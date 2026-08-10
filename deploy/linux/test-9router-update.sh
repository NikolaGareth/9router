#!/usr/bin/env bash
set -u

# Integration tests for the Linux updater. Keep every mutation beneath a
# repository-local temporary directory so the suite is safe in CI.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPDATER="$ROOT_DIR/deploy/linux/9router-update"
SERVICE_UNIT="$ROOT_DIR/deploy/linux/9router.service"
INSTALLER="$ROOT_DIR/deploy/linux/install.sh"
TMP=""

cleanup() {
  [[ -n "$TMP" ]] && rm -rf -- "$TMP"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

new_tmp() {
  mkdir -p "$ROOT_DIR/.superpowers"
  TMP="$(mktemp -d "$ROOT_DIR/.superpowers/9router-update-test.XXXXXX")"
}

assert_file() {
  test -f "$1" || fail "expected file: $1"
}

assert_dir() {
  test -d "$1" || fail "expected directory: $1"
}

assert_not_exists() {
  test ! -e "$1" || fail "did not expect path: $1"
}

assert_empty_file() {
  test ! -s "$1" || fail "expected empty file: $1"
}

file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

assert_event_log() {
  local expected
  local actual

  expected="$(printf '%s\n' "$@")"
  actual="$(<"$TMP/install-events.log")"
  [[ "$actual" == "$expected" ]] ||
    fail "unexpected installer event order:\nexpected:\n$expected\nactual:\n$actual"
}

run_fake_systemctl() {
  env \
    NINEROUTER_TEST_SYSTEMCTL_LOG="$TMP/systemctl.log" \
    NINEROUTER_TEST_INSTALL_EVENTS="$TMP/install-events.log" \
    NINEROUTER_TEST_SYSTEMCTL_STATE="$TMP/systemctl.state" \
    NINEROUTER_TEST_SYSTEMCTL_ENABLED_STATE="$TMP/systemctl.enabled" \
  NINEROUTER_TEST_SYSTEMCTL_WANTS_LINK="$TMP/systemctl.wants-link" \
    NINEROUTER_SERVICE_TARGET="$TMP/etc/systemd/system/9router.service" \
    NINEROUTER_TEST_PREVIOUS_DIR="$TMP/opt/9router.previous" \
    NINEROUTER_TEST_DAEMON_RELOAD_MARKER="$TMP/daemon-reload.failed" \
    "$TMP/bin/systemctl" "$@"
}

test_service_unit_uses_fixed_production_paths_without_credentials() {
  assert_file "$SERVICE_UNIT"
  grep -q '^ExecStart=/opt/node-v24.15.0-npm/node/bin/node /opt/9router/.runtime/custom-server.js$' "$SERVICE_UNIT" || \
    fail 'service unit does not use the fixed production Node entry point'
  grep -q '^Environment=DATA_DIR=/root/.9router$' "$SERVICE_UNIT" || \
    fail 'service unit does not use the fixed production data directory'
  if grep -Eqi 'password|api[_-]?key|token|secret' "$SERVICE_UNIT"; then
    fail 'service unit must not contain credentials'
  fi
}

test_installer_has_root_guard_and_preserves_data_directory() {
  assert_file "$INSTALLER"
  bash -n "$INSTALLER" || fail 'installer has invalid shell syntax'
  grep -q 'EUID' "$INSTALLER" || fail 'installer does not verify root execution'
  grep -Eq 'MKDIR.*-p.*DATA_DIR' "$INSTALLER" || \
    fail 'installer does not create the data directory non-destructively'
  if grep -Eq '(rm|cat|read).*DATA_DIR|DATA_DIR.*(rm|cat|read)' "$INSTALLER"; then
    fail 'installer must not delete or read the data directory'
  fi
}

make_fakes() {
  mkdir -p "$TMP/bin" "$TMP/opt" "$TMP/run" "$TMP/usr/local/sbin" \
    "$TMP/etc/systemd/system" "$TMP/root"
  : >"$TMP/systemctl.log"
  : >"$TMP/npm.log"
  : >"$TMP/curl.log"
  : >"$TMP/git.log"
  : >"$TMP/flock.log"
  : >"$TMP/install-events.log"
  : >"$TMP/phase.log"
  printf 'active\n' >"$TMP/systemctl.state"
  printf '%s\n' "${NINEROUTER_TEST_INITIAL_ENABLED_STATE:-enabled}" >"$TMP/systemctl.enabled"
  : >"$TMP/systemctl.wants-link"

  cat >"$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$NINEROUTER_TEST_GIT_LOG"
if [[ "$1" == clone ]]; then
  printf 'git clone\n' >>"$NINEROUTER_TEST_INSTALL_EVENTS"
fi
if [[ "$1" == -C ]]; then
  printf 'test-revision\n'
  exit 0
fi
if [[ "$1" != clone ]]; then
  echo "unexpected git command: $*" >&2
  exit 64
fi
dest="${@: -1}"
mkdir -p "$dest"
printf '{"scripts":{"build":"next build"}}\n' >"$dest/package.json"
EOF

  cat >"$TMP/bin/flock" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$NINEROUTER_TEST_FLOCK_LOG"
[[ "${NINEROUTER_TEST_LOCK_FAIL:-0}" != 1 ]] || exit 1
owner_file="$NINEROUTER_TEST_LOCK_OWNER_FILE"
if [[ -n "${NINEROUTER_INHERITED_LOCK_FD:-}" ]]; then
  [[ -f "$owner_file" ]] || exit 1
  [[ -f "$NINEROUTER_TEST_LOCK_ID_FILE" ]] || exit 1
  owner_pid="$(<"$owner_file")"
  kill -0 "$owner_pid" 2>/dev/null
  exit
fi
guard_path="${owner_file}.guard"
/bin/mkdir "$guard_path" 2>/dev/null || exit 1
owner_pid=""
if [[ -f "$owner_file" ]]; then
  owner_pid="$(<"$owner_file")"
fi
if [[ -n "$owner_pid" ]] && kill -0 "$owner_pid" 2>/dev/null; then
  /bin/rmdir "$guard_path"
  exit 1
fi
printf '%s\n' "$PPID" >"$owner_file"
if /usr/bin/stat -Lc '%d:%i' -- "$NINEROUTER_LOCK_FILE" >"$NINEROUTER_TEST_LOCK_ID_FILE" 2>/dev/null; then
  :
else
  /usr/bin/stat -L -f '%d:%i' "$NINEROUTER_LOCK_FILE" >"$NINEROUTER_TEST_LOCK_ID_FILE"
fi
/bin/rmdir "$guard_path"
EOF

  cat >"$TMP/bin/npm" <<'EOF'
#!/usr/bin/env bash
set -eu
if [[ "$1" == ci ]]; then
  printf 'npm ci\n' >>"$NINEROUTER_TEST_NPM_LOG"
  exit 0
fi
if [[ "$1" != run || "$2" != build ]]; then
  echo "unexpected npm command: $*" >&2
  exit 64
fi
printf 'npm run build\n' >>"$NINEROUTER_TEST_NPM_LOG"
if [[ "${NINEROUTER_TEST_BUILD_FAIL:-0}" == 1 ]]; then
  exit 42
fi
mkdir -p .next/standalone/src/mitm .next/standalone/open-sse \
  node_modules/node-forge node_modules/next src/mitm open-sse
: >.next/standalone/server.js
: >.next/standalone/src/mitm/server.js
: >.next/standalone/open-sse/standalone-marker
: >custom-server.js
: >src/mitm/runtime-helper.js
: >open-sse/source-marker
EOF

  cat >"$TMP/bin/stat" <<'EOF'
#!/usr/bin/env bash
set -eu
follow=0
format=""
path=""
while (( $# > 0 )); do
  case "$1" in
    -Lc) follow=1; format="$2"; shift 2 ;;
    -c) format="$2"; shift 2 ;;
    --) shift ;;
    *) path="$1"; shift ;;
  esac
