#!/usr/bin/env bash
set -u

# Integration tests for the Linux updater. Keep every mutation beneath a
# repository-local temporary directory so the suite is safe in CI.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPDATER="$ROOT_DIR/deploy/linux/9router-update"
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
  TMP="$(mktemp -d "$ROOT_DIR/.9router-update-test.XXXXXX")"
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

make_fakes() {
  mkdir -p "$TMP/bin" "$TMP/opt" "$TMP/run"
  : >"$TMP/systemctl.log"
  : >"$TMP/npm.log"
  : >"$TMP/curl.log"
  : >"$TMP/git.log"
  : >"$TMP/flock.log"
  printf 'active\n' >"$TMP/systemctl.state"

  cat >"$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$NINEROUTER_TEST_GIT_LOG"
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
[[ "${NINEROUTER_TEST_LOCK_FAIL:-0}" != 1 ]]
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
mkdir -p .next/standalone node_modules/node-forge node_modules/next src/mitm open-sse
: >.next/standalone/server.js
: >custom-server.js
: >src/mitm/mitm-marker
EOF

  cat >"$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$NINEROUTER_TEST_SYSTEMCTL_LOG"
case "$1" in
  stop)
    [[ "$2" == 9router ]]
    [[ "${NINEROUTER_TEST_STOP_FAIL:-0}" != 1 ]] || exit 5
    if [[ "${NINEROUTER_TEST_STOP_REMAINS_ACTIVE:-0}" == 1 ]]; then
      printf 'active\n' >"$NINEROUTER_TEST_SYSTEMCTL_STATE"
    else
      printf 'inactive\n' >"$NINEROUTER_TEST_SYSTEMCTL_STATE"
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
      kill -TERM "$PPID"
    fi
    ;;
  is-active)
    [[ "$2" == --quiet && "$3" == 9router ]]
    [[ "$(cat "$NINEROUTER_TEST_SYSTEMCTL_STATE")" == active ]] && exit 0
    exit 3
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

  chmod +x "$TMP/bin/git" "$TMP/bin/flock" "$TMP/bin/npm" \
    "$TMP/bin/systemctl" "$TMP/bin/curl" "$TMP/bin/sleep"
}

run_updater() {
  local output_file="$1"
  shift
  env \
    NINEROUTER_ROOT="$TMP/opt/9router" \
    NINEROUTER_BUILD_DIR="$TMP/opt/9router-build" \
    NINEROUTER_PREVIOUS_DIR="$TMP/opt/9router.previous" \
    NINEROUTER_LOCK_FILE="$TMP/run/9router-update.lock" \
    NINEROUTER_GIT="$TMP/bin/git" \
    NINEROUTER_NPM="$TMP/bin/npm" \
    NINEROUTER_SYSTEMCTL="$TMP/bin/systemctl" \
    NINEROUTER_CURL="$TMP/bin/curl" \
    NINEROUTER_NODE="$(command -v node)" \
    NINEROUTER_TEST_SYSTEMCTL_LOG="$TMP/systemctl.log" \
    NINEROUTER_TEST_SYSTEMCTL_STATE="$TMP/systemctl.state" \
    NINEROUTER_TEST_NPM_LOG="$TMP/npm.log" \
    NINEROUTER_TEST_CURL_LOG="$TMP/curl.log" \
    NINEROUTER_TEST_GIT_LOG="$TMP/git.log" \
    NINEROUTER_TEST_FLOCK_LOG="$TMP/flock.log" \
    PATH="$TMP/bin:$PATH" \
    "$@" bash "$UPDATER" >"$output_file" 2>&1
}

test_successful_update_installs_flat_runtime_and_restarts_service() {
  new_tmp
  make_fakes
  mkdir -p "$TMP/opt/9router"
  : >"$TMP/opt/9router/current-marker"
  if ! run_updater "$TMP/output"; then
    fail 'updater failed during the successful update scenario'
  fi

  assert_file "$TMP/opt/9router/.runtime/custom-server.js"
  assert_file "$TMP/opt/9router/.runtime/server.js"
  assert_dir "$TMP/opt/9router/.runtime/open-sse"
  assert_dir "$TMP/opt/9router/.runtime/src/mitm"
  assert_file "$TMP/opt/9router/.runtime/src/mitm/mitm-marker"
  assert_not_exists "$TMP/opt/9router/.runtime/src/mitm/mitm"
  assert_not_exists "$TMP/opt/9router.previous"
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

test_health_failure_preserves_previous_release_and_reports_safe_recovery() {
  new_tmp
  make_fakes
  mkdir -p "$TMP/opt/9router"
  : >"$TMP/opt/9router/current-marker"
  if run_updater "$TMP/output" env NINEROUTER_TEST_CURL_MODE=fail; then
    fail 'updater succeeded despite a failed health check'
  fi

  assert_dir "$TMP/opt/9router.previous"
  assert_file "$TMP/opt/9router.previous/current-marker"
  grep -Fq 'rm -rf -- ' "$TMP/output" || fail 'recovery command does not use rm --'
  grep -Fq "mv -- $TMP/opt/9router.previous $TMP/opt/9router" "$TMP/output" || \
    fail 'missing safe recovery move command'
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
  if run_updater "$TMP/output-term" env NINEROUTER_TEST_SEND_TERM_ON_START=1; then
    fail 'updater ignored SIGTERM during the critical switch'
  fi
  assert_file "$TMP/opt/9router.previous/current-marker"
  assert_dir "$TMP/opt/9router"
  grep -Fq '新版本已位于正式目录' "$TMP/output-term" || \
    fail 'trap did not report the actual post-switch state'
  grep -Fq '人工恢复：' "$TMP/output-term" || \
    fail 'trap did not retain a manual recovery instruction'
  cleanup
  TMP=""
}

if [[ ! -f "$UPDATER" ]]; then
  fail "deploy/linux/9router-update is missing"
fi

test_successful_update_installs_flat_runtime_and_restarts_service
test_rejects_unsafe_data_overlapping_and_symlink_paths
test_existing_previous_refuses_update_without_deletion
test_stop_failure_and_active_service_abort_before_switch
test_lock_contention_prevents_mutation
test_health_failure_preserves_previous_release_and_reports_safe_recovery
test_first_install_health_failure_has_no_invalid_recovery_instruction
test_rejects_non_login_redirect_and_accepts_login_redirect
test_health_rejects_inactive_service_and_trap_preserves_recovery_state
printf 'PASS: 9router Linux updater tests\n'
