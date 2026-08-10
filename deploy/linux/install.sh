#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TEST_ROOT=""
TEST_MODE="${NINEROUTER_TEST_MODE:-0}"

UNIT_EXISTED=0
UNIT_DEPLOYED=0
UNIT_BACKUP_READY=0
UNIT_BACKUP_TEMP=""
UNIT_STAGED=""
UPDATER_EXISTED=0
UPDATER_DEPLOYED=0
UPDATER_BACKUP_READY=0
UPDATER_BACKUP_TEMP=""
UPDATER_STAGED=""
ENABLE_STATE=""
ENABLE_QUERY_STATUS=0
SERVICE_WAS_ACTIVE=0
ACTIVE_QUERY_STATUS=0
ENABLE_STATE_READY=0
ENABLE_STATE_TEMP=""
TRANSACTION_ACTIVE=0
UPDATER_STARTED=0
UPDATER_PHASE="missing"

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
  local allow_final_symlink="${3:-0}"

  [[ "$candidate" == /* && "$candidate" != */./* && "$candidate" != */../* ]] ||
    die "测试路径必须是无别名的绝对路径：$label"
  parent="${candidate%/*}"
  leaf="${candidate##*/}"
  [[ -n "$parent" && "$leaf" != . && "$leaf" != .. ]] ||
    die "测试路径格式无效：$label"
  resolved_parent="$(cd -P -- "$parent" && pwd)" ||
    die "测试路径父目录无法 realpath：$label"
  resolved="$resolved_parent/$leaf"
  [[ "$allow_final_symlink" == 1 || ! -L "$resolved" ]] ||
    die "测试路径无法 realpath：$label"
  [[ "$resolved" == "$TEST_ROOT/"* ]] || die "测试路径必须位于测试根：$label"
}