done
if (( follow == 1 )) && [[ "$path" == /dev/fd/* || "$path" == /proc/self/fd/* ]]; then
  if [[ "${NINEROUTER_TEST_REPLACE_LOCK_BEFORE_FD_STAT:-0}" == 1 &&
    ! -e "$NINEROUTER_TEST_LOCK_SWAP_MARKER" ]]; then
    /bin/mv "$NINEROUTER_LOCK_FILE" "$NINEROUTER_TEST_REPLACED_LOCK_FILE"
    : >"$NINEROUTER_LOCK_FILE"
    : >"$NINEROUTER_TEST_LOCK_SWAP_MARKER"
  fi
  cat "$NINEROUTER_TEST_LOCK_ID_FILE"
  exit
fi
if [[ "$format" == %d && "${NINEROUTER_TEST_CROSS_DEVICE:-0}" == 1 && \
  "$path" == *9router-build* ]]; then
    printf '2\n'
    exit
fi
if (( follow == 1 )); then
  if /usr/bin/stat -Lc "$format" -- "$path" 2>/dev/null; then
    exit
  fi
  exec /usr/bin/stat -L -f "$format" "$path"
fi
if /usr/bin/stat -c "$format" -- "$path" 2>/dev/null; then
  exit
fi
exec /usr/bin/stat -f "$format" "$path"
EOF

  cat >"$TMP/bin/node" <<'EOF'
#!/usr/bin/env bash
set -eu
if [[ "$1" == --check && "${NINEROUTER_TEST_NODE_CHECK_FAIL:-0}" == 1 ]]; then
  exit 12
fi
exit 0
EOF

  cat >"$TMP/bin/mv" <<'EOF'
#!/usr/bin/env bash
set -eu
while [[ "$1" == -T || "$1" == -n || "$1" == -- ]]; do
  shift
done
source_path="$1"
destination_path="$2"
if [[ -e "$destination_path" || -L "$destination_path" ]]; then
  exit 1
fi
/bin/mv "$source_path" "$destination_path"
EOF

  cat >"$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$NINEROUTER_TEST_SYSTEMCTL_LOG"
printf 'systemctl %s\n' "$*" >>"$NINEROUTER_TEST_INSTALL_EVENTS"
case "$1" in
  daemon-reload)
    if [[ "${NINEROUTER_TEST_DAEMON_RELOAD_FAIL_ONCE:-0}" == 1 && ! -e "$NINEROUTER_TEST_DAEMON_RELOAD_MARKER" ]]; then
      : >"$NINEROUTER_TEST_DAEMON_RELOAD_MARKER"
      exit 7
    fi
    if [[ "${NINEROUTER_TEST_RECOVERY_DAEMON_RELOAD_FAIL_ONCE:-0}" == 1 && \
      ! -e "$NINEROUTER_TEST_RECOVERY_DAEMON_RELOAD_MARKER" ]]; then
      : >"$NINEROUTER_TEST_RECOVERY_DAEMON_RELOAD_MARKER"
      exit 17
    fi
    ;;
  enable)
    [[ "$2" == 9router ]]
    printf 'enabled\n' >"$NINEROUTER_TEST_SYSTEMCTL_ENABLED_STATE"
    : >"$NINEROUTER_TEST_SYSTEMCTL_WANTS_LINK"
    [[ "${NINEROUTER_TEST_ENABLE_FAIL:-0}" != 1 ]] || exit 8
    ;;
  disable)
    [[ "$2" == 9router ]]
    if [[ "${NINEROUTER_TEST_REALISTIC_MISSING_UNIT:-0}" == 1 &&
      ! -e "$NINEROUTER_SERVICE_TARGET" && ! -L "$NINEROUTER_SERVICE_TARGET" ]]; then
      exit 18
    fi
    printf 'disabled\n' >"$NINEROUTER_TEST_SYSTEMCTL_ENABLED_STATE"
    rm -f -- "$NINEROUTER_TEST_SYSTEMCTL_WANTS_LINK"
    ;;
  mask)
    [[ "$2" == 9router ]]
    if [[ "${NINEROUTER_TEST_REALISTIC_MASK:-0}" == 1 ]]; then
      if [[ -L "$NINEROUTER_SERVICE_TARGET" && \
        "$(readlink "$NINEROUTER_SERVICE_TARGET")" == /dev/null ]]; then
        :
      elif [[ -e "$NINEROUTER_SERVICE_TARGET" || -L "$NINEROUTER_SERVICE_TARGET" ]]; then
        exit 9
      else
        ln -s /dev/null "$NINEROUTER_SERVICE_TARGET"
      fi
    fi
    printf 'masked\n' >"$NINEROUTER_TEST_SYSTEMCTL_ENABLED_STATE"
    rm -f -- "$NINEROUTER_TEST_SYSTEMCTL_WANTS_LINK"
    ;;
  is-enabled)
    [[ "$2" == 9router ]]
    if [[ "${NINEROUTER_TEST_IS_ENABLED_QUERY_ERROR_WITH_STATE:-0}" == 1 ]]; then
      printf 'enabled\n'
      exit 5
    fi
    if [[ "${NINEROUTER_TEST_IS_ENABLED_QUERY_ERROR:-0}" == 1 ]]; then
      printf 'Failed to query unit state\n' >&2
      exit 5
    fi
    if [[ "${NINEROUTER_TEST_REALISTIC_MISSING_UNIT:-0}" == 1 &&
      ! -e "$NINEROUTER_SERVICE_TARGET" && ! -L "$NINEROUTER_SERVICE_TARGET" ]]; then
      printf 'not-found\n'
      exit 4
    fi
    state="$(cat "$NINEROUTER_TEST_SYSTEMCTL_ENABLED_STATE")"
    printf '%s\n' "$state"
    case "$state" in
      enabled) exit 0 ;;
      disabled|masked) exit 1 ;;
      not-found) exit 4 ;;
      *) exit 3 ;;
    esac
    ;;
  stop)
    [[ "$2" == 9router ]]
    if [[ "${NINEROUTER_TEST_REALISTIC_MISSING_UNIT:-0}" == 1 &&
      ! -e "$NINEROUTER_SERVICE_TARGET" && ! -L "$NINEROUTER_SERVICE_TARGET" ]]; then
      exit 19
    fi
    [[ "${NINEROUTER_TEST_STOP_FAIL:-0}" != 1 ]] || exit 5
    if [[ "${NINEROUTER_TEST_STOP_REMAINS_ACTIVE:-0}" == 1 ]]; then
      printf 'active\n' >"$NINEROUTER_TEST_SYSTEMCTL_STATE"
    else
      printf 'inactive\n' >"$NINEROUTER_TEST_SYSTEMCTL_STATE"
    fi
    if [[ "${NINEROUTER_TEST_CREATE_PREVIOUS_ON_STOP:-0}" == 1 ]]; then
      mkdir -p "$NINEROUTER_TEST_PREVIOUS_DIR"
      : >"$NINEROUTER_TEST_PREVIOUS_DIR/race-marker"
    fi
    ;;
  start)
    [[ "$2" == 9router ]]
    if [[ "${NINEROUTER_TEST_START_INACTIVE:-0}" == 1 ]]; then
      printf 'inactive\n' >"$NINEROUTER_TEST_SYSTEMCTL_STATE"
    else
      printf 'active\n' >"$NINEROUTER_TEST_SYSTEMCTL_STATE"
    fi
    if [[ "${NINEROUTER_TEST_SEND_TERM_ON_START:-0}" == 1 ]]; then
      if [[ -n "${NINEROUTER_TEST_START_BLOCKED_MARKER:-}" ]]; then
        : >"$NINEROUTER_TEST_START_BLOCKED_MARKER"
      fi
      while [[ ! -e "$NINEROUTER_TEST_TERM_GO" ]]; do
        /bin/sleep 0.01
      done
    fi
    ;;
  is-active)
    if [[ "${NINEROUTER_TEST_REALISTIC_MISSING_UNIT:-0}" == 1 &&
      ! -e "$NINEROUTER_SERVICE_TARGET" && ! -L "$NINEROUTER_SERVICE_TARGET" ]]; then
      if [[ "$2" == --quiet ]]; then
        exit 4
      fi
      printf 'unknown\n'
      exit 4
    fi
    if [[ "$2" == --quiet && "$3" == 9router ]]; then
      [[ "$(cat "$NINEROUTER_TEST_SYSTEMCTL_STATE")" == active ]] && exit 0
      exit 3
    fi
    [[ "$2" == 9router ]]
    if [[ "${NINEROUTER_TEST_STOP_QUERY_ERROR:-0}" == 1 ]]; then
      printf 'Failed to connect to bus\n'
      exit 1
    fi
    case "$(cat "$NINEROUTER_TEST_SYSTEMCTL_STATE")" in
      active) printf 'active\n'; exit 0 ;;
      inactive) printf 'inactive\n'; exit 3 ;;
      failed) printf 'failed\n'; exit 3 ;;
      *) printf 'unknown\n'; exit 4 ;;
    esac
    ;;
  *)
    echo "unexpected systemctl command: $*" >&2
    exit 64
    ;;
esac
EOF

  cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'curl health-check\n' >>"$NINEROUTER_TEST_CURL_LOG"
case "${NINEROUTER_TEST_CURL_MODE:-success}" in
  success) printf '200 \n' ;;
  login-redirect) printf '302 http://127.0.0.1/login\n' ;;
  bad-redirect) printf '302 https://example.invalid/not-login\n' ;;
  fail) exit 22 ;;
  *)
    echo "unexpected curl mode: ${NINEROUTER_TEST_CURL_MODE}" >&2
    exit 64
    ;;
esac
EOF

  cat >"$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"$TMP/bin/install" <<'EOF'
#!/usr/bin/env bash
set -eu
if [[ "$*" == *'/9router-update '* ]]; then
  printf 'install updater\n' >>"$NINEROUTER_TEST_INSTALL_EVENTS"
elif [[ "$*" == *'/9router.service '* ]]; then
  printf 'install unit\n' >>"$NINEROUTER_TEST_INSTALL_EVENTS"
  [[ "${NINEROUTER_TEST_INSTALL_FAIL:-}" != unit ]] || exit 9
fi
exec /usr/bin/install "$@"
EOF

  cat >"$TMP/bin/cp" <<'EOF'
#!/usr/bin/env bash
set -eu
source_path="${@: -2:1}"
destination_path="${@: -1}"
if [[ -n "${NINEROUTER_UPDATER_TARGET:-}" && "$source_path" == "$NINEROUTER_UPDATER_TARGET" ]]; then
  printf 'cp backup-updater\n' >>"$NINEROUTER_TEST_INSTALL_EVENTS"
  if [[ "${NINEROUTER_TEST_CP_FAIL:-}" == updater ]]; then
    printf 'partial-updater-backup\n' >"$destination_path"
    exit 77
  fi
elif [[ -n "${NINEROUTER_SERVICE_TARGET:-}" && "$source_path" == "$NINEROUTER_SERVICE_TARGET" ]]; then
  printf 'cp backup-unit\n' >>"$NINEROUTER_TEST_INSTALL_EVENTS"
  if [[ "${NINEROUTER_TEST_CP_FAIL:-}" == unit ]]; then
    printf 'partial-unit-backup\n' >"$destination_path"
    exit 78
  fi
fi
if [[ "$1" == -a ]]; then
  shift
  exec /bin/cp -pR "$@"
fi
exec /bin/cp "$@"
EOF

  cat >"$TMP/bin/mv" <<'EOF'
#!/usr/bin/env bash
set -eu
while [[ "$1" == -T || "$1" == -n || "$1" == -f || "$1" == -fT || "$1" == -- ]]; do
  shift
done
source_path="$1"
destination_path="$2"
if [[ -n "${NINEROUTER_PHASE_FILE:-}" && "$destination_path" == "$NINEROUTER_PHASE_FILE" ]]; then
  phase_value="$(cat "$source_path")"
  printf '%s\n' "$phase_value" >>"$NINEROUTER_TEST_PHASE_LOG"
  if [[ "${NINEROUTER_TEST_FAIL_PHASE:-}" == "$phase_value" ]]; then
    exit 79
  fi
fi
case "$source_path" in
  *9router.service.new.*) printf 'mv install-unit\n' >>"$NINEROUTER_TEST_INSTALL_EVENTS" ;;
  *9router.service.backup.*) printf 'mv restore-unit\n' >>"$NINEROUTER_TEST_INSTALL_EVENTS" ;;
  */9router-install-recovery.unit) printf 'mv restore-unit\n' >>"$NINEROUTER_TEST_INSTALL_EVENTS" ;;
esac
if [[ "${NINEROUTER_TEST_FAIL_OLD_MOVE_BEFORE_MUTATION:-0}" == 1 && \
  "$source_path" == "$NINEROUTER_ROOT" && "$destination_path" == "$NINEROUTER_PREVIOUS_DIR" ]]; then
  exit 72
fi
if [[ "${NINEROUTER_TEST_REPLACE_ROOT_AT_OLD_INTENT:-0}" == 1 && \
  "$source_path" == "$NINEROUTER_ROOT" && "$destination_path" == "$NINEROUTER_PREVIOUS_DIR" ]]; then
  /bin/mv "$source_path" "$NINEROUTER_TEST_DISPLACED_ROOT"
  /bin/mkdir -p "$source_path"
  : >"$source_path/forged-root"
  exit 71
fi
if [[ "${NINEROUTER_TEST_FAIL_OLD_MOVE_AFTER_MUTATION:-0}" == 1 && \
  "$source_path" == "$NINEROUTER_ROOT" && "$destination_path" == "$NINEROUTER_PREVIOUS_DIR" ]]; then
  /bin/mv "$source_path" "$destination_path"
  exit 73
fi
if [[ "${NINEROUTER_TEST_FAIL_NEW_MOVE_BEFORE_MUTATION:-0}" == 1 && \
  "$source_path" == "$NINEROUTER_BUILD_DIR" && "$destination_path" == "$NINEROUTER_ROOT" ]]; then
  exit 74
fi
if [[ "${NINEROUTER_TEST_FAIL_RECOVERY_ROOT_STAGE_AFTER_MUTATION:-0}" == 1 && \
  "$source_path" == "$NINEROUTER_ROOT" && "$destination_path" == "$NINEROUTER_TEST_FAILED_ROOT" ]]; then
  /bin/mv "$source_path" "$destination_path"
  exit 81
fi
if [[ "${NINEROUTER_TEST_FAIL_RECOVERY_PREVIOUS_AFTER_MUTATION:-0}" == 1 && \
  "$source_path" == "$NINEROUTER_PREVIOUS_DIR" && "$destination_path" == "$NINEROUTER_ROOT" ]]; then
  /bin/mv "$source_path" "$destination_path"
  exit 82
fi
if [[ "${NINEROUTER_TEST_FAIL_RECOVERY_UNIT_AFTER_MUTATION:-0}" == 1 && \
  "$destination_path" == "$NINEROUTER_SERVICE_TARGET" ]]; then
  /bin/mv -f "$source_path" "$destination_path"
  exit 83
fi
if [[ "${NINEROUTER_TEST_FAIL_RECOVERY_UPDATER_AFTER_MUTATION:-0}" == 1 && \
  "$destination_path" == "$NINEROUTER_UPDATER_TARGET" ]]; then
  /bin/mv -f "$source_path" "$destination_path"
  exit 84
fi
if [[ -e "$destination_path" || -L "$destination_path" ]]; then
  /bin/mv -f "$source_path" "$destination_path"
else
  /bin/mv "$source_path" "$destination_path"
fi
EOF

  cat >"$TMP/bin/rm" <<'EOF'
#!/usr/bin/env bash
set -eu
for argument in "$@"; do
  if [[ "$argument" == *9router.service.backup.* ]]; then
    printf 'rm cleanup-backup\n' >>"$NINEROUTER_TEST_INSTALL_EVENTS"
    break
  fi
  if [[ "$argument" == */9router-install-recovery.unit ]]; then
    printf 'rm cleanup-backup\n' >>"$NINEROUTER_TEST_INSTALL_EVENTS"
    break
  fi
  if [[ "$argument" == *'/9router.service' || "$argument" == *9router.service.new.* ]]; then
    printf 'rm remove-unit\n' >>"$NINEROUTER_TEST_INSTALL_EVENTS"
    break
  fi
done
if [[ "${NINEROUTER_TEST_FAIL_CLEANUP_UNIT_AFTER_MUTATION:-0}" == 1 ]]; then
  for argument in "$@"; do
    if [[ "$argument" == "$NINEROUTER_SERVICE_TARGET" ]]; then
      /bin/rm -f -- "$argument"
      exit 85
    fi
  done
fi
if [[ "${NINEROUTER_TEST_FAIL_CLEANUP_UPDATER_AFTER_MUTATION:-0}" == 1 ]]; then
  for argument in "$@"; do
    if [[ "$argument" == "$NINEROUTER_UPDATER_TARGET" ]]; then
      /bin/rm -f -- "$argument"
      exit 86
    fi
  done
fi
for argument in "$@"; do
  if [[ "${NINEROUTER_TEST_FAIL_RECOVERY_SCRIPT_REMOVE:-0}" == 1 &&
    "$argument" == */9router-install-recover ]]; then
    exit 87
  fi
  if [[ "${NINEROUTER_TEST_FAIL_CLEANUP_SCRIPT_REMOVE:-0}" == 1 &&
    "$argument" == */9router-install-cleanup ]]; then
    exit 88
  fi
done
exec /bin/rm "$@"
EOF

  for command_name in mkdir; do
    cat >"$TMP/bin/$command_name" <<EOF
#!/usr/bin/env bash
exec /bin/$command_name "\$@"
EOF
  done

  chmod +x "$TMP/bin/git" "$TMP/bin/flock" "$TMP/bin/npm" "$TMP/bin/node" "$TMP/bin/stat" \
    "$TMP/bin/mv" "$TMP/bin/systemctl" "$TMP/bin/curl" "$TMP/bin/sleep" \
    "$TMP/bin/mkdir" "$TMP/bin/rm" "$TMP/bin/cp" "$TMP/bin/install"
}

