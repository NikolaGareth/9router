#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TEST_ROOT=""
TEST_MODE="${NINEROUTER_TEST_MODE:-0}"
UNIT_EXISTED=0
UNIT_DEPLOYED=0
UNIT_TRANSACTION_ACTIVE=0
UNIT_BACKUP=""
UNIT_STAGED=""

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
  local parent
  local leaf
  local resolved_parent
  local resolved

  [[ "$candidate" == /* && "$candidate" != */./* && "$candidate" != */../* ]] ||
    die "测试路径必须是无别名的绝对路径：$label"
  parent="${candidate%/*}"
  leaf="${candidate##*/}"
  [[ -n "$parent" && "$leaf" != . && "$leaf" != .. ]] ||
    die "测试路径格式无效：$label"
  resolved_parent="$(cd -P -- "$parent" && pwd)" ||
    die "测试路径父目录无法 realpath：$label"
  resolved="$resolved_parent/$leaf"
  [[ ! -L "$resolved" ]] ||
    die "测试路径无法 realpath：$label"
  [[ "$resolved" == "$TEST_ROOT/"* ]] ||
    die "测试路径必须位于测试根：$label"
}

validate_test_root() {
  local input="$1"
  local repository_root

  TEST_ROOT="$(cd -P -- "$input" && pwd)" ||
    die 'root 测试根无法 realpath'
  [[ -d "$TEST_ROOT" && ! -L "$input" ]] ||
    die 'root 测试根必须是非符号链接目录'
  repository_root="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
  case "$TEST_ROOT" in
    /tmp/*|/private/tmp/*|"$repository_root"/.superpowers/*) ;;
    /opt|/opt/*|/etc|/etc/*|/run|/run/*)
      die "root 测试根明确拒绝生产路径：$TEST_ROOT"
      ;;
    *) die "root 测试根必须位于受限测试目录：$TEST_ROOT" ;;
  esac
}

restore_unit_after_failure() {
  local restore_failed=0

  (( UNIT_TRANSACTION_ACTIVE == 1 )) || return 0
  if [[ -n "$UNIT_STAGED" && -e "$UNIT_STAGED" ]]; then
    if ! "$RM" -f -- "$UNIT_STAGED"; then
      printf '无法删除未安装的 unit 临时文件：%s\n' "$UNIT_STAGED" >&2
      restore_failed=1
    fi
  fi
  if (( UNIT_EXISTED == 1 )); then
    if [[ -n "$UNIT_BACKUP" && ( -e "$UNIT_BACKUP" || -L "$UNIT_BACKUP" ) ]]; then
      if ! "$MV" -fT -- "$UNIT_BACKUP" "$SERVICE_TARGET"; then
        printf '无法原子恢复原有 systemd unit：%s\n' "$SERVICE_TARGET" >&2
        restore_failed=1
      fi
    else
      printf '缺少原有 systemd unit 备份，无法恢复：%s\n' "$SERVICE_TARGET" >&2
      restore_failed=1
    fi
  elif (( UNIT_DEPLOYED == 1 )); then
    if ! "$RM" -f -- "$SERVICE_TARGET"; then
      printf '无法移除首次安装的 systemd unit：%s\n' "$SERVICE_TARGET" >&2
      restore_failed=1
    fi
  fi
  if (( UNIT_DEPLOYED == 1 || UNIT_EXISTED == 1 )); then
    if ! "$SYSTEMCTL" daemon-reload; then
      printf 'unit 回滚后 systemd daemon-reload 失败\n' >&2
      restore_failed=1
    fi
  fi
  UNIT_TRANSACTION_ACTIVE=0
  return "$restore_failed"
}

on_exit() {
  local exit_code="$?"

  trap - EXIT
  if [[ "$exit_code" -ne 0 ]]; then
    restore_unit_after_failure || true
  fi
  exit "$exit_code"
}

if [[ "$TEST_MODE" != 1 && "$EUID" -ne 0 ]]; then
  die 'install.sh 必须以 root 身份运行'
fi

if [[ "$TEST_MODE" == 1 ]]; then
  test_root_input="${NINEROUTER_TEST_ROOT:-}"
  [[ -n "$test_root_input" ]] || die 'root 测试模式缺少 NINEROUTER_TEST_ROOT'
  validate_test_root "$test_root_input"

  for override in UPDATER_TARGET SERVICE_TARGET DATA_DIR SYSTEMCTL NODE NPM GIT CURL FLOCK MKDIR CP MV RM INSTALL; do
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
  CP="$NINEROUTER_CP"
  MV="$NINEROUTER_MV"
  RM="$NINEROUTER_RM"
  INSTALL="$NINEROUTER_INSTALL"

  for target in UPDATER_TARGET SERVICE_TARGET DATA_DIR SYSTEMCTL NODE NPM GIT CURL FLOCK MKDIR CP MV RM INSTALL; do
    validate_test_path "$target" "${!target}"
  done
else
  for override in NINEROUTER_TEST_MODE NINEROUTER_TEST_ROOT NINEROUTER_UPDATER_TARGET NINEROUTER_SERVICE_TARGET NINEROUTER_DATA_DIR NINEROUTER_SYSTEMCTL NINEROUTER_NODE NINEROUTER_NPM NINEROUTER_GIT NINEROUTER_CURL NINEROUTER_FLOCK NINEROUTER_MKDIR NINEROUTER_CP NINEROUTER_MV NINEROUTER_RM NINEROUTER_INSTALL; do
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
  CP=/bin/cp
  MV=/bin/mv
  RM=/bin/rm
  INSTALL=/usr/bin/install
fi

require_executable Node "$NODE"
require_executable npm "$NPM"
require_executable git "$GIT"
require_executable curl "$CURL"
require_executable flock "$FLOCK"
require_executable systemctl "$SYSTEMCTL"
require_executable mkdir "$MKDIR"
require_executable cp "$CP"
require_executable mv "$MV"
require_executable rm "$RM"
require_executable install "$INSTALL"

[[ -f "$SCRIPT_DIR/9router-update" ]] || die '缺少 deploy/linux/9router-update'
[[ -f "$SCRIPT_DIR/9router.service" ]] || die '缺少 deploy/linux/9router.service'

"$MKDIR" -p "${UPDATER_TARGET%/*}" "${SERVICE_TARGET%/*}"
"$INSTALL" -m 0755 "$SCRIPT_DIR/9router-update" "$UPDATER_TARGET"
if [[ -e "$SERVICE_TARGET" || -L "$SERVICE_TARGET" ]]; then
  UNIT_EXISTED=1
  UNIT_BACKUP="$(/usr/bin/mktemp "${SERVICE_TARGET}.backup.XXXXXX")"
  "$CP" -a -- "$SERVICE_TARGET" "$UNIT_BACKUP"
fi
UNIT_TRANSACTION_ACTIVE=1
trap on_exit EXIT
UNIT_STAGED="$(/usr/bin/mktemp "${SERVICE_TARGET}.new.XXXXXX")"
"$INSTALL" -m 0644 "$SCRIPT_DIR/9router.service" "$UNIT_STAGED"
"$MV" -fT -- "$UNIT_STAGED" "$SERVICE_TARGET"
UNIT_STAGED=""
UNIT_DEPLOYED=1
"$MKDIR" -p "$DATA_DIR"
"$SYSTEMCTL" daemon-reload
"$SYSTEMCTL" enable 9router
"$UPDATER_TARGET"
if [[ -n "$UNIT_BACKUP" ]]; then
  "$RM" -f -- "$UNIT_BACKUP"
fi
UNIT_TRANSACTION_ACTIVE=0