validate_test_root() {
  local input="$1"
  local repository_root

  TEST_ROOT="$(cd -P -- "$input" && pwd)" || die 'root 测试根无法 realpath'
  [[ -d "$TEST_ROOT" && ! -L "$input" ]] || die 'root 测试根必须是非符号链接目录'
  repository_root="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
  case "$TEST_ROOT" in
    /tmp/*|/private/tmp/*|"$repository_root"/.superpowers/*) ;;
    /opt|/opt/*|/etc|/etc/*|/run|/run/*)
      die "root 测试根明确拒绝生产路径：$TEST_ROOT"
      ;;
    *) die "root 测试根必须位于受限测试目录：$TEST_ROOT" ;;
  esac
}

validate_protocol_paths() {
  local label
  local path
  local parent

  for label in LOCK_FILE PHASE_FILE RECOVERY_UNIT RECOVERY_UPDATER RECOVERY_ENABLE_STATE; do
    path="${!label}"
    parent="${path%/*}"
    [[ -d "$parent" && ! -L "$parent" ]] || die "事务协议父目录不安全：$label"
    [[ ! -L "$path" ]] || die "事务协议路径不得为符号链接：$label"
  done
  [[ "$LOCK_FILE" != "$PHASE_FILE" &&
    "$LOCK_FILE" != "$RECOVERY_UNIT" &&
    "$LOCK_FILE" != "$RECOVERY_UPDATER" &&
    "$LOCK_FILE" != "$RECOVERY_ENABLE_STATE" &&
    "$PHASE_FILE" != "$RECOVERY_UNIT" &&
    "$PHASE_FILE" != "$RECOVERY_UPDATER" &&
    "$PHASE_FILE" != "$RECOVERY_ENABLE_STATE" &&
    "$RECOVERY_UNIT" != "$RECOVERY_UPDATER" &&
    "$RECOVERY_UNIT" != "$RECOVERY_ENABLE_STATE" &&
    "$RECOVERY_UPDATER" != "$RECOVERY_ENABLE_STATE" ]] ||
    die '事务协议路径不得重复'
  if [[ -L "$LOCK_FILE" || ( -e "$LOCK_FILE" && ! -f "$LOCK_FILE" ) ]]; then
    die "部署锁必须为不存在或普通文件：$LOCK_FILE"
  fi
  if [[ -e "$PHASE_FILE" && ! -f "$PHASE_FILE" ]]; then
    die "阶段文件必须为不存在或普通文件：$PHASE_FILE"
  fi
  for path in "$RECOVERY_UNIT" "$RECOVERY_UPDATER" "$RECOVERY_ENABLE_STATE"; do
    [[ ! -e "$path" && ! -L "$path" ]] ||
      die "检测到未处理的固定恢复材料，拒绝覆盖：$path"
  done
}

cleanup_path() {
  local path="$1"

  [[ -n "$path" && ( -e "$path" || -L "$path" ) ]] || return 0
  "$RM" -f -- "$path"
}

unit_material_is_safe() {
  local material="$1"

  if [[ -f "$material" && ! -L "$material" ]]; then
    return 0
  fi
  [[ -L "$material" && "$(/usr/bin/readlink "$material")" == /dev/null ]]
}

unit_recovery_is_safe() {
  unit_material_is_safe "$RECOVERY_UNIT"
}

updater_material_is_safe() {
  local material="$1"

  [[ -f "$material" && ! -L "$material" ]]
}

updater_recovery_is_safe() {
  updater_material_is_safe "$RECOVERY_UPDATER"
}

restore_enable_state() {
  case "$ENABLE_STATE" in
    enabled) "$SYSTEMCTL" enable 9router ;;
    disabled) "$SYSTEMCTL" disable 9router ;;
    masked) "$SYSTEMCTL" mask 9router ;;
    not-found) "$SYSTEMCTL" disable 9router ;;
    *) return 1 ;;
  esac
}

cleanup_unready_temps() {
  local cleanup_failed=0
  local path

  for path in "$UNIT_STAGED" "$UPDATER_STAGED" "$UNIT_BACKUP_TEMP" \
    "$UPDATER_BACKUP_TEMP" "$ENABLE_STATE_TEMP"; do
    cleanup_path "$path" || cleanup_failed=1
  done
  return "$cleanup_failed"
}

restore_pre_switch() {
  local restore_failed=0
  local unit_changed="$UNIT_DEPLOYED"

  cleanup_unready_temps || restore_failed=1

  if (( UNIT_DEPLOYED == 1 )); then
    if (( UNIT_EXISTED == 1 )); then
      if (( UNIT_BACKUP_READY == 1 )) && unit_recovery_is_safe; then
        if "$MV" -fT -- "$RECOVERY_UNIT" "$SERVICE_TARGET"; then
          UNIT_BACKUP_READY=0
        else
          printf '无法原子恢复原有 systemd unit：%s\n' "$SERVICE_TARGET" >&2
          restore_failed=1
        fi
      else
        printf '原有 systemd unit 备份未 READY，拒绝用残缺材料恢复：%s\n' "$SERVICE_TARGET" >&2
        restore_failed=1
      fi
    elif ! "$RM" -f -- "$SERVICE_TARGET"; then
      printf '无法移除首次安装的 systemd unit：%s\n' "$SERVICE_TARGET" >&2
      restore_failed=1
    fi
  elif (( UNIT_BACKUP_READY == 1 )); then
    cleanup_path "$RECOVERY_UNIT" || restore_failed=1
    UNIT_BACKUP_READY=0
  fi

  if (( UPDATER_DEPLOYED == 1 )); then
    if (( UPDATER_EXISTED == 1 )); then
      if (( UPDATER_BACKUP_READY == 1 )) && [[ -f "$RECOVERY_UPDATER" && ! -L "$RECOVERY_UPDATER" ]]; then
        if "$MV" -fT -- "$RECOVERY_UPDATER" "$UPDATER_TARGET"; then
          UPDATER_BACKUP_READY=0
        else
          printf '无法原子恢复原有 updater：%s\n' "$UPDATER_TARGET" >&2
          restore_failed=1
        fi
      else
        printf '原有 updater 备份未 READY，拒绝用残缺材料恢复：%s\n' "$UPDATER_TARGET" >&2
        restore_failed=1
      fi
    elif ! "$RM" -f -- "$UPDATER_TARGET"; then
      printf '无法移除首次安装的 updater：%s\n' "$UPDATER_TARGET" >&2
      restore_failed=1
    fi
  elif (( UPDATER_BACKUP_READY == 1 )); then
    cleanup_path "$RECOVERY_UPDATER" || restore_failed=1
    UPDATER_BACKUP_READY=0
  fi

  if (( unit_changed == 1 )); then
    "$SYSTEMCTL" daemon-reload || restore_failed=1
    restore_enable_state || restore_failed=1
    if (( SERVICE_WAS_ACTIVE == 1 )) && [[ "$ENABLE_STATE" != masked ]]; then
      "$SYSTEMCTL" start 9router || restore_failed=1
    fi
  fi
  if (( ENABLE_STATE_READY == 1 )); then
    cleanup_path "$RECOVERY_ENABLE_STATE" || restore_failed=1
    ENABLE_STATE_READY=0
  fi
  TRANSACTION_ACTIVE=0
  return "$restore_failed"
}

read_updater_phase() {
  local phase_value

  if [[ ! -f "$PHASE_FILE" || -L "$PHASE_FILE" ]]; then
    printf 'missing\n'
    return 0
  fi
  phase_value="$(<"$PHASE_FILE")"
  case "$phase_value" in
    preparing|building|stopping|old_moved|new_moved|started|healthy|health_failed)
      printf '%s\n' "$phase_value"
      ;;
    *) printf 'unknown\n' ;;
  esac
}

report_joint_recovery() {
  local enable_command

  printf '固定恢复材料：旧 unit=%q；旧 updater=%q；原 enable 状态=%q（%s）。\n' \
    "$RECOVERY_UNIT" "$RECOVERY_UPDATER" "$RECOVERY_ENABLE_STATE" "$ENABLE_STATE" >&2
  if (( UNIT_EXISTED != 1 || UPDATER_EXISTED != 1 ||
    UNIT_BACKUP_READY != 1 || UPDATER_BACKUP_READY != 1 )); then
    printf '没有旧 unit 与旧 updater 可供联合恢复；这是首次安装或旧入口材料不完整，不生成联合恢复命令。\n' >&2
    return 0
  fi
  if ! unit_recovery_is_safe; then
    printf '旧 unit 恢复材料类型不安全，不生成联合恢复命令；请保留现场人工核对。\n' >&2
    return 0
  fi
  if ! updater_recovery_is_safe; then
    printf '旧 updater 恢复材料类型不安全，不生成联合恢复命令；请保留现场人工核对。\n' >&2
    return 0
  fi
  if [[ ! -e "$PREVIOUS_DIR" || -L "$PREVIOUS_DIR" ]]; then
    printf '旧运行目录材料不存在，无法生成完整联合恢复命令；请保留全部现场人工核对。\n' >&2
    return 0
  fi
  case "$ENABLE_STATE" in
    enabled) enable_command='systemctl enable 9router' ;;
    disabled) enable_command='systemctl disable 9router' ;;
    masked) enable_command='systemctl mask 9router' ;;
    not-found) enable_command='systemctl disable 9router' ;;
  esac

  printf '联合恢复命令：systemctl stop 9router && ' >&2
  if [[ -e "$DEPLOY_ROOT" || -L "$DEPLOY_ROOT" ]]; then
    printf 'rm -rf -- %q && ' "$DEPLOY_ROOT" >&2
  fi
  printf 'mv -T -- %q %q && mv -fT -- %q %q && mv -fT -- %q %q && systemctl daemon-reload && %s && rm -f -- %q' \
    "$PREVIOUS_DIR" "$DEPLOY_ROOT" \
    "$RECOVERY_UNIT" "$SERVICE_TARGET" \
    "$RECOVERY_UPDATER" "$UPDATER_TARGET" "$enable_command" "$RECOVERY_ENABLE_STATE" >&2
  if (( SERVICE_WAS_ACTIVE == 1 )) && [[ "$ENABLE_STATE" != masked ]]; then
    printf ' && systemctl start 9router' >&2
  fi
  printf '\n' >&2
}

preserve_post_switch() {
  TRANSACTION_ACTIVE=0
  cleanup_unready_temps || true
  printf '9Router 已进入切换后阶段（%s）；未自动回滚，新 unit、新 updater 与部署现场均已保留。\n' \
    "$UPDATER_PHASE" >&2
  report_joint_recovery
}

on_exit() {
  local exit_code="$?"

  trap - EXIT
  if [[ "$exit_code" -ne 0 && "$TRANSACTION_ACTIVE" -eq 1 ]]; then
    if (( UPDATER_STARTED == 1 )); then
      UPDATER_PHASE="$(read_updater_phase)"
      case "$UPDATER_PHASE" in
        preparing|building|stopping|missing)
          restore_pre_switch || true
          ;;
        old_moved|new_moved|started|healthy|health_failed)
          preserve_post_switch
          ;;
        *)
          printf '更新阶段文件内容无效；为避免破坏切换现场，不自动恢复安装入口。\n' >&2
          preserve_post_switch
          ;;
      esac
    else
      restore_pre_switch || true
    fi
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

  for override in UPDATER_TARGET SERVICE_TARGET DATA_DIR LOCK_FILE PHASE_FILE RECOVERY_UNIT \
    RECOVERY_UPDATER RECOVERY_ENABLE_STATE SYSTEMCTL NODE NPM GIT CURL FLOCK MKDIR CP MV RM INSTALL; do
    env_name="NINEROUTER_${override}"
    [[ -n "${!env_name+x}" ]] || die "root 测试模式缺少 $env_name"
  done

  UPDATER_TARGET="$NINEROUTER_UPDATER_TARGET"
  DEPLOY_ROOT="$NINEROUTER_ROOT"
  PREVIOUS_DIR="$NINEROUTER_PREVIOUS_DIR"
  SERVICE_TARGET="$NINEROUTER_SERVICE_TARGET"
  DATA_DIR="$NINEROUTER_DATA_DIR"
  LOCK_FILE="$NINEROUTER_LOCK_FILE"
  PHASE_FILE="$NINEROUTER_PHASE_FILE"
  RECOVERY_UNIT="$NINEROUTER_RECOVERY_UNIT"
  RECOVERY_UPDATER="$NINEROUTER_RECOVERY_UPDATER"
  RECOVERY_ENABLE_STATE="$NINEROUTER_RECOVERY_ENABLE_STATE"
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

  for target in DATA_DIR LOCK_FILE PHASE_FILE RECOVERY_UNIT \
    RECOVERY_UPDATER RECOVERY_ENABLE_STATE SYSTEMCTL NODE NPM GIT CURL FLOCK MKDIR CP MV RM INSTALL; do
    validate_test_path "$target" "${!target}"
  done
  validate_test_path UPDATER_TARGET "$UPDATER_TARGET" 1
  validate_test_path SERVICE_TARGET "$SERVICE_TARGET" 1
  validate_test_path DEPLOY_ROOT "$DEPLOY_ROOT"
  validate_test_path PREVIOUS_DIR "$PREVIOUS_DIR"
else
  for override in NINEROUTER_TEST_MODE NINEROUTER_TEST_ROOT NINEROUTER_UPDATER_TARGET \
    NINEROUTER_SERVICE_TARGET NINEROUTER_DATA_DIR NINEROUTER_LOCK_FILE NINEROUTER_PHASE_FILE \
    NINEROUTER_RECOVERY_UNIT NINEROUTER_RECOVERY_UPDATER NINEROUTER_RECOVERY_ENABLE_STATE \
    NINEROUTER_SYSTEMCTL NINEROUTER_NODE NINEROUTER_NPM NINEROUTER_GIT NINEROUTER_CURL \
    NINEROUTER_FLOCK NINEROUTER_MKDIR NINEROUTER_CP NINEROUTER_MV NINEROUTER_RM NINEROUTER_INSTALL; do
    [[ -z "${!override+x}" ]] || die "root 环境拒绝 $override 覆盖"
  done

  UPDATER_TARGET=/usr/local/sbin/9router-update
  DEPLOY_ROOT=/opt/9router
  PREVIOUS_DIR=/opt/9router.previous
  SERVICE_TARGET=/etc/systemd/system/9router.service
  DATA_DIR=/root/.9router
  LOCK_FILE=/run/9router-update.lock
  PHASE_FILE=/run/9router-update.phase
  RECOVERY_UNIT=/run/9router-install-recovery.unit
  RECOVERY_UPDATER=/run/9router-install-recovery.updater
  RECOVERY_ENABLE_STATE=/run/9router-install-recovery.enable-state
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
validate_protocol_paths

exec 8>>"$LOCK_FILE"
"$FLOCK" -n 8 || die '已有 9Router 安装或更新事务正在执行'
validate_protocol_paths

if ENABLE_STATE="$($SYSTEMCTL is-enabled 9router 2>/dev/null)"; then
  ENABLE_QUERY_STATUS=0
else
  ENABLE_QUERY_STATUS=$?
fi
case "$ENABLE_STATE" in
  enabled)
    [[ "$ENABLE_QUERY_STATUS" -eq 0 ]] ||
      die 'systemctl is-enabled 查询失败，拒绝信任 enabled 输出'
    ;;
  disabled|masked)
    [[ "$ENABLE_QUERY_STATUS" -eq 1 ]] ||
      die "systemctl is-enabled 查询状态异常：$ENABLE_STATE"
    ;;
  not-found)
    [[ "$ENABLE_QUERY_STATUS" -eq 1 || "$ENABLE_QUERY_STATUS" -eq 4 ]] ||
      die 'systemctl is-enabled 查询状态异常：not-found'
    ;;
  *) die '无法确认 9router 原始 enable 状态，拒绝写入安装入口' ;;
esac

if [[ "$ENABLE_STATE" != not-found ]]; then
  if "$SYSTEMCTL" is-active --quiet 9router 2>/dev/null; then
    ACTIVE_QUERY_STATUS=0
  else
    ACTIVE_QUERY_STATUS=$?
  fi
  case "$ACTIVE_QUERY_STATUS" in
    0) SERVICE_WAS_ACTIVE=1 ;;
    3|4) SERVICE_WAS_ACTIVE=0 ;;
    *) die '无法确认 9router 原始运行状态，拒绝写入安装入口' ;;
  esac
fi

"$MKDIR" -p "${UPDATER_TARGET%/*}" "${SERVICE_TARGET%/*}"
TRANSACTION_ACTIVE=1
trap on_exit EXIT

ENABLE_STATE_TEMP="$(/usr/bin/mktemp "${RECOVERY_ENABLE_STATE}.tmp.XXXXXX")"
printf '%s\n' "$ENABLE_STATE" >"$ENABLE_STATE_TEMP"
"$MV" -fT -- "$ENABLE_STATE_TEMP" "$RECOVERY_ENABLE_STATE"
ENABLE_STATE_TEMP=""
ENABLE_STATE_READY=1

if [[ -e "$UPDATER_TARGET" || -L "$UPDATER_TARGET" ]]; then
  UPDATER_EXISTED=1
  UPDATER_BACKUP_TEMP="$(/usr/bin/mktemp "${RECOVERY_UPDATER}.tmp.XXXXXX")"
  "$CP" -a -- "$UPDATER_TARGET" "$UPDATER_BACKUP_TEMP"
  if ! updater_material_is_safe "$UPDATER_BACKUP_TEMP"; then
    printf '原有 updater 不是普通文件，拒绝改写安装入口。\n' >&2
    cleanup_path "$UPDATER_BACKUP_TEMP" || true
    die '无法安全备份原有 updater'
  fi
  "$MV" -fT -- "$UPDATER_BACKUP_TEMP" "$RECOVERY_UPDATER"
  UPDATER_BACKUP_TEMP=""
  UPDATER_BACKUP_READY=1
fi
if [[ -e "$SERVICE_TARGET" || -L "$SERVICE_TARGET" ]]; then
  UNIT_EXISTED=1
  UNIT_BACKUP_TEMP="$(/usr/bin/mktemp "${RECOVERY_UNIT}.tmp.XXXXXX")"
  "$CP" -a -- "$SERVICE_TARGET" "$UNIT_BACKUP_TEMP"
  if ! unit_material_is_safe "$UNIT_BACKUP_TEMP"; then
    printf '原有 systemd unit 不是普通文件或 /dev/null mask，拒绝改写安装入口。\n' >&2
    cleanup_path "$UNIT_BACKUP_TEMP" || true
    die '无法安全备份原有 systemd unit'
  fi
  "$MV" -fT -- "$UNIT_BACKUP_TEMP" "$RECOVERY_UNIT"
  UNIT_BACKUP_TEMP=""
  UNIT_BACKUP_READY=1
fi

UPDATER_STAGED="$(/usr/bin/mktemp "${UPDATER_TARGET}.new.XXXXXX")"
"$INSTALL" -m 0755 "$SCRIPT_DIR/9router-update" "$UPDATER_STAGED"
"$MV" -fT -- "$UPDATER_STAGED" "$UPDATER_TARGET"
UPDATER_STAGED=""
UPDATER_DEPLOYED=1

UNIT_STAGED="$(/usr/bin/mktemp "${SERVICE_TARGET}.new.XXXXXX")"
"$INSTALL" -m 0644 "$SCRIPT_DIR/9router.service" "$UNIT_STAGED"
"$MV" -fT -- "$UNIT_STAGED" "$SERVICE_TARGET"
UNIT_STAGED=""
UNIT_DEPLOYED=1

"$MKDIR" -p "$DATA_DIR"
"$SYSTEMCTL" daemon-reload
"$SYSTEMCTL" enable 9router

cleanup_path "$PHASE_FILE"
UPDATER_STARTED=1
NINEROUTER_INHERITED_LOCK_FD=8 "$UPDATER_TARGET"
UPDATER_PHASE="$(read_updater_phase)"
[[ "$UPDATER_PHASE" == healthy ]] || die "更新器成功返回但阶段不是 healthy：$UPDATER_PHASE"
UPDATER_STARTED=0
TRANSACTION_ACTIVE=0

if (( UNIT_BACKUP_READY == 1 )); then
  cleanup_path "$RECOVERY_UNIT" || printf '警告：无法清理 unit 恢复材料：%s\n' "$RECOVERY_UNIT" >&2
fi
if (( UPDATER_BACKUP_READY == 1 )); then
  cleanup_path "$RECOVERY_UPDATER" || printf '警告：无法清理 updater 恢复材料：%s\n' "$RECOVERY_UPDATER" >&2
fi
if (( ENABLE_STATE_READY == 1 )); then
  cleanup_path "$RECOVERY_ENABLE_STATE" || printf '警告：无法清理 enable 状态恢复材料：%s\n' "$RECOVERY_ENABLE_STATE" >&2
fi