run_updater() {
  local output_file="$1"
  local updater_pid
  shift
  env \
    NINEROUTER_TEST_MODE=1 \
    NINEROUTER_TEST_ROOT="$TMP" \
    NINEROUTER_ROOT="$TMP/opt/9router" \
    NINEROUTER_BUILD_DIR="$TMP/opt/9router-build" \
    NINEROUTER_PREVIOUS_DIR="$TMP/opt/9router.previous" \
    NINEROUTER_LOCK_FILE="$TMP/run/9router-update.lock" \
    NINEROUTER_PHASE_FILE="$TMP/run/9router-update.phase" \
    NINEROUTER_GIT="$TMP/bin/git" \
    NINEROUTER_MV="$TMP/bin/mv" \
    NINEROUTER_STAT="$TMP/bin/stat" \
    NINEROUTER_FLOCK="$TMP/bin/flock" \
    NINEROUTER_SLEEP="$TMP/bin/sleep" \
    NINEROUTER_MKDIR="$TMP/bin/mkdir" \
    NINEROUTER_RM="$TMP/bin/rm" \
    NINEROUTER_CP="$TMP/bin/cp" \
    NINEROUTER_NPM="$TMP/bin/npm" \
    NINEROUTER_SYSTEMCTL="$TMP/bin/systemctl" \
    NINEROUTER_CURL="$TMP/bin/curl" \
    NINEROUTER_NODE="$TMP/bin/node" \
    NINEROUTER_TEST_SYSTEMCTL_LOG="$TMP/systemctl.log" \
    NINEROUTER_TEST_SYSTEMCTL_STATE="$TMP/systemctl.state" \
    NINEROUTER_TEST_SYSTEMCTL_ENABLED_STATE="$TMP/systemctl.enabled" \
    NINEROUTER_TEST_SYSTEMCTL_WANTS_LINK="$TMP/systemctl.wants-link" \
    NINEROUTER_TEST_PREVIOUS_DIR="$TMP/opt/9router.previous" \
    NINEROUTER_TEST_NPM_LOG="$TMP/npm.log" \
    NINEROUTER_TEST_CURL_LOG="$TMP/curl.log" \
    NINEROUTER_TEST_GIT_LOG="$TMP/git.log" \
    NINEROUTER_TEST_FLOCK_LOG="$TMP/flock.log" \
    NINEROUTER_TEST_LOCK_OWNER_FILE="$TMP/flock.owner" \
    NINEROUTER_TEST_LOCK_ID_FILE="$TMP/flock.identity" \
    NINEROUTER_TEST_LOCK_SWAP_MARKER="$TMP/flock.swap" \
    NINEROUTER_TEST_REPLACED_LOCK_FILE="$TMP/run/replaced-during-fd-check.lock" \
    NINEROUTER_TEST_INSTALL_EVENTS="$TMP/install-events.log" \
    NINEROUTER_TEST_PHASE_LOG="$TMP/phase.log" \
    NINEROUTER_TEST_DAEMON_RELOAD_MARKER="$TMP/daemon-reload.failed" \
    NINEROUTER_TEST_RECOVERY_DAEMON_RELOAD_MARKER="$TMP/recovery-daemon-reload.failed" \
    NINEROUTER_TEST_TERM_GO="$TMP/term-go" \
    PATH="$TMP/bin:$PATH" \
    "$@" bash "$UPDATER" >"$output_file" 2>&1 &
  updater_pid=$!
  if [[ -n "${NINEROUTER_TEST_UPDATER_PID_FILE:-}" ]]; then
    printf '%s\n' "$updater_pid" >"$NINEROUTER_TEST_UPDATER_PID_FILE"
  fi
  wait "$updater_pid"
}

run_installer() {
  local output_file="$1"
  shift

  env \
    NINEROUTER_TEST_MODE=1 \
    NINEROUTER_TEST_ROOT="$TMP" \
    NINEROUTER_UPDATER_TARGET="$TMP/usr/local/sbin/9router-update" \
    NINEROUTER_SERVICE_TARGET="$TMP/etc/systemd/system/9router.service" \
    NINEROUTER_DATA_DIR="$TMP/root/.9router" \
    NINEROUTER_SYSTEMCTL="$TMP/bin/systemctl" \
    NINEROUTER_NODE="$TMP/bin/node" \
    NINEROUTER_NPM="$TMP/bin/npm" \
    NINEROUTER_GIT="$TMP/bin/git" \
    NINEROUTER_CURL="$TMP/bin/curl" \
    NINEROUTER_FLOCK="$TMP/bin/flock" \
    NINEROUTER_MKDIR="$TMP/bin/mkdir" \
    NINEROUTER_CP="$TMP/bin/cp" \
    NINEROUTER_MV="$TMP/bin/mv" \
    NINEROUTER_RM="$TMP/bin/rm" \
    NINEROUTER_INSTALL="$TMP/bin/install" \
    NINEROUTER_ROOT="$TMP/opt/9router" \
    NINEROUTER_BUILD_DIR="$TMP/opt/9router-build" \
    NINEROUTER_PREVIOUS_DIR="$TMP/opt/9router.previous" \
    NINEROUTER_LOCK_FILE="$TMP/run/9router-update.lock" \
    NINEROUTER_PHASE_FILE="$TMP/run/9router-update.phase" \
    NINEROUTER_RECOVERY_UNIT="$TMP/run/9router-install-recovery.unit" \
    NINEROUTER_RECOVERY_UPDATER="$TMP/run/9router-install-recovery.updater" \
    NINEROUTER_RECOVERY_ENABLE_STATE="$TMP/run/9router-install-recovery.enable-state" \
    NINEROUTER_RECOVERY_SCRIPT="$TMP/run/9router-install-recover" \
    NINEROUTER_FIRST_INSTALL_CLEANUP_SCRIPT="$TMP/run/9router-install-cleanup" \
    NINEROUTER_MV="$TMP/bin/mv" \
    NINEROUTER_STAT="$TMP/bin/stat" \
    NINEROUTER_SLEEP="$TMP/bin/sleep" \
    NINEROUTER_RM="$TMP/bin/rm" \
    NINEROUTER_CP="$TMP/bin/cp" \
    NINEROUTER_TEST_SYSTEMCTL_LOG="$TMP/systemctl.log" \
    NINEROUTER_TEST_SYSTEMCTL_STATE="$TMP/systemctl.state" \
    NINEROUTER_TEST_SYSTEMCTL_ENABLED_STATE="$TMP/systemctl.enabled" \
    NINEROUTER_TEST_SYSTEMCTL_WANTS_LINK="$TMP/systemctl.wants-link" \
    NINEROUTER_TEST_PREVIOUS_DIR="$TMP/opt/9router.previous" \
    NINEROUTER_TEST_NPM_LOG="$TMP/npm.log" \
    NINEROUTER_TEST_CURL_LOG="$TMP/curl.log" \
    NINEROUTER_TEST_GIT_LOG="$TMP/git.log" \
    NINEROUTER_TEST_FLOCK_LOG="$TMP/flock.log" \
    NINEROUTER_TEST_LOCK_OWNER_FILE="$TMP/flock.owner" \
    NINEROUTER_TEST_LOCK_ID_FILE="$TMP/flock.identity" \
    NINEROUTER_TEST_LOCK_SWAP_MARKER="$TMP/flock.swap" \
    NINEROUTER_TEST_REPLACED_LOCK_FILE="$TMP/run/replaced-during-fd-check.lock" \
    NINEROUTER_TEST_INSTALL_EVENTS="$TMP/install-events.log" \
    NINEROUTER_TEST_PHASE_LOG="$TMP/phase.log" \
    NINEROUTER_TEST_DAEMON_RELOAD_MARKER="$TMP/daemon-reload.failed" \
    NINEROUTER_TEST_RECOVERY_DAEMON_RELOAD_MARKER="$TMP/recovery-daemon-reload.failed" \
    PATH="$TMP/bin:$PATH" \
    "$@" bash "$INSTALLER" >"$output_file" 2>&1
}

run_fixed_script() {
  local output_file="$1"
  local script_path="$2"
  shift 2

  env \
    NINEROUTER_TEST_SYSTEMCTL_LOG="$TMP/systemctl.log" \
    NINEROUTER_TEST_INSTALL_EVENTS="$TMP/install-events.log" \
    NINEROUTER_TEST_SYSTEMCTL_STATE="$TMP/systemctl.state" \
    NINEROUTER_TEST_SYSTEMCTL_ENABLED_STATE="$TMP/systemctl.enabled" \
    NINEROUTER_TEST_SYSTEMCTL_WANTS_LINK="$TMP/systemctl.wants-link" \
    NINEROUTER_TEST_PREVIOUS_DIR="$TMP/opt/9router.previous" \
    NINEROUTER_TEST_DAEMON_RELOAD_MARKER="$TMP/daemon-reload.failed" \
    NINEROUTER_TEST_RECOVERY_DAEMON_RELOAD_MARKER="$TMP/recovery-daemon-reload.failed" \
    NINEROUTER_TEST_FLOCK_LOG="$TMP/flock.log" \
    NINEROUTER_TEST_LOCK_OWNER_FILE="$TMP/flock.owner" \
    NINEROUTER_TEST_LOCK_ID_FILE="$TMP/flock.identity" \
    NINEROUTER_TEST_LOCK_SWAP_MARKER="$TMP/flock.swap" \
    NINEROUTER_TEST_REPLACED_LOCK_FILE="$TMP/run/replaced-during-fd-check.lock" \
    NINEROUTER_TEST_INSTALL_EVENTS="$TMP/install-events.log" \
    NINEROUTER_SERVICE_TARGET="$TMP/etc/systemd/system/9router.service" \
    NINEROUTER_ROOT="$TMP/opt/9router" \
    NINEROUTER_PREVIOUS_DIR="$TMP/opt/9router.previous" \
    NINEROUTER_UPDATER_TARGET="$TMP/usr/local/sbin/9router-update" \
    NINEROUTER_TEST_FAILED_ROOT="$TMP/opt/9router.failed" \
    NINEROUTER_LOCK_FILE="$TMP/run/9router-update.lock" \
    PATH="$TMP/bin:$PATH" \
    "$@" "$script_path" >"$output_file" 2>&1
}

new_install_tmp() {
  TMP="$(mktemp -d /private/tmp/9router-install-test.XXXXXX)"
}

prepare_existing_unit() {
  mkdir -p "$TMP/etc/systemd/system" "$TMP/root/.9router"
  printf '[Service]\nExecStart=/legacy/router\n' >"$TMP/etc/systemd/system/9router.service"
  chmod 0600 "$TMP/etc/systemd/system/9router.service"
  cp "$TMP/etc/systemd/system/9router.service" "$TMP/original-unit"
  printf 'keep-this-data\n' >"$TMP/root/.9router/existing-data"
}

prepare_existing_updater() {
  mkdir -p "$TMP/usr/local/sbin"
  printf '#!/usr/bin/env bash\nprintf old-updater\\n\n' >"$TMP/usr/local/sbin/9router-update"
  chmod 0700 "$TMP/usr/local/sbin/9router-update"
  cp "$TMP/usr/local/sbin/9router-update" "$TMP/original-updater"
}

prepare_legacy_installation() {
  mkdir -p "$TMP/etc/systemd/system" "$TMP/usr/local/sbin" \
    "$TMP/opt/9router" "$TMP/root/.9router"
  cat >"$TMP/opt/9router/legacy-entrypoint" <<EOF
#!/usr/bin/env bash
printf 'legacy-entrypoint-ok\\n'
EOF
  chmod 0755 "$TMP/opt/9router/legacy-entrypoint"
  printf '[Service]\nExecStart=%s\n' "$TMP/opt/9router/legacy-entrypoint" \
    >"$TMP/etc/systemd/system/9router.service"
  chmod 0600 "$TMP/etc/systemd/system/9router.service"
  cp "$TMP/etc/systemd/system/9router.service" "$TMP/original-unit"
  printf '#!/usr/bin/env bash\nprintf legacy-updater-ok\\n\n' \
    >"$TMP/usr/local/sbin/9router-update"
  chmod 0700 "$TMP/usr/local/sbin/9router-update"
  cp "$TMP/usr/local/sbin/9router-update" "$TMP/original-updater"
  printf 'keep-this-data\n' >"$TMP/root/.9router/existing-data"
}

prepare_masked_installation() {
  mkdir -p "$TMP/etc/systemd/system" "$TMP/usr/local/sbin" \
    "$TMP/opt/9router" "$TMP/root/.9router"
  rm -f -- "$TMP/etc/systemd/system/9router.service"
  ln -s /dev/null "$TMP/etc/systemd/system/9router.service"
  printf '#!/usr/bin/env bash\nprintf masked-old-updater\\n\n' \
    >"$TMP/usr/local/sbin/9router-update"
  chmod 0700 "$TMP/usr/local/sbin/9router-update"
  cp "$TMP/usr/local/sbin/9router-update" "$TMP/original-updater"
  : >"$TMP/opt/9router/current-marker"
  printf 'masked\n' >"$TMP/systemctl.enabled"
  printf 'inactive\n' >"$TMP/systemctl.state"
  rm -f -- "$TMP/systemctl.wants-link"
}

assert_old_updater_restored() {
  cmp "$TMP/original-updater" "$TMP/usr/local/sbin/9router-update" || \
    fail 'installer did not restore the original updater bytes'
  [[ "$(file_mode "$TMP/usr/local/sbin/9router-update")" == 700 ]] || \
    fail 'installer did not restore the original updater permissions'
}

