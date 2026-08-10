#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TEST_ROOT=""

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_executable() {
  local label="$1"
  local command_path="$2"

  [[ -x "$command_path" ]] || die "缺少可执行文件：$label ($command_path)"
}

validate_test_path() {
  local label="$1"
  local candidate="$2"
  local resolved

  resolved="$(/usr/bin/realpath -m -- "$candidate")" ||
    die "测试路径无法 realpath：$label"
  [[ "$resolved" == "$TEST_ROOT/"* ]] ||
    die "测试路径必须位于测试根：$label"
}

if [[ "$EUID" -ne 0 ]]; then
  die 'install.sh 必须以 root 身份运行'
fi

if [[ "${NINEROUTER_TEST_MODE:-0}" == 1 ]]; then
  TEST_ROOT="${NINEROUTER_TEST_ROOT:-}"
  [[ -n "$TEST_ROOT" ]] || die 'root 测试模式缺少 NINEROUTER_TEST_ROOT'
  TEST_ROOT="$(/usr/bin/realpath -e -- "$TEST_ROOT")" ||
    die 'root 测试根无法 realpath'
  [[ -d "$TEST_ROOT" && ! -L "$TEST_ROOT" ]] ||
    die 'root 测试根必须是非符号链接目录'

  for override in UPDATER_TARGET SERVICE_TARGET DATA_DIR SYSTEMCTL NODE NPM GIT CURL FLOCK MKDIR; do
    env_name="NINEROUTER_${override}"
    [[ -n "${!env_name+x}" ]] || die "root 测试模式缺少 $env_name"
  done

  UPDATER_TARGET="$NINEROUTER_UPDATER_TARGET"
  SERVICE_TARGET="$NINEROUTER_SERVICE_TARGET"
  DATA_DIR="$NINEROUTER_DATA_DIR"
  SYSTEMCTL="$NINEROUTER_SYSTEMCTL"
  NODE="$NINEROUTER_NODE"
  NPM="$NINEROUTER_NPM"
  GIT="$NINEROUTER_GIT"
  CURL="$NINEROUTER_CURL"
  FLOCK="$NINEROUTER_FLOCK"
  MKDIR="$NINEROUTER_MKDIR"

  for target in UPDATER_TARGET SERVICE_TARGET DATA_DIR SYSTEMCTL NODE NPM GIT CURL FLOCK MKDIR; do
    validate_test_path "$target" "${!target}"
  done
else
  for override in NINEROUTER_TEST_MODE NINEROUTER_TEST_ROOT NINEROUTER_UPDATER_TARGET NINEROUTER_SERVICE_TARGET NINEROUTER_DATA_DIR NINEROUTER_SYSTEMCTL NINEROUTER_NODE NINEROUTER_NPM NINEROUTER_GIT NINEROUTER_CURL NINEROUTER_FLOCK NINEROUTER_MKDIR; do
    [[ -z "${!override+x}" ]] || die "root 环境拒绝 $override 覆盖"
  done

  UPDATER_TARGET=/usr/local/sbin/9router-update
  SERVICE_TARGET=/etc/systemd/system/9router.service
  DATA_DIR=/root/.9router
  SYSTEMCTL=/usr/bin/systemctl
  NODE=/opt/node-v24.15.0-npm/node/bin/node
  NPM=/opt/node-v24.15.0-npm/node/bin/npm
  GIT=/usr/bin/git
  CURL=/usr/bin/curl
  FLOCK=/usr/bin/flock
  MKDIR=/bin/mkdir
fi

require_executable Node "$NODE"
require_executable npm "$NPM"
require_executable git "$GIT"
require_executable curl "$CURL"
require_executable flock "$FLOCK"
require_executable systemctl "$SYSTEMCTL"
require_executable mkdir "$MKDIR"

[[ -f "$SCRIPT_DIR/9router-update" ]] || die '缺少 deploy/linux/9router-update'
[[ -f "$SCRIPT_DIR/9router.service" ]] || die '缺少 deploy/linux/9router.service'

"$MKDIR" -p "${UPDATER_TARGET%/*}" "${SERVICE_TARGET%/*}"
/usr/bin/install -m 0755 "$SCRIPT_DIR/9router-update" "$UPDATER_TARGET"
/usr/bin/install -m 0644 "$SCRIPT_DIR/9router.service" "$SERVICE_TARGET"
"$MKDIR" -p "$DATA_DIR"
"$SYSTEMCTL" daemon-reload
"$SYSTEMCTL" enable 9router
"$UPDATER_TARGET"
