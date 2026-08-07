#!/usr/bin/env bash

# Integration tests for the Linux updater.  Keep every filesystem mutation
# below the temporary directory so this script is safe to run locally or in CI.
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPDATER="$ROOT_DIR/deploy/linux/9router-update"
TMP=""

cleanup() {
  [[ -n "$TMP" ]] && rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
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

make_fakes() {
  mkdir -p "$TMP/bin" "$TMP/opt" "$TMP/run"
  : >"$TMP/systemctl.log"

  cat >"$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
set -eu
if [[ "$1" != clone ]]; then
  echo "unexpected git command: $*" >&2
  exit 64
fi
dest="${@: -1}"
mkdir -p "$dest"
printf '{"scripts":{"build":"next build"}}\n' >"$dest/package.json"
EOF

  cat >"$TMP/bin/npm" <<'EOF'
#!/usr/bin/env bash
set -eu
if [[ "$1" != run || "$2" != build ]]; then
  echo "unexpected npm command: $*" >&2
  exit 64
fi
if [[ "${NINEROUTER_TEST_BUILD_FAIL:-0}" == 1 ]]; then
  exit 42
fi
mkdir -p .next/standalone node_modules/node-forge node_modules/next src/mitm open-sse
: >.next/standalone/server.js
: >custom-server.js
EOF

  cat >"$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s %s\n' "$1" "$2" >>"$NINEROUTER_TEST_SYSTEMCTL_LOG"
EOF

  cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
if [[ "${NINEROUTER_TEST_CURL_FAIL:-0}" == 1 ]]; then
  exit 22
fi
printf 'ok\n'
EOF

  chmod +x "$TMP/bin/git" "$TMP/bin/npm" "$TMP/bin/systemctl" "$TMP/bin/curl"
}

run_updater() {
  local output_file="$1"
  shift
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
  "$@" bash "$UPDATER" >"$output_file" 2>&1
}

test_successful_update_installs_runtime_and_restarts_service() {
  TMP="$(mktemp -d)"
  make_fakes
  if ! run_updater "$TMP/output"; then
    fail 'updater failed during the successful update scenario'
  fi

  assert_file "$TMP/opt/9router/.runtime/custom-server.js"
  assert_file "$TMP/opt/9router/.runtime/server.js"
  assert_dir "$TMP/opt/9router/.runtime/open-sse"
  assert_dir "$TMP/opt/9router/.runtime/src/mitm"
  assert_not_exists "$TMP/opt/9router.previous"
  grep -q '^stop 9router$' "$TMP/systemctl.log" || fail 'service was not stopped'
  grep -q '^start 9router$' "$TMP/systemctl.log" || fail 'service was not started'
  cleanup
  TMP=""
}

test_build_failure_keeps_current_service_running() {
  TMP="$(mktemp -d)"
  make_fakes
  mkdir -p "$TMP/opt/9router"
  : >"$TMP/opt/9router/current-marker"
  if run_updater "$TMP/output" env NINEROUTER_TEST_BUILD_FAIL=1; then
    fail 'updater succeeded despite a failed build'
  fi

  assert_file "$TMP/opt/9router/current-marker"
  ! grep -q '^stop 9router$' "$TMP/systemctl.log" || fail 'service stopped after build failure'
  cleanup
  TMP=""
}

test_health_check_failure_preserves_previous_release_and_reports_recovery() {
  TMP="$(mktemp -d)"
  make_fakes
  mkdir -p "$TMP/opt/9router"
  : >"$TMP/opt/9router/current-marker"
  if run_updater "$TMP/output" env NINEROUTER_TEST_CURL_FAIL=1; then
    fail 'updater succeeded despite a failed health check'
  fi

  grep -q '^start 9router$' "$TMP/systemctl.log" || fail 'new service was not started'
  assert_dir "$TMP/opt/9router.previous"
  assert_file "$TMP/opt/9router.previous/current-marker"
  grep -Fq "mv $TMP/opt/9router.previous $TMP/opt/9router" "$TMP/output" || \
    fail 'missing manual recovery command in updater output'
  cleanup
  TMP=""
}

if [[ ! -f "$UPDATER" ]]; then
  fail "deploy/linux/9router-update is missing; updater tests are intentionally red"
fi

test_successful_update_installs_runtime_and_restarts_service
test_build_failure_keeps_current_service_running
test_health_check_failure_preserves_previous_release_and_reports_recovery
printf 'PASS: 9router Linux updater tests\n'