assert_no_fixed_recovery_materials() {
  assert_not_exists "$TMP/run/9router-install-recovery.unit"
  assert_not_exists "$TMP/run/9router-install-recovery.updater"
  assert_not_exists "$TMP/run/9router-install-recovery.enable-state"
  assert_not_exists "$TMP/run/9router-install-recover"
  assert_not_exists "$TMP/run/9router-install-cleanup"
  assert_not_exists "$TMP/run/9router-install-recover.step"
  assert_not_exists "$TMP/run/9router-install-cleanup.step"
  assert_not_exists "$TMP/run/9router-install-recovery.unit.work"
  assert_not_exists "$TMP/run/9router-install-recovery.updater.work"
}

assert_old_unit_restored() {
  cmp "$TMP/original-unit" "$TMP/etc/systemd/system/9router.service" || \
    fail 'installer did not restore the original unit bytes'
  [[ "$(file_mode "$TMP/etc/systemd/system/9router.service")" == 600 ]] || \
    fail 'installer did not restore the original unit permissions'
  assert_file "$TMP/root/.9router/existing-data"
  grep -Fqx 'keep-this-data' "$TMP/root/.9router/existing-data" || \
    fail 'installer changed existing data-directory content'
  ! compgen -G "$TMP/etc/systemd/system/9router.service.new.*" >/dev/null || \
    fail 'installer left a new-unit staging file'
  ! compgen -G "$TMP/etc/systemd/system/9router.service.backup.*" >/dev/null || \
    fail 'installer left a unit backup after rollback'
  grep -Fqx 'enabled' "$TMP/systemctl.enabled" ||
    fail 'installer did not restore the previous enabled state'
  assert_file "$TMP/systemctl.wants-link"
}

test_installer_uses_only_test_paths_and_preserves_existing_data() {
  new_install_tmp
  make_fakes
  prepare_existing_unit
  if ! (cd / && run_installer "$TMP/output"); then
    sed -n '1,160p' "$TMP/output" >&2
    fail 'installer failed in isolated test mode'
  fi

  assert_file "$TMP/usr/local/sbin/9router-update"
  assert_file "$TMP/etc/systemd/system/9router.service"
  cmp "$SERVICE_UNIT" "$TMP/etc/systemd/system/9router.service" ||
    fail 'installer did not install the new unit'
  [[ "$(file_mode "$TMP/etc/systemd/system/9router.service")" == 644 ]] ||
    fail 'installer did not set the new unit permissions'
  assert_file "$TMP/root/.9router/existing-data"
  grep -Fqx 'keep-this-data' "$TMP/root/.9router/existing-data" ||
    fail 'installer changed existing data-directory content'
  ! compgen -G "$TMP/etc/systemd/system/9router.service.backup.*" >/dev/null ||
    fail 'installer did not clean its unit backup after success'
  assert_event_log \
    'systemctl is-enabled 9router' \
    'systemctl is-active --quiet 9router' \
    'cp backup-unit' \
    'install updater' \
    'install unit' \
    'mv install-unit' \
    'systemctl daemon-reload' \
    'systemctl enable 9router' \
    'git clone' \
    'systemctl start 9router' \
    'systemctl is-active --quiet 9router' \
    'rm cleanup-backup'
  cleanup
  TMP=""
}

test_installer_rolls_back_unit_on_failure() {
  local scenario
  local failure_env

  for scenario in unit daemon_reload enable updater; do
    case "$scenario" in
      unit) failure_env=NINEROUTER_TEST_INSTALL_FAIL=unit ;;
      daemon_reload) failure_env=NINEROUTER_TEST_DAEMON_RELOAD_FAIL_ONCE=1 ;;
      enable) failure_env=NINEROUTER_TEST_ENABLE_FAIL=1 ;;
      updater) failure_env=NINEROUTER_TEST_BUILD_FAIL=1 ;;
    esac
    new_install_tmp
    make_fakes
    prepare_existing_unit
    if run_installer "$TMP/output-$scenario" env "$failure_env"; then
      fail "installer succeeded despite $scenario failure"
    fi
    assert_old_unit_restored
    if [[ "$scenario" != unit ]]; then
      grep -q '^daemon-reload$' "$TMP/systemctl.log" ||
        fail "installer did not reload systemd after $scenario rollback"
    fi
    if [[ "$scenario" == updater ]]; then
      assert_event_log \
        'systemctl is-enabled 9router' \
        'systemctl is-active --quiet 9router' \
        'cp backup-unit' \
        'install updater' \
        'install unit' \
        'mv install-unit' \
        'systemctl daemon-reload' \
        'systemctl enable 9router' \
        'git clone' \
        'mv restore-unit' \
        'systemctl daemon-reload' \
        'systemctl enable 9router' \
        'systemctl start 9router'
    fi
    cleanup
    TMP=""
  done
}

test_first_install_failure_removes_new_unit() {
  new_install_tmp
  make_fakes
  printf 'not-found\n' >"$TMP/systemctl.enabled"
  rm -f -- "$TMP/systemctl.wants-link"
  mkdir -p "$TMP/root/.9router"
  printf 'keep-this-data\n' >"$TMP/root/.9router/existing-data"
  if run_installer "$TMP/output" env NINEROUTER_TEST_BUILD_FAIL=1; then
    fail 'first installer run succeeded despite updater failure'
  fi
  assert_not_exists "$TMP/etc/systemd/system/9router.service"
  assert_file "$TMP/root/.9router/existing-data"
  grep -Fqx 'keep-this-data' "$TMP/root/.9router/existing-data" ||
    fail 'first install changed existing data-directory content'
  grep -q '^daemon-reload$' "$TMP/systemctl.log" ||
    fail 'first-install rollback did not reload systemd'
  grep -Fqx 'disabled' "$TMP/systemctl.enabled" ||
    fail 'first-install rollback did not disable the service'
  assert_not_exists "$TMP/systemctl.wants-link"
  cleanup
  TMP=""
}

test_health_failure_after_switch_keeps_new_entrypoints() {
  new_install_tmp
  make_fakes
  prepare_existing_unit
  mkdir -p "$TMP/opt/9router"
  printf 'old-runtime\n' >"$TMP/opt/9router/current-marker"
  printf 'old-updater\n' >"$TMP/usr/local/sbin/9router-update"
  chmod 0700 "$TMP/usr/local/sbin/9router-update"
  if run_installer "$TMP/output-health" env NINEROUTER_TEST_CURL_MODE=fail; then
    fail 'installer succeeded despite post-switch health failure'
  fi
  cmp "$SERVICE_UNIT" "$TMP/etc/systemd/system/9router.service" ||
    fail 'post-switch health failure rolled back the new unit'
  cmp "$UPDATER" "$TMP/usr/local/sbin/9router-update" ||
    fail 'post-switch health failure rolled back the new updater'
  grep -Fqx 'enabled' "$TMP/systemctl.enabled" ||
    fail 'post-switch health failure changed enabled state'
  assert_file "$TMP/opt/9router.previous/current-marker"
  assert_file "$TMP/opt/9router/.runtime/custom-server.js"
  grep -Fq '旧版本保留在' "$TMP/output-health" ||
    fail 'post-switch health failure did not retain updater recovery details'
  cleanup
  TMP=""
}

test_backup_copy_failures_never_restore_partial_material() {
  local scenario

  for scenario in updater unit; do
    new_install_tmp
    make_fakes
    prepare_existing_unit
    prepare_existing_updater
    if run_installer "$TMP/output-cp-$scenario" env "NINEROUTER_TEST_CP_FAIL=$scenario"; then
      fail "installer succeeded despite $scenario backup copy failure"
    fi
    assert_old_unit_restored
    assert_old_updater_restored
    assert_no_fixed_recovery_materials
    ! grep -Fq 'partial-' "$TMP/etc/systemd/system/9router.service" || \
      fail 'partial unit backup replaced the live unit'
    ! grep -Fq 'partial-' "$TMP/usr/local/sbin/9router-update" || \
      fail 'partial updater backup replaced the live updater'
    cleanup
    TMP=""
  done
}

test_installer_rejects_unknown_enable_state_and_query_error_before_writes() {
  local scenario

  for scenario in unknown query_error query_error_with_state; do
    new_install_tmp
    make_fakes
    prepare_existing_unit
    prepare_existing_updater
    if [[ "$scenario" == unknown ]]; then
      printf 'static\n' >"$TMP/systemctl.enabled"
      if run_installer "$TMP/output-$scenario"; then
        fail 'installer accepted an unrecognized is-enabled state'
      fi
    elif [[ "$scenario" == query_error ]]; then
      if run_installer "$TMP/output-$scenario" env NINEROUTER_TEST_IS_ENABLED_QUERY_ERROR=1; then
        fail 'installer continued after is-enabled query failure'
      fi
    else
      if run_installer "$TMP/output-$scenario" env NINEROUTER_TEST_IS_ENABLED_QUERY_ERROR_WITH_STATE=1; then
        fail 'installer trusted is-enabled output from a failed query'
      fi
    fi
    cmp "$TMP/original-unit" "$TMP/etc/systemd/system/9router.service" || \
      fail "installer wrote the unit after $scenario is-enabled result"
    assert_old_updater_restored
    ! grep -Fq 'install updater' "$TMP/install-events.log" || \
      fail "installer wrote the updater after $scenario is-enabled result"
    assert_not_exists "$TMP/run/9router-update.phase"
    assert_no_fixed_recovery_materials
    cleanup
    TMP=""
  done
}

test_updater_writes_atomic_phase_protocol() {
  new_tmp
  make_fakes
  mkdir -p "$TMP/opt/9router"
  : >"$TMP/opt/9router/current-marker"
  if ! run_updater "$TMP/output-phase-success"; then
    fail 'updater failed while recording the success phase protocol'
  fi
  [[ "$(<"$TMP/phase.log")" == "$(printf '%s\n' \
    preparing building stopping old_move_intent old_moved \
    new_move_intent new_moved started healthy)" ]] || \
    fail 'updater did not atomically record every success phase in order'
  grep -Fqx 'healthy' "$TMP/run/9router-update.phase" || \
    fail 'updater did not retain the final healthy phase'
  [[ "$(file_mode "$TMP/run/9router-update.phase")" == 600 ]] || \
    fail 'updater phase file is not private'
  cleanup
  TMP=""

  new_tmp
  make_fakes
  mkdir -p "$TMP/opt/9router"
  : >"$TMP/opt/9router/current-marker"
  if run_updater "$TMP/output-phase-failure" env NINEROUTER_TEST_CURL_MODE=fail; then
    fail 'updater succeeded despite the phase-protocol health failure'
  fi
  [[ "$(<"$TMP/phase.log")" == "$(printf '%s\n' \
    preparing building stopping old_move_intent old_moved \
    new_move_intent new_moved started health_failed)" ]] || \
    fail 'updater did not atomically record health_failed after the switch'
  grep -Fqx 'health_failed' "$TMP/run/9router-update.phase" || \
    fail 'updater did not retain the final health_failed phase'
  cleanup
  TMP=""
}

test_healthy_phase_is_durable_before_previous_cleanup() {
  new_tmp
  make_fakes
  mkdir -p "$TMP/opt/9router"
  : >"$TMP/opt/9router/current-marker"
  if run_updater "$TMP/output-healthy-phase-failure" env NINEROUTER_TEST_FAIL_PHASE=healthy; then
    fail 'updater succeeded despite failure to persist the healthy phase'
  fi
  assert_file "$TMP/opt/9router.previous/current-marker"
  assert_file "$TMP/opt/9router/.runtime/custom-server.js"
  grep -Fqx 'started' "$TMP/run/9router-update.phase" || \
    fail 'failed healthy write did not leave the prior durable phase'
  cleanup
  TMP=""
}

test_preexisting_previous_is_classified_as_pre_switch() {
  new_install_tmp
  make_fakes
  prepare_existing_unit
  prepare_existing_updater
  mkdir -p "$TMP/opt/9router" "$TMP/opt/9router.previous"
  : >"$TMP/opt/9router/current-marker"
  : >"$TMP/opt/9router.previous/preexisting-marker"
  if run_installer "$TMP/output-preexisting-previous"; then
    fail 'installer succeeded despite a preexisting previous directory'
  fi
  assert_old_unit_restored
  assert_old_updater_restored
  assert_file "$TMP/opt/9router/current-marker"
  assert_file "$TMP/opt/9router.previous/preexisting-marker"
  grep -Fqx 'preparing' "$TMP/run/9router-update.phase" || \
    fail 'preexisting previous was not recorded as a pre-switch failure'
  ! grep -Fq '人工恢复：' "$TMP/output-preexisting-previous" || \
    fail 'preexisting previous was incorrectly advertised as rollback material'
  assert_no_fixed_recovery_materials
  cleanup
  TMP=""
}

test_switch_barrier_preserves_new_entrypoints_and_fixed_recovery_materials() {
  new_install_tmp
  make_fakes
  prepare_legacy_installation
  if run_installer "$TMP/output-switch-race" env NINEROUTER_TEST_FAIL_OLD_MOVE_AFTER_MUTATION=1; then
    fail 'installer succeeded despite failure at the old-directory switch barrier'
  fi
  cmp "$SERVICE_UNIT" "$TMP/etc/systemd/system/9router.service" || \
    fail 'switch-race failure rolled back the new unit'
  cmp "$UPDATER" "$TMP/usr/local/sbin/9router-update" || \
    fail 'switch-race failure rolled back the new updater'
  grep -Fqx 'old_move_intent' "$TMP/run/9router-update.phase" || \
    fail 'old move intent was not retained when mv mutated before failing'
  cmp "$TMP/original-unit" "$TMP/run/9router-install-recovery.unit" || \
    fail 'switch-race failure did not retain the old unit recovery material'
  cmp "$TMP/original-updater" "$TMP/run/9router-install-recovery.updater" || \
    fail 'switch-race failure did not retain the old updater recovery material'
  grep -Fq '现场无法证明未发生切换' "$TMP/output-switch-race" || \
    fail 'switch-race failure did not report the uncertain intent scene'
  cleanup
  TMP=""
}

