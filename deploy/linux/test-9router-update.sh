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
for argument in "$@"; do
  if [[ "${NINEROUTER_TEST_CROSS_DEVICE:-0}" == 1 && "$argument" == *9router-build* ]]; then
    printf '2\n'
    exit 0
  fi
done
printf '1\n'
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
case "$1" in
  stop)
    [[ "$2" == 9router ]]
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
      kill -TERM "$PPID"
    fi
    ;;
  is-active)
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

  chmod +x "$TMP/bin/git" "$TMP/bin/flock" "$TMP/bin/npm" "$TMP/bin/node" "$TMP/bin/stat" \
    "$TMP/bin/mv" "$TMP/bin/systemctl" "$TMP/bin/curl" "$TMP/bin/sleep"
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
    NINEROUTER_MV="$TMP/bin/mv" \
    NINEROUTER_STAT="$TMP/bin/stat" \
    NINEROUTER_FLOCK="$TMP/bin/flock" \
    NINEROUTER_SLEEP="$TMP/bin/sleep" \
    NINEROUTER_NPM="$TMP/bin/npm" \
    NINEROUTER_SYSTEMCTL="$TMP/bin/systemctl" \
    NINEROUTER_CURL="$TMP/bin/curl" \
    NINEROUTER_NODE="$TMP/bin/node" \
    NINEROUTER_TEST_SYSTEMCTL_LOG="$TMP/systemctl.log" \
    NINEROUTER_TEST_SYSTEMCTL_STATE="$TMP/systemctl.state" \
    NINEROUTER_TEST_PREVIOUS_DIR="$TMP/opt/9router.previous" \
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
  grep -Fq '阶段：starting-new-in-progress' "$TMP/output-term" || \
    fail 'trap did not retain the pre-start in-progress phase'
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
test_rejects_unsafe_or_overlapping_lock_before_opening_it
test_existing_previous_refuses_update_without_deletion
test_stop_failure_and_active_service_abort_before_switch
test_cross_filesystem_deployment_aborts_before_stop
test_build_and_node_check_failures_do_not_stop_service
test_previous_recheck_prevents_racy_nested_move
test_lock_contention_prevents_mutation
test_health_failure_preserves_previous_release_and_reports_safe_recovery
test_first_install_health_failure_has_no_invalid_recovery_instruction
test_rejects_non_login_redirect_and_accepts_login_redirect
test_health_rejects_inactive_service_and_trap_preserves_recovery_state
printf 'PASS: 9router Linux updater tests\n'