test_move_intent_failures_use_strict_scene_classification() {
  new_install_tmp
  make_fakes
  prepare_legacy_installation
  if run_installer "$TMP/output-old-before" env \
    NINEROUTER_TEST_FAIL_OLD_MOVE_BEFORE_MUTATION=1; then
    fail 'installer succeeded despite old-directory mv failing before mutation'
  fi
  grep -Fqx 'old_move_intent' "$TMP/run/9router-update.phase" || \
    fail 'old-directory mv failure did not retain old_move_intent'
  assert_file "$TMP/opt/9router/legacy-entrypoint"
  assert_not_exists "$TMP/opt/9router.previous"
  assert_old_unit_restored
  assert_old_updater_restored
  assert_no_fixed_recovery_materials
  cleanup
  TMP=""

  new_install_tmp
  make_fakes
  prepare_legacy_installation
  if run_installer "$TMP/output-new-before-existing" env \
    NINEROUTER_TEST_FAIL_NEW_MOVE_BEFORE_MUTATION=1; then
    fail 'installer succeeded despite new-directory mv failing before mutation'
  fi
  grep -Fqx 'new_move_intent' "$TMP/run/9router-update.phase" || \
    fail 'new-directory mv failure did not retain new_move_intent'
  assert_not_exists "$TMP/opt/9router"
  assert_file "$TMP/opt/9router.previous/legacy-entrypoint"
  assert_dir "$TMP/opt/9router-build"
  cmp "$SERVICE_UNIT" "$TMP/etc/systemd/system/9router.service" || \
    fail 'new-move intent with a committed old move rolled back the new unit'
  cmp "$UPDATER" "$TMP/usr/local/sbin/9router-update" || \
    fail 'new-move intent with a committed old move rolled back the new updater'
  cmp "$TMP/original-unit" "$TMP/run/9router-install-recovery.unit" || \
    fail 'new-move intent did not preserve old unit recovery material'
  cmp "$TMP/original-updater" "$TMP/run/9router-install-recovery.updater" || \
    fail 'new-move intent did not preserve old updater recovery material'
  grep -Fq '现场无法证明未发生切换' "$TMP/output-new-before-existing" || \
    fail 'new-move intent did not report the committed-old uncertain scene'
  cleanup
  TMP=""

  new_install_tmp
  make_fakes
  printf 'not-found\n' >"$TMP/systemctl.enabled"
  rm -f -- "$TMP/systemctl.wants-link"
  if run_installer "$TMP/output-new-before-first" env \
    NINEROUTER_TEST_FAIL_NEW_MOVE_BEFORE_MUTATION=1; then
    fail 'first install succeeded despite new-directory mv failing before mutation'
  fi
  grep -Fqx 'new_move_intent' "$TMP/run/9router-update.phase" || \
    fail 'first-install new mv failure did not retain new_move_intent'
  assert_not_exists "$TMP/opt/9router"
  assert_dir "$TMP/opt/9router-build"
  assert_not_exists "$TMP/etc/systemd/system/9router.service"
  assert_not_exists "$TMP/usr/local/sbin/9router-update"
  assert_no_fixed_recovery_materials
  cleanup
  TMP=""

  new_install_tmp
  make_fakes
  prepare_legacy_installation
  if run_installer "$TMP/output-old-replaced" env \
    NINEROUTER_TEST_REPLACE_ROOT_AT_OLD_INTENT=1 \
    NINEROUTER_TEST_DISPLACED_ROOT="$TMP/opt/displaced-original-root"; then
    fail 'installer succeeded after ROOT was replaced during old_move_intent'
  fi
  grep -Fqx 'old_move_intent' "$TMP/run/9router-update.phase" || \
    fail 'replaced ROOT did not retain old_move_intent'
  assert_file "$TMP/opt/9router/forged-root"
  assert_file "$TMP/opt/displaced-original-root/legacy-entrypoint"
  cmp "$SERVICE_UNIT" "$TMP/etc/systemd/system/9router.service" || \
    fail 'replaced ROOT was misclassified as an unchanged pre-switch scene'
  cmp "$UPDATER" "$TMP/usr/local/sbin/9router-update" || \
    fail 'replaced ROOT caused the old updater to be automatically restored'
  cmp "$TMP/original-unit" "$TMP/run/9router-install-recovery.unit" || \
    fail 'replaced ROOT did not preserve the old unit material'
  grep -Fq '现场无法证明未发生切换' "$TMP/output-old-replaced" || \
    fail 'replaced ROOT did not produce the uncertain-scene diagnostic'
  cleanup
  TMP=""
}

test_post_switch_failure_supports_legacy_joint_recovery() {
  local legacy_exec
  local legacy_output

  new_install_tmp
  make_fakes
  prepare_legacy_installation
  if run_installer "$TMP/output-joint-recovery" env NINEROUTER_TEST_CURL_MODE=fail; then
    fail 'installer succeeded despite post-switch health failure'
  fi
  cmp "$SERVICE_UNIT" "$TMP/etc/systemd/system/9router.service" || \
    fail 'post-switch failure did not preserve the new unit现场'
  cmp "$UPDATER" "$TMP/usr/local/sbin/9router-update" || \
    fail 'post-switch failure did not preserve the new updater现场'
  cmp "$TMP/original-unit" "$TMP/run/9router-install-recovery.unit" || \
    fail 'old unit recovery material has incorrect bytes'
  cmp "$TMP/original-updater" "$TMP/run/9router-install-recovery.updater" || \
    fail 'old updater recovery material has incorrect bytes'
  [[ "$(file_mode "$TMP/run/9router-install-recovery.unit")" == 600 ]] || \
    fail 'old unit recovery material lost its permissions'
  [[ "$(file_mode "$TMP/run/9router-install-recovery.updater")" == 700 ]] || \
    fail 'old updater recovery material lost its permissions'
  grep -Fqx 'enabled' "$TMP/run/9router-install-recovery.enable-state" || \
    fail 'original enable state was not retained'
  [[ "$(file_mode "$TMP/run/9router-install-recovery.enable-state")" == 600 ]] || \
    fail 'enable-state recovery material is not private'
  assert_file "$TMP/run/9router-install-recover"
  [[ "$(file_mode "$TMP/run/9router-install-recover")" == 700 ]] || \
    fail 'joint recovery script is not private and executable'
  grep -Fqx "人工联合恢复：$TMP/run/9router-install-recover" \
    "$TMP/output-joint-recovery" || \
    fail 'installer did not output the single fixed recovery script command'
  ! grep -Eq '联合恢复命令：.*(systemctl|mv|rm)' "$TMP/output-joint-recovery" || \
    fail 'installer still emitted an inline joint recovery command'
  if ! run_fixed_script "$TMP/output-run-recovery" \
    "$TMP/run/9router-install-recover"; then
    fail 'fixed joint recovery script failed on its validated scene'
  fi
  cmp "$TMP/original-unit" "$TMP/etc/systemd/system/9router.service" || \
    fail 'joint recovery did not restore the legacy unit'
  assert_old_updater_restored
  legacy_exec="$(sed -n 's/^ExecStart=//p' "$TMP/etc/systemd/system/9router.service")"
  legacy_output="$("$legacy_exec")"
  [[ "$legacy_output" == legacy-entrypoint-ok ]] || \
    fail 'restored legacy unit entrypoint is not executable'
  assert_file "$TMP/opt/9router.failed/.runtime/custom-server.js"
  assert_no_fixed_recovery_materials
  if run_installer "$TMP/output-existing-failed-root"; then
    fail 'installer accepted a retained failed-code directory before writing entrypoints'
  fi
  grep -Fq '失败代码检查目录' "$TMP/output-existing-failed-root" || \
    fail 'retained failed-code refusal did not explain how to unblock installation'
  cmp "$TMP/original-unit" "$TMP/etc/systemd/system/9router.service" || \
    fail 'retained failed-code refusal changed the restored unit'
  assert_old_updater_restored
  cleanup
  TMP=""
}

test_joint_recovery_terminal_revalidates_systemd_and_rejects_bad_step() {
  new_install_tmp
  make_fakes
  prepare_legacy_installation
  if run_installer "$TMP/output-terminal-setup" env NINEROUTER_TEST_CURL_MODE=fail; then
    fail 'installer succeeded despite terminal-recovery setup failure'
  fi
  if run_fixed_script "$TMP/output-terminal-script-remove" \
    "$TMP/run/9router-install-recover" env \
      NINEROUTER_TEST_FAIL_RECOVERY_SCRIPT_REMOVE=1; then
    fail 'recovery succeeded despite fixed-script cleanup failure'
  fi
  assert_file "$TMP/run/9router-install-recover"
  assert_not_exists "$TMP/run/9router-install-recover.step"
  ln -s /dev/null "$TMP/run/9router-install-recover.step"
  printf 'inactive\n' >"$TMP/systemctl.state"
  printf 'disabled\n' >"$TMP/systemctl.enabled"
  rm -f -- "$TMP/systemctl.wants-link"
  if run_fixed_script "$TMP/output-terminal-bad-step" \
    "$TMP/run/9router-install-recover"; then
    fail 'joint recovery treated an unsafe step path as a genuinely absent step'
  fi
  assert_file "$TMP/run/9router-install-recover"
  [[ -L "$TMP/run/9router-install-recover.step" ]] || \
    fail 'bad-step refusal unexpectedly removed the unsafe step path'
  rm -f -- "$TMP/run/9router-install-recover.step"
  if ! run_fixed_script "$TMP/output-terminal-resume" \
    "$TMP/run/9router-install-recover"; then
    fail 'joint recovery could not resume from its validated step-missing terminal scene'
  fi
  grep -Fqx 'active' "$TMP/systemctl.state" || \
    fail 'step-missing terminal recovery did not restore the original active state'
  grep -Fqx 'enabled' "$TMP/systemctl.enabled" || \
    fail 'step-missing terminal recovery did not restore the original enable state'
  assert_no_fixed_recovery_materials
  cleanup
  TMP=""
}

test_generated_script_intermediate_write_failures_are_not_published() {
  new_install_tmp
  make_fakes
  prepare_legacy_installation
  if run_installer "$TMP/output-joint-write-failure" env \
    NINEROUTER_TEST_CURL_MODE=fail \
    NINEROUTER_TEST_FAIL_SCRIPT_WRITE_AT=5; then
    fail 'installer succeeded despite joint-script write-failure setup'
  fi
  assert_not_exists "$TMP/run/9router-install-recover"
  assert_not_exists "$TMP/run/9router-install-recover.step"
  assert_not_exists "$TMP/run/9router-install-recovery.unit.work"
  assert_not_exists "$TMP/run/9router-install-recovery.updater.work"
  cmp "$TMP/original-unit" "$TMP/run/9router-install-recovery.unit" || \
    fail 'joint-script write failure consumed the old unit material'
  cmp "$TMP/original-updater" "$TMP/run/9router-install-recovery.updater" || \
    fail 'joint-script write failure consumed the old updater material'
  cmp "$SERVICE_UNIT" "$TMP/etc/systemd/system/9router.service" || \
    fail 'joint-script write failure changed the retained new unit'
  cmp "$UPDATER" "$TMP/usr/local/sbin/9router-update" || \
    fail 'joint-script write failure changed the retained new updater'
  cleanup
  TMP=""

  new_install_tmp
  make_fakes
  prepare_legacy_installation
  if run_installer "$TMP/output-joint-write-retry" env \
    NINEROUTER_TEST_CURL_MODE=fail; then
    fail 'joint-script normal retry setup unexpectedly succeeded'
  fi
  assert_file "$TMP/run/9router-install-recover"
  [[ "$(file_mode "$TMP/run/9router-install-recover")" == 700 ]] || \
    fail 'joint-script normal retry did not publish a complete 0700 script'
  cleanup
  TMP=""

  new_install_tmp
  make_fakes
  printf 'not-found\n' >"$TMP/systemctl.enabled"
  rm -f -- "$TMP/systemctl.wants-link"
  if run_installer "$TMP/output-cleanup-write-failure" env \
    NINEROUTER_TEST_CURL_MODE=fail \
    NINEROUTER_TEST_FAIL_SCRIPT_WRITE_AT=5; then
    fail 'installer succeeded despite cleanup-script write-failure setup'
  fi
  assert_not_exists "$TMP/run/9router-install-cleanup"
  assert_not_exists "$TMP/run/9router-install-cleanup.step"
  assert_not_exists "$TMP/run/9router-install-recovery.unit"
  assert_not_exists "$TMP/run/9router-install-recovery.updater"
  grep -Fqx 'not-found' "$TMP/run/9router-install-recovery.enable-state" || \
    fail 'cleanup-script write failure consumed the enable-state material'
  grep -Fqx 'health_failed' "$TMP/run/9router-update.phase" || \
    fail 'cleanup-script write failure consumed the phase material'
  cmp "$SERVICE_UNIT" "$TMP/etc/systemd/system/9router.service" || \
    fail 'cleanup-script write failure changed the retained new unit'
  cmp "$UPDATER" "$TMP/usr/local/sbin/9router-update" || \
    fail 'cleanup-script write failure changed the retained new updater'
  cleanup
  TMP=""

  new_install_tmp
  make_fakes
  printf 'not-found\n' >"$TMP/systemctl.enabled"
  rm -f -- "$TMP/systemctl.wants-link"
  if run_installer "$TMP/output-cleanup-write-retry" env \
    NINEROUTER_TEST_CURL_MODE=fail; then
    fail 'cleanup-script normal retry setup unexpectedly succeeded'
  fi
  assert_file "$TMP/run/9router-install-cleanup"
  [[ "$(file_mode "$TMP/run/9router-install-cleanup")" == 700 ]] || \
    fail 'cleanup-script normal retry did not publish a complete 0700 script'
  cleanup
  TMP=""
}

test_joint_recovery_script_resumes_after_each_partial_failure() {
  local legacy_exec

  new_install_tmp
  make_fakes
  prepare_legacy_installation
  if run_installer "$TMP/output-create-resumable" env NINEROUTER_TEST_CURL_MODE=fail; then
    fail 'installer succeeded despite resumable-recovery setup failure'
  fi

  if run_fixed_script "$TMP/output-recovery-active" \
    "$TMP/run/9router-install-recover" env NINEROUTER_TEST_STOP_REMAINS_ACTIVE=1; then
    fail 'joint recovery changed the scene while stop left the service active'
  fi
  assert_file "$TMP/opt/9router/.runtime/custom-server.js"
  assert_file "$TMP/opt/9router.previous/legacy-entrypoint"
  cmp "$SERVICE_UNIT" "$TMP/etc/systemd/system/9router.service" || \
    fail 'active-service refusal changed the new unit'

  if run_fixed_script "$TMP/output-recovery-root-stage" \
    "$TMP/run/9router-install-recover" env \
      NINEROUTER_TEST_FAIL_RECOVERY_ROOT_STAGE_AFTER_MUTATION=1; then
    fail 'root staging failure was not surfaced'
  fi
  assert_not_exists "$TMP/opt/9router"
  assert_file "$TMP/opt/9router.failed/.runtime/custom-server.js"
  assert_file "$TMP/opt/9router.previous/legacy-entrypoint"

  if run_fixed_script "$TMP/output-recovery-previous" \
    "$TMP/run/9router-install-recover" env \
      NINEROUTER_TEST_FAIL_RECOVERY_PREVIOUS_AFTER_MUTATION=1; then
    fail 'previous restore failure was not surfaced'
  fi
  assert_file "$TMP/opt/9router/legacy-entrypoint"
  assert_not_exists "$TMP/opt/9router.previous"

  if run_fixed_script "$TMP/output-recovery-unit" \
    "$TMP/run/9router-install-recover" env \
      NINEROUTER_TEST_FAIL_RECOVERY_UNIT_AFTER_MUTATION=1; then
    fail 'unit restore failure was not surfaced'
  fi
  cmp "$TMP/original-unit" "$TMP/etc/systemd/system/9router.service" || \
    fail 'unit mutation failure did not reach the strict completed scene'
  cmp "$TMP/original-unit" "$TMP/run/9router-install-recovery.unit" || \
    fail 'unit mutation failure consumed the immutable recovery material'

  if run_fixed_script "$TMP/output-recovery-updater" \
    "$TMP/run/9router-install-recover" env \
      NINEROUTER_TEST_FAIL_RECOVERY_UPDATER_AFTER_MUTATION=1; then
    fail 'updater restore failure was not surfaced'
  fi
  assert_old_updater_restored
  cmp "$TMP/original-updater" "$TMP/run/9router-install-recovery.updater" || \
    fail 'updater mutation failure consumed the immutable recovery material'

  if run_fixed_script "$TMP/output-recovery-daemon" \
    "$TMP/run/9router-install-recover" env \
      NINEROUTER_TEST_RECOVERY_DAEMON_RELOAD_FAIL_ONCE=1; then
    fail 'recovery daemon-reload failure was not surfaced'
  fi
  assert_file "$TMP/run/9router-install-recover"
  if ! run_fixed_script "$TMP/output-recovery-resumed" \
    "$TMP/run/9router-install-recover"; then
    fail 'joint recovery could not resume after partial failures'
  fi
  legacy_exec="$(sed -n 's/^ExecStart=//p' "$TMP/etc/systemd/system/9router.service")"
  [[ "$("$legacy_exec")" == legacy-entrypoint-ok ]] || \
    fail 'resumed joint recovery did not restore the legacy entrypoint'
  assert_no_fixed_recovery_materials
  cleanup
  TMP=""
}

test_joint_recovery_rejects_replaced_lock_inode() {
  new_install_tmp
  make_fakes
  prepare_legacy_installation
  if run_installer "$TMP/output-lock-inode-setup" env NINEROUTER_TEST_CURL_MODE=fail; then
    fail 'installer succeeded despite lock-inode recovery setup failure'
  fi
  /bin/mv "$TMP/run/9router-update.lock" "$TMP/run/replaced-old.lock"
  : >"$TMP/run/9router-update.lock"
  if run_fixed_script "$TMP/output-replaced-lock" \
    "$TMP/run/9router-install-recover"; then
    fail 'joint recovery accepted a replaced shared-lock inode'
  fi
  grep -Fq '锁 inode 已变化' "$TMP/output-replaced-lock" || \
    fail 'replaced-lock refusal did not identify the inode mismatch'
  cmp "$TMP/original-unit" "$TMP/run/9router-install-recovery.unit" || \
    fail 'replaced-lock refusal changed recovery materials'
  cleanup
  TMP=""

  new_install_tmp
  make_fakes
  prepare_legacy_installation
  if run_installer "$TMP/output-lock-race-setup" env NINEROUTER_TEST_CURL_MODE=fail; then
    fail 'installer succeeded despite lock-race recovery setup failure'
  fi
  if run_fixed_script "$TMP/output-lock-race" \
    "$TMP/run/9router-install-recover" env \
      NINEROUTER_TEST_REPLACE_LOCK_BEFORE_FD_STAT=1; then
    fail 'joint recovery accepted a lock path replaced between path and FD checks'
  fi
  grep -Fq 'FD 校验期间发生变化' "$TMP/output-lock-race" || \
    fail 'lock path/FD race refusal did not identify the second path mismatch'
  cmp "$TMP/original-unit" "$TMP/run/9router-install-recovery.unit" || \
    fail 'lock path/FD race refusal changed recovery materials'
  assert_file "$TMP/opt/9router.previous/legacy-entrypoint"
  cleanup
  TMP=""
}

test_joint_recovery_script_refuses_concurrent_updater_lock() {
  local launcher_pid
  local updater_pid

  new_install_tmp
  make_fakes
  prepare_legacy_installation
  if run_installer "$TMP/output-create-recovery" env NINEROUTER_TEST_CURL_MODE=fail; then
    fail 'installer succeeded despite the recovery-script setup failure'
  fi
  assert_file "$TMP/run/9router-install-recover"

  mkdir -p "$TMP/parallel/opt" "$TMP/parallel/run"
  NINEROUTER_TEST_UPDATER_PID_FILE="$TMP/parallel/updater.pid" \
    run_updater "$TMP/parallel/output" env \
      NINEROUTER_ROOT="$TMP/parallel/opt/9router" \
      NINEROUTER_BUILD_DIR="$TMP/parallel/opt/9router-build" \
      NINEROUTER_PREVIOUS_DIR="$TMP/parallel/opt/9router.previous" \
      NINEROUTER_PHASE_FILE="$TMP/parallel/run/9router-update.phase" \
      NINEROUTER_TEST_PREVIOUS_DIR="$TMP/parallel/opt/9router.previous" \
      NINEROUTER_TEST_SEND_TERM_ON_START=1 \
      NINEROUTER_TEST_START_BLOCKED_MARKER="$TMP/parallel/updater-running" &
  launcher_pid=$!
  while [[ ! -e "$TMP/parallel/updater-running" ]]; do
    /bin/sleep 0.01
  done
  updater_pid="$(<"$TMP/parallel/updater.pid")"

  if run_fixed_script "$TMP/output-recovery-locked" \
    "$TMP/run/9router-install-recover"; then
    fail 'joint recovery ran while an updater held the shared lock'
  fi
  grep -Fq '已有 9Router 安装或更新事务正在执行' "$TMP/output-recovery-locked" || \
    fail 'joint recovery lock refusal was not explicit'
  cmp "$TMP/original-unit" "$TMP/run/9router-install-recovery.unit" || \
    fail 'lock-contended recovery changed the old unit material'
  cmp "$TMP/original-updater" "$TMP/run/9router-install-recovery.updater" || \
    fail 'lock-contended recovery changed the old updater material'
  assert_file "$TMP/opt/9router.previous/legacy-entrypoint"

  kill -TERM "$updater_pid"
  : >"$TMP/term-go"
  wait "$launcher_pid" || true
  cleanup
  TMP=""
}

test_first_install_post_switch_cleanup_preserves_code_and_allows_retry() {
  new_install_tmp
  make_fakes
  printf 'not-found\n' >"$TMP/systemctl.enabled"
  rm -f -- "$TMP/systemctl.wants-link"
  mkdir -p "$TMP/root/.9router"
  printf 'keep-first-install-data\n' >"$TMP/root/.9router/existing-data"
  if run_installer "$TMP/output-first-post-switch" env NINEROUTER_TEST_CURL_MODE=fail; then
    fail 'first install succeeded despite post-switch health failure'
  fi
  cmp "$SERVICE_UNIT" "$TMP/etc/systemd/system/9router.service" || \
    fail 'first-install failure did not preserve the new unit现场'
  cmp "$UPDATER" "$TMP/usr/local/sbin/9router-update" || \
    fail 'first-install failure did not preserve the new updater现场'
  assert_not_exists "$TMP/run/9router-install-recovery.unit"
  assert_not_exists "$TMP/run/9router-install-recovery.updater"
  grep -Fqx 'not-found' "$TMP/run/9router-install-recovery.enable-state" || \
    fail 'first-install failure did not retain the original not-found state'
  assert_file "$TMP/run/9router-install-cleanup"
  [[ "$(file_mode "$TMP/run/9router-install-cleanup")" == 700 ]] || \
    fail 'first-install cleanup script is not private and executable'
  grep -Fqx "首次安装安全收尾：$TMP/run/9router-install-cleanup" \
    "$TMP/output-first-post-switch" || \
    fail 'first-install failure did not output its fixed cleanup script'
  assert_not_exists "$TMP/run/9router-install-recover"
  : >"$TMP/opt/9router/first-attempt-marker"

  if run_fixed_script "$TMP/output-first-cleanup-locked" \
    "$TMP/run/9router-install-cleanup" env NINEROUTER_TEST_LOCK_FAIL=1; then
    fail 'first-install cleanup ran while the shared update lock was held'
  fi
  cmp "$SERVICE_UNIT" "$TMP/etc/systemd/system/9router.service" || \
    fail 'lock-contended cleanup changed the new unit'
  cmp "$UPDATER" "$TMP/usr/local/sbin/9router-update" || \
    fail 'lock-contended cleanup changed the new updater'

  if run_fixed_script "$TMP/output-first-cleanup-unit" \
    "$TMP/run/9router-install-cleanup" env \
      NINEROUTER_TEST_FAIL_CLEANUP_UNIT_AFTER_MUTATION=1; then
    fail 'first-install unit cleanup failure was not surfaced'
  fi
  assert_not_exists "$TMP/etc/systemd/system/9router.service"
  cmp "$UPDATER" "$TMP/usr/local/sbin/9router-update" || \
    fail 'unit cleanup failure also removed the updater'
  if run_fixed_script "$TMP/output-first-cleanup-updater" \
    "$TMP/run/9router-install-cleanup" env \
      NINEROUTER_TEST_REALISTIC_MISSING_UNIT=1 \
      NINEROUTER_TEST_FAIL_CLEANUP_UPDATER_AFTER_MUTATION=1; then
    fail 'first-install updater cleanup failure was not surfaced'
  fi
  assert_not_exists "$TMP/usr/local/sbin/9router-update"
  if run_fixed_script "$TMP/output-first-cleanup-daemon" \
    "$TMP/run/9router-install-cleanup" env \
      NINEROUTER_TEST_REALISTIC_MISSING_UNIT=1 \
      NINEROUTER_TEST_RECOVERY_DAEMON_RELOAD_FAIL_ONCE=1; then
    fail 'first-install cleanup daemon-reload failure was not surfaced'
  fi
  assert_file "$TMP/run/9router-install-cleanup"
  if run_fixed_script "$TMP/output-first-cleanup-script-remove" \
    "$TMP/run/9router-install-cleanup" env \
      NINEROUTER_TEST_REALISTIC_MISSING_UNIT=1 \
      NINEROUTER_TEST_FAIL_CLEANUP_SCRIPT_REMOVE=1; then
    fail 'first-install cleanup succeeded despite fixed-script cleanup failure'
  fi
  assert_file "$TMP/run/9router-install-cleanup"
  assert_not_exists "$TMP/run/9router-install-cleanup.step"
  ln -s /dev/null "$TMP/run/9router-install-cleanup.step"
  if run_fixed_script "$TMP/output-first-cleanup-bad-step" \
    "$TMP/run/9router-install-cleanup" env \
      NINEROUTER_TEST_REALISTIC_MISSING_UNIT=1; then
    fail 'first-install cleanup treated an unsafe step path as genuinely absent'
  fi
  assert_file "$TMP/run/9router-install-cleanup"
  [[ -L "$TMP/run/9router-install-cleanup.step" ]] || \
    fail 'first-install bad-step refusal removed the unsafe step path'
  rm -f -- "$TMP/run/9router-install-cleanup.step"
  if ! run_fixed_script "$TMP/output-first-cleanup" \
    "$TMP/run/9router-install-cleanup" env \
      NINEROUTER_TEST_REALISTIC_MISSING_UNIT=1; then
    fail 'first-install cleanup could not resume from a validated terminal scene'
  fi
  assert_not_exists "$TMP/etc/systemd/system/9router.service"
  assert_not_exists "$TMP/usr/local/sbin/9router-update"
  assert_not_exists "$TMP/run/9router-update.phase"
  assert_not_exists "$TMP/run/9router-install-recovery.enable-state"
  assert_not_exists "$TMP/run/9router-install-cleanup"
  assert_file "$TMP/opt/9router/.runtime/custom-server.js"
  grep -Fqx 'keep-first-install-data' "$TMP/root/.9router/existing-data" || \
    fail 'first-install cleanup touched the persistent data directory'

  if run_installer "$TMP/output-first-retry-failure" env \
    NINEROUTER_TEST_CURL_MODE=fail; then
    fail 'retry unexpectedly succeeded during the repeated-health-failure scenario'
  fi
  assert_file "$TMP/run/9router-install-cleanup"
  if ! run_fixed_script "$TMP/output-second-cleanup" \
    "$TMP/run/9router-install-cleanup"; then
    fail 'repeated post-switch failure did not provide a usable cleanup script'
  fi
  assert_file "$TMP/opt/9router/.runtime/custom-server.js"
  assert_file "$TMP/opt/9router/.previous-release-inspection/first-attempt-marker"
  assert_no_fixed_recovery_materials

  if ! run_installer "$TMP/output-first-retry"; then
    fail 'installer could not retry after repeated first-install cleanup'
  fi
  cmp "$SERVICE_UNIT" "$TMP/etc/systemd/system/9router.service" || \
    fail 'retry did not install the new unit'
  cmp "$UPDATER" "$TMP/usr/local/sbin/9router-update" || \
    fail 'retry did not install the new updater'
  grep -Fqx 'healthy' "$TMP/run/9router-update.phase" || \
    fail 'retry did not complete a healthy update'
  grep -Fqx 'keep-first-install-data' "$TMP/root/.9router/existing-data" || \
    fail 'retry touched the persistent data directory'
  assert_no_fixed_recovery_materials
  cleanup
  TMP=""
}

test_phase_and_recovery_paths_are_guarded() {
  new_tmp
  make_fakes
  if run_updater "$TMP/output-phase-outside" env NINEROUTER_PHASE_FILE=/run/9router-update.phase; then
    fail 'root test updater accepted a phase file outside the test root'
  fi
  assert_empty_file "$TMP/git.log"
  cleanup
  TMP=""

  new_tmp
  make_fakes
  : >"$TMP/phase-target"
  ln -s "$TMP/phase-target" "$TMP/run/9router-update.phase"
  if run_updater "$TMP/output-phase-symlink"; then
    fail 'updater accepted a symlink phase file'
  fi
  assert_empty_file "$TMP/git.log"
  cleanup
  TMP=""

  new_install_tmp
  make_fakes
  if run_installer "$TMP/output-recovery-outside" env \
    NINEROUTER_RECOVERY_UNIT=/run/9router-install-recovery.unit; then
    fail 'root test installer accepted recovery material outside the test root'
  fi
  ! grep -Fq 'install updater' "$TMP/install-events.log" || \
    fail 'installer wrote an entrypoint before rejecting an unsafe recovery path'
  cleanup
  TMP=""
}

test_masked_unit_symlink_is_restored_before_switch() {
  new_install_tmp
  make_fakes
  prepare_masked_installation
  if run_installer "$TMP/output-masked" env \
    NINEROUTER_TEST_BUILD_FAIL=1 NINEROUTER_TEST_REALISTIC_MASK=1; then
    fail 'masked installation succeeded despite pre-switch build failure'
  fi
  [[ -L "$TMP/etc/systemd/system/9router.service" ]] ||
    fail 'pre-switch failure did not restore the masked unit symlink'
  [[ "$(readlink "$TMP/etc/systemd/system/9router.service")" == /dev/null ]] ||
    fail 'restored masked unit does not target /dev/null'
  assert_old_updater_restored
  grep -Fqx 'masked' "$TMP/systemctl.enabled" ||
    fail 'pre-switch failure did not restore the masked enable state'
  assert_no_fixed_recovery_materials
  cleanup
  TMP=""
}

test_masked_active_service_is_rejected_before_entrypoint_writes() {
  new_install_tmp
  make_fakes
  prepare_masked_installation
  printf 'active\n' >"$TMP/systemctl.state"
  if run_installer "$TMP/output-masked-active" env NINEROUTER_TEST_REALISTIC_MASK=1; then
    fail 'installer accepted an initially active masked service'
  fi
  grep -Fq '请先 unmask' "$TMP/output-masked-active" || \
    fail 'masked-active refusal did not explain the required unmask action'
  [[ -L "$TMP/etc/systemd/system/9router.service" && \
    "$(readlink "$TMP/etc/systemd/system/9router.service")" == /dev/null ]] || \
    fail 'masked-active refusal changed the masked unit'
  assert_old_updater_restored
  assert_file "$TMP/opt/9router/current-marker"
  ! grep -Fq 'cp backup-' "$TMP/install-events.log" || \
    fail 'masked-active refusal created a recovery backup'
  ! grep -Fq 'install updater' "$TMP/install-events.log" || \
    fail 'masked-active refusal wrote an entrypoint'
  assert_no_fixed_recovery_materials
  cleanup
  TMP=""
}

test_non_mask_unit_symlink_is_rejected_before_entrypoint_writes() {
  new_install_tmp
  make_fakes
  prepare_existing_updater
  mkdir -p "$TMP/opt/9router"
  printf '[Service]\nExecStart=/legacy/linked-router\n' >"$TMP/linked-unit-target"
  rm -f -- "$TMP/etc/systemd/system/9router.service"
  ln -s "$TMP/linked-unit-target" "$TMP/etc/systemd/system/9router.service"
  if run_installer "$TMP/output-linked-unit"; then
    fail 'installer accepted a non-mask unit symlink'
  fi
  [[ -L "$TMP/etc/systemd/system/9router.service" ]] ||
    fail 'installer replaced the rejected unit symlink'
  [[ "$(readlink "$TMP/etc/systemd/system/9router.service")" == "$TMP/linked-unit-target" ]] ||
    fail 'installer changed the rejected unit symlink target'
  assert_old_updater_restored
  ! grep -Fq 'install updater' "$TMP/install-events.log" ||
    fail 'installer wrote an updater before rejecting the unit symlink'
  assert_no_fixed_recovery_materials
  cleanup
  TMP=""
}

test_updater_symlink_is_rejected_before_entrypoint_writes() {
  new_install_tmp
  make_fakes
  prepare_existing_unit
  printf '#!/usr/bin/env bash\nprintf linked-updater\\n\n' >"$TMP/linked-updater-target"
  chmod 0700 "$TMP/linked-updater-target"
  rm -f -- "$TMP/usr/local/sbin/9router-update"
  ln -s "$TMP/linked-updater-target" "$TMP/usr/local/sbin/9router-update"
  if run_installer "$TMP/output-linked-updater"; then
    fail 'installer accepted an updater symlink'
  fi
  [[ -L "$TMP/usr/local/sbin/9router-update" ]] ||
    fail 'installer replaced the rejected updater symlink'
  [[ "$(readlink "$TMP/usr/local/sbin/9router-update")" == "$TMP/linked-updater-target" ]] ||
    fail 'installer changed the rejected updater symlink target'
  cmp "$TMP/original-unit" "$TMP/etc/systemd/system/9router.service" ||
    fail 'installer changed the unit before rejecting the updater symlink'
  ! grep -Fq 'install updater' "$TMP/install-events.log" ||
    fail 'installer wrote an updater before rejecting the updater symlink'
  assert_no_fixed_recovery_materials
  cleanup
  TMP=""
}

test_installer_lock_contention_prevents_phase_and_entrypoint_mutation() {
  new_install_tmp
  make_fakes
  prepare_existing_unit
  prepare_existing_updater
  printf 'old_moved\n' >"$TMP/run/9router-update.phase"
  if run_installer "$TMP/output-installer-lock" env NINEROUTER_TEST_LOCK_FAIL=1; then
    fail 'installer ran despite deployment-lock contention'
  fi
  cmp "$TMP/original-unit" "$TMP/etc/systemd/system/9router.service" ||
    fail 'lock-contended installer changed the unit'
  assert_old_updater_restored
  grep -Fqx 'old_moved' "$TMP/run/9router-update.phase" ||
    fail 'lock-contended installer cleared another updater phase'
  ! grep -Fq 'install updater' "$TMP/install-events.log" ||
    fail 'lock-contended installer wrote a new updater'
  assert_no_fixed_recovery_materials
  cleanup
  TMP=""
}

test_pre_switch_stop_race_restarts_the_restored_legacy_service() {
  new_install_tmp
  make_fakes
  prepare_legacy_installation
  if run_installer "$TMP/output-stop-race" env NINEROUTER_TEST_CREATE_PREVIOUS_ON_STOP=1; then
    fail 'installer succeeded despite previous appearing after stop'
  fi
  cmp "$TMP/original-unit" "$TMP/etc/systemd/system/9router.service" ||
    fail 'stop-race failure did not restore the legacy unit'
  assert_old_updater_restored
  grep -Fqx 'active' "$TMP/systemctl.state" ||
    fail 'stop-race failure left the previously active legacy service stopped'
  assert_file "$TMP/opt/9router/legacy-entrypoint"
  assert_file "$TMP/opt/9router.previous/race-marker"
  assert_no_fixed_recovery_materials
  cleanup
  TMP=""
}

test_installer_rejects_unsafe_test_roots() {
  local unsafe_root

  new_install_tmp
  make_fakes
  for unsafe_root in /opt /etc /run; do
    if run_installer "$TMP/output-${unsafe_root#/}" env "NINEROUTER_TEST_ROOT=$unsafe_root"; then
      fail "installer accepted unsafe test root: $unsafe_root"
    fi
    test -s "$TMP/output-${unsafe_root#/}" ||
      fail "installer did not reject unsafe test root before commands: $unsafe_root"
  done
  assert_empty_file "$TMP/install-events.log"
  cleanup
  TMP=""
}

test_successful_update_installs_flat_runtime_and_restarts_service() {
  new_tmp
  make_fakes
  mkdir -p "$TMP/opt/9router"
  : >"$TMP/opt/9router/current-marker"
  printf 'lock-sentinel\n' >"$TMP/run/9router-update.lock"
  if ! run_updater "$TMP/output"; then
    fail 'updater failed during the successful update scenario'
  fi

  assert_file "$TMP/opt/9router/.runtime/custom-server.js"
  assert_file "$TMP/opt/9router/.runtime/server.js"
  assert_dir "$TMP/opt/9router/.runtime/open-sse"
  assert_file "$TMP/opt/9router/.runtime/open-sse/standalone-marker"
  assert_file "$TMP/opt/9router/.runtime/open-sse/source-marker"
  assert_not_exists "$TMP/opt/9router/.runtime/open-sse/open-sse"
  assert_dir "$TMP/opt/9router/.runtime/src/mitm"
  assert_file "$TMP/opt/9router/.runtime/src/mitm/server.js"
  assert_file "$TMP/opt/9router/.runtime/src/mitm/runtime-helper.js"
  assert_not_exists "$TMP/opt/9router/.runtime/src/mitm/mitm"
  assert_not_exists "$TMP/opt/9router.previous"
  grep -Fqx 'lock-sentinel' "$TMP/run/9router-update.lock" || \
    fail 'existing lock file was truncated'
  grep -q '^npm ci$' "$TMP/npm.log" || fail 'dependencies were not installed with npm ci'
  grep -q '^stop 9router$' "$TMP/systemctl.log" || fail 'service was not stopped'
  grep -q '^is-active --quiet 9router$' "$TMP/systemctl.log" || fail 'service activity was not checked'
  grep -q '^start 9router$' "$TMP/systemctl.log" || fail 'service was not started'
  cleanup
  TMP=""
}

test_rejects_unsafe_data_overlapping_and_symlink_paths() {
  new_tmp
  make_fakes
  if run_updater "$TMP/output" env NINEROUTER_ROOT=relative; then
    fail 'relative root was accepted'
  fi
  if run_updater "$TMP/output-data" env NINEROUTER_ROOT=/root/.9router; then
    fail 'data directory was accepted as root'
  fi
  if run_updater "$TMP/output-overlap" env \
    "NINEROUTER_ROOT=$TMP/opt/9router" \
    "NINEROUTER_BUILD_DIR=$TMP/opt/9router/build"; then
    fail 'overlapping root and build paths were accepted'
  fi
  if run_updater "$TMP/output-alias" env "NINEROUTER_ROOT=$TMP/opt/../opt/9router"; then
    fail 'dot-segment alias was accepted'
  fi
  mkdir -p "$TMP/opt/real-root"
  ln -s "$TMP/opt/real-root" "$TMP/opt/root-link"
  if run_updater "$TMP/output-symlink" env "NINEROUTER_ROOT=$TMP/opt/root-link"; then
    fail 'symlink root was accepted'
  fi
  assert_empty_file "$TMP/git.log"
  assert_empty_file "$TMP/npm.log"
  assert_empty_file "$TMP/systemctl.log"
  cleanup
  TMP=""
}

test_rejects_unsafe_or_overlapping_lock_before_opening_it() {
  new_tmp
  make_fakes
  printf 'lock-sentinel\n' >"$TMP/run/9router-update.lock"
  if run_updater "$TMP/output-overlap" env \
    "NINEROUTER_ROOT=$TMP/run" \
    "NINEROUTER_BUILD_DIR=$TMP/opt/9router-build" \
    "NINEROUTER_PREVIOUS_DIR=$TMP/opt/9router.previous" \
    "NINEROUTER_LOCK_FILE=$TMP/run/9router-update.lock"; then
    fail 'lock file overlapping root was accepted'
  fi
  grep -Fqx 'lock-sentinel' "$TMP/run/9router-update.lock" || \
    fail 'unsafe lock was truncated before validation'

  cleanup
  TMP=""
  new_tmp
  make_fakes
  : >"$TMP/run/real.lock"
  ln -s "$TMP/run/real.lock" "$TMP/run/lock-link"
  if run_updater "$TMP/output-symlink" env "NINEROUTER_LOCK_FILE=$TMP/run/lock-link"; then
    fail 'symlink lock file was accepted'
  fi
  cleanup
  TMP=""
}

test_existing_previous_refuses_update_without_deletion() {
  new_tmp
  make_fakes
  mkdir -p "$TMP/opt/9router.previous"
  : >"$TMP/opt/9router.previous/old-marker"
  if run_updater "$TMP/output"; then
    fail 'updater accepted an existing previous release'
  fi

  assert_file "$TMP/opt/9router.previous/old-marker"
  assert_empty_file "$TMP/git.log"
  assert_empty_file "$TMP/npm.log"
  assert_empty_file "$TMP/systemctl.log"
  cleanup
  TMP=""
}

test_stop_failure_and_active_service_abort_before_switch() {
  new_tmp
  make_fakes
  mkdir -p "$TMP/opt/9router"
  : >"$TMP/opt/9router/current-marker"
  if run_updater "$TMP/output-stop" env NINEROUTER_TEST_STOP_FAIL=1; then
    fail 'updater continued after a failed stop'
  fi
  assert_file "$TMP/opt/9router/current-marker"
  assert_not_exists "$TMP/opt/9router.previous"

  if run_updater "$TMP/output-active" env NINEROUTER_TEST_STOP_REMAINS_ACTIVE=1; then
    fail 'updater continued while the service remained active'
  fi
  assert_file "$TMP/opt/9router/current-marker"
  assert_not_exists "$TMP/opt/9router.previous"
  if run_updater "$TMP/output-query-error" env NINEROUTER_TEST_STOP_QUERY_ERROR=1; then
    fail 'updater continued after a failed stop-state query'
  fi
  assert_file "$TMP/opt/9router/current-marker"
  assert_not_exists "$TMP/opt/9router.previous"
  cleanup
  TMP=""
}

test_cross_filesystem_deployment_aborts_before_stop() {
  new_tmp
  make_fakes
  mkdir -p "$TMP/opt/9router"
  : >"$TMP/opt/9router/current-marker"
  if run_updater "$TMP/output" env NINEROUTER_TEST_CROSS_DEVICE=1; then
    fail 'updater accepted root, build, and previous on different devices'
  fi
  assert_file "$TMP/opt/9router/current-marker"
  assert_not_exists "$TMP/opt/9router.previous"
  assert_empty_file "$TMP/systemctl.log"
  cleanup
  TMP=""
}

test_first_install_cross_filesystem_aborts_before_start() {
  new_tmp
  make_fakes
  if run_updater "$TMP/output" env NINEROUTER_TEST_CROSS_DEVICE=1; then
    fail 'first install accepted build and destination on different devices'
  fi
  assert_not_exists "$TMP/opt/9router"
  assert_empty_file "$TMP/systemctl.log"
  cleanup
  TMP=""
}

test_build_and_node_check_failures_do_not_stop_service() {
  new_tmp
  make_fakes
  mkdir -p "$TMP/opt/9router"
  : >"$TMP/opt/9router/current-marker"
  if run_updater "$TMP/output-build" env NINEROUTER_TEST_BUILD_FAIL=1; then
    fail 'updater continued after build failure'
  fi
  assert_file "$TMP/opt/9router/current-marker"
  assert_empty_file "$TMP/systemctl.log"

  cleanup
  TMP=""
  new_tmp
  make_fakes
  mkdir -p "$TMP/opt/9router"
  : >"$TMP/opt/9router/current-marker"
  if run_updater "$TMP/output-node" env NINEROUTER_TEST_NODE_CHECK_FAIL=1; then
    fail 'updater continued after Node syntax-check failure'
  fi
  assert_file "$TMP/opt/9router/current-marker"
  assert_empty_file "$TMP/systemctl.log"
  cleanup
  TMP=""
}

test_previous_recheck_prevents_racy_nested_move() {
  new_tmp
  make_fakes
  mkdir -p "$TMP/opt/9router"
  : >"$TMP/opt/9router/current-marker"
  if run_updater "$TMP/output" env NINEROUTER_TEST_CREATE_PREVIOUS_ON_STOP=1; then
    fail 'updater switched despite a newly-created previous directory'
  fi
  assert_file "$TMP/opt/9router/current-marker"
  assert_file "$TMP/opt/9router.previous/race-marker"
  assert_not_exists "$TMP/opt/9router.previous/9router/current-marker"
  cleanup
  TMP=""
}

test_lock_contention_prevents_mutation() {
  new_tmp
  make_fakes
  if run_updater "$TMP/output" env NINEROUTER_TEST_LOCK_FAIL=1; then
    fail 'updater ran despite lock contention'
  fi
  assert_empty_file "$TMP/git.log"
  assert_empty_file "$TMP/npm.log"
  assert_empty_file "$TMP/systemctl.log"
  cleanup
  TMP=""
}

test_health_failure_preserves_previous_release_without_unlocked_inline_recovery() {
  new_tmp
  make_fakes
  mkdir -p "$TMP/opt/9router"
  : >"$TMP/opt/9router/current-marker"
  if run_updater "$TMP/output" env NINEROUTER_TEST_CURL_MODE=fail; then
    fail 'updater succeeded despite a failed health check'
  fi

  assert_dir "$TMP/opt/9router.previous"
  assert_file "$TMP/opt/9router.previous/current-marker"
  grep -Fq '未生成不持锁的内联恢复命令' "$TMP/output" || \
    fail 'standalone updater did not explain the locked recovery requirement'
  ! grep -Eq '人工恢复：.*(systemctl|mv|rm)' "$TMP/output" || \
    fail 'standalone updater advertised an unlocked inline recovery command'
  cleanup
  TMP=""
}

test_first_install_health_failure_has_no_invalid_recovery_instruction() {
  new_tmp
  make_fakes
  if run_updater "$TMP/output" env NINEROUTER_TEST_CURL_MODE=fail; then
    fail 'first install succeeded despite a failed health check'
  fi

  assert_not_exists "$TMP/opt/9router.previous"
  grep -Fq '未发现可恢复的旧版本目录' "$TMP/output" || \
    fail 'first-install failure did not explain the missing previous release'
  ! grep -Fq '人工恢复：' "$TMP/output" || \
    fail 'first-install failure advertised an invalid recovery command'
  cleanup
  TMP=""
}

test_rejects_non_login_redirect_and_accepts_login_redirect() {
  new_tmp
  make_fakes
  if run_updater "$TMP/output-bad" env NINEROUTER_TEST_CURL_MODE=bad-redirect; then
    fail 'arbitrary redirect was accepted as healthy'
  fi
  assert_dir "$TMP/opt/9router"

  cleanup
  TMP=""
  new_tmp
  make_fakes
  if ! run_updater "$TMP/output-login" env NINEROUTER_TEST_CURL_MODE=login-redirect; then
    fail 'login redirect was rejected as unhealthy'
  fi
  assert_not_exists "$TMP/opt/9router.previous"
  cleanup
  TMP=""
}

test_health_rejects_inactive_service_and_trap_preserves_recovery_state() {
  new_tmp
  make_fakes
  if run_updater "$TMP/output-inactive" env NINEROUTER_TEST_START_INACTIVE=1; then
    fail 'inactive service was accepted as healthy'
  fi
  assert_not_exists "$TMP/opt/9router.previous"
  assert_empty_file "$TMP/curl.log"

  cleanup
  TMP=""
  new_tmp
  make_fakes
  mkdir -p "$TMP/opt/9router"
  : >"$TMP/opt/9router/current-marker"
  NINEROUTER_TEST_UPDATER_PID_FILE="$TMP/updater.pid" \
    run_updater "$TMP/output-term" env NINEROUTER_TEST_SEND_TERM_ON_START=1 &
  launcher_pid=$!
  while [[ ! -s "$TMP/updater.pid" ]]; do
    /bin/sleep 0.01
  done
  updater_pid="$(<"$TMP/updater.pid")"
  while ! grep -q '^start 9router$' "$TMP/systemctl.log"; do
    /bin/sleep 0.01
  done
  kill -TERM "$updater_pid"
  : >"$TMP/term-go"
  if wait "$launcher_pid"; then
    fail 'updater ignored SIGTERM during the critical switch'
  fi
  assert_file "$TMP/opt/9router.previous/current-marker"
  assert_dir "$TMP/opt/9router"
  grep -Fq '阶段：new_moved' "$TMP/output-term" || \
    fail 'trap did not retain the pre-start in-progress phase'
  grep -Fq '构建目录已成为正式目录' "$TMP/output-term" || \
    fail 'trap did not report the actual post-switch state'
  grep -Fq '未生成不持锁的内联恢复命令' "$TMP/output-term" || \
    fail 'trap did not retain the locked-recovery diagnostic'
  cleanup
  TMP=""
}

if [[ ! -f "$UPDATER" ]]; then
  fail "deploy/linux/9router-update is missing"
fi

test_service_unit_uses_fixed_production_paths_without_credentials
test_installer_has_root_guard_and_preserves_data_directory
test_installer_uses_only_test_paths_and_preserves_existing_data
test_installer_rolls_back_unit_on_failure
test_first_install_failure_removes_new_unit
test_health_failure_after_switch_keeps_new_entrypoints
test_backup_copy_failures_never_restore_partial_material
test_installer_rejects_unknown_enable_state_and_query_error_before_writes
test_updater_writes_atomic_phase_protocol
test_healthy_phase_is_durable_before_previous_cleanup
test_preexisting_previous_is_classified_as_pre_switch
test_switch_barrier_preserves_new_entrypoints_and_fixed_recovery_materials
test_move_intent_failures_use_strict_scene_classification
test_post_switch_failure_supports_legacy_joint_recovery
test_joint_recovery_terminal_revalidates_systemd_and_rejects_bad_step
test_generated_script_intermediate_write_failures_are_not_published
test_joint_recovery_script_resumes_after_each_partial_failure
test_joint_recovery_rejects_replaced_lock_inode
test_joint_recovery_script_refuses_concurrent_updater_lock
test_first_install_post_switch_cleanup_preserves_code_and_allows_retry
test_phase_and_recovery_paths_are_guarded
test_masked_unit_symlink_is_restored_before_switch
test_masked_active_service_is_rejected_before_entrypoint_writes
test_non_mask_unit_symlink_is_rejected_before_entrypoint_writes
test_updater_symlink_is_rejected_before_entrypoint_writes
test_installer_lock_contention_prevents_phase_and_entrypoint_mutation
test_pre_switch_stop_race_restarts_the_restored_legacy_service
test_installer_rejects_unsafe_test_roots
test_successful_update_installs_flat_runtime_and_restarts_service
test_rejects_unsafe_data_overlapping_and_symlink_paths
test_rejects_unsafe_or_overlapping_lock_before_opening_it
test_existing_previous_refuses_update_without_deletion
test_stop_failure_and_active_service_abort_before_switch
test_cross_filesystem_deployment_aborts_before_stop
test_first_install_cross_filesystem_aborts_before_start
test_build_and_node_check_failures_do_not_stop_service
test_previous_recheck_prevents_racy_nested_move
test_lock_contention_prevents_mutation
test_health_failure_preserves_previous_release_without_unlocked_inline_recovery
test_first_install_health_failure_has_no_invalid_recovery_instruction
test_rejects_non_login_redirect_and_accepts_login_redirect
test_health_rejects_inactive_service_and_trap_preserves_recovery_state
printf 'PASS: 9router Linux updater tests\n'
