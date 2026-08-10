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
RECOVERY_SCRIPT_TEMP=""
FIRST_INSTALL_CLEANUP_SCRIPT_TEMP=""
RECOVERY_WORK_UNIT_TEMP=""
RECOVERY_WORK_UPDATER_TEMP=""
RECOVERY_STEP_TEMP=""
FIRST_INSTALL_CLEANUP_STEP_TEMP=""
TRANSACTION_ACTIVE=0
UPDATER_STARTED=0
UPDATER_PHASE="missing"
DEPLOY_ROOT_EXISTED=0
DEPLOY_ROOT_INITIAL_ID=""

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
  local seen_paths='|'

  for label in LOCK_FILE PHASE_FILE RECOVERY_UNIT RECOVERY_UPDATER RECOVERY_ENABLE_STATE \
    RECOVERY_SCRIPT FIRST_INSTALL_CLEANUP_SCRIPT RECOVERY_WORK_UNIT RECOVERY_WORK_UPDATER \
    RECOVERY_STEP FIRST_INSTALL_CLEANUP_STEP; do
    path="${!label}"
    parent="${path%/*}"
    [[ -d "$parent" && ! -L "$parent" ]] || die "事务协议父目录不安全：$label"
    [[ ! -L "$path" ]] || die "事务协议路径不得为符号链接：$label"
    case "$seen_paths" in
      *"|$path|"*) die '事务协议路径不得重复' ;;
    esac
    seen_paths+="$path|"
  done
  if [[ -L "$LOCK_FILE" || ( -e "$LOCK_FILE" && ! -f "$LOCK_FILE" ) ]]; then
    die "部署锁必须为不存在或普通文件：$LOCK_FILE"
  fi
  if [[ -e "$PHASE_FILE" && ! -f "$PHASE_FILE" ]]; then
    die "阶段文件必须为不存在或普通文件：$PHASE_FILE"
  fi
  for path in "$RECOVERY_UNIT" "$RECOVERY_UPDATER" "$RECOVERY_ENABLE_STATE" \
    "$RECOVERY_SCRIPT" "$FIRST_INSTALL_CLEANUP_SCRIPT" "$RECOVERY_WORK_UNIT" \
    "$RECOVERY_WORK_UPDATER" "$RECOVERY_STEP" "$FIRST_INSTALL_CLEANUP_STEP"; do
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
    "$UPDATER_BACKUP_TEMP" "$ENABLE_STATE_TEMP" "$RECOVERY_SCRIPT_TEMP" \
    "$FIRST_INSTALL_CLEANUP_SCRIPT_TEMP" "$RECOVERY_WORK_UNIT_TEMP" \
    "$RECOVERY_WORK_UPDATER_TEMP" "$RECOVERY_STEP_TEMP" \
    "$FIRST_INSTALL_CLEANUP_STEP_TEMP"; do
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
    preparing|building|stopping|old_move_intent|old_moved|new_move_intent|new_moved|started|healthy|health_failed)
      printf '%s\n' "$phase_value"
      ;;
    *) printf 'unknown\n' ;;
  esac
}

path_is_safe_directory() {
  local path="$1"

  [[ -d "$path" && ! -L "$path" ]]
}

path_is_absent() {
  local path="$1"

  [[ ! -e "$path" && ! -L "$path" ]]
}

intent_scene_is_unchanged() {
  case "$UPDATER_PHASE" in
    old_move_intent)
      (( DEPLOY_ROOT_EXISTED == 1 )) &&
        path_is_safe_directory "$DEPLOY_ROOT" &&
        [[ "$("$STAT" -Lc '%d:%i' -- "$DEPLOY_ROOT" 2>/dev/null)" == "$DEPLOY_ROOT_INITIAL_ID" ]] &&
        path_is_safe_directory "$BUILD_DIR" &&
        path_is_absent "$PREVIOUS_DIR"
      ;;
    new_move_intent)
      (( DEPLOY_ROOT_EXISTED == 0 )) &&
        path_is_absent "$DEPLOY_ROOT" &&
        path_is_safe_directory "$BUILD_DIR" &&
        path_is_absent "$PREVIOUS_DIR"
      ;;
    *) return 1 ;;
  esac
}

preserve_uncertain_intent() {
  TRANSACTION_ACTIVE=0
  cleanup_unready_temps || true
  printf '更新器停在意图阶段（%s），现场无法证明未发生切换；为避免误恢复，安装器未自动改动入口或目录。\n' \
    "$UPDATER_PHASE" >&2
  printf '安全诊断：ROOT=%q（%s），BUILD=%q（%s），previous=%q（%s）；固定恢复材料保持原样，请在持有 %q 锁时人工核对。\n' \
    "$DEPLOY_ROOT" "$([[ -e "$DEPLOY_ROOT" || -L "$DEPLOY_ROOT" ]] && printf present || printf absent)" \
    "$BUILD_DIR" "$([[ -e "$BUILD_DIR" || -L "$BUILD_DIR" ]] && printf present || printf absent)" \
    "$PREVIOUS_DIR" "$([[ -e "$PREVIOUS_DIR" || -L "$PREVIOUS_DIR" ]] && printf present || printf absent)" \
    "$LOCK_FILE" >&2
}

cleanup_joint_generation() {
  local cleanup_failed=0
  local path

  for path in "$RECOVERY_SCRIPT_TEMP" "$RECOVERY_WORK_UNIT_TEMP" \
    "$RECOVERY_WORK_UPDATER_TEMP" "$RECOVERY_STEP_TEMP" "$RECOVERY_SCRIPT" \
    "$RECOVERY_WORK_UNIT" "$RECOVERY_WORK_UPDATER" "$RECOVERY_STEP"; do
    cleanup_path "$path" || cleanup_failed=1
  done
  RECOVERY_SCRIPT_TEMP=""
  RECOVERY_WORK_UNIT_TEMP=""
  RECOVERY_WORK_UPDATER_TEMP=""
  RECOVERY_STEP_TEMP=""
  return "$cleanup_failed"
}

cleanup_first_install_generation() {
  local cleanup_failed=0
  local path

  for path in "$FIRST_INSTALL_CLEANUP_SCRIPT_TEMP" \
    "$FIRST_INSTALL_CLEANUP_STEP_TEMP" "$FIRST_INSTALL_CLEANUP_SCRIPT" \
    "$FIRST_INSTALL_CLEANUP_STEP"; do
    cleanup_path "$path" || cleanup_failed=1
  done
  FIRST_INSTALL_CLEANUP_SCRIPT_TEMP=""
  FIRST_INSTALL_CLEANUP_STEP_TEMP=""
  return "$cleanup_failed"
}

script_printf() {
  script_write_count=$((script_write_count + 1))
  if [[ "$TEST_MODE" == 1 && "$script_write_fail_at" =~ ^[1-9][0-9]*$ &&
    "$script_write_count" -eq "$script_write_fail_at" ]]; then
    return 97
  fi
  printf "$@"
}

write_joint_recovery_script() {
  local lock_identity phase_identity unit_identity recovery_updater_identity
  local enable_identity previous_identity service_identity updater_identity
  local work_unit_identity work_updater_identity recovery_token
  local root_state=absent root_identity='' build_state=absent build_identity=''
  local script_write_count=0
  local script_write_fail_at="${NINEROUTER_TEST_FAIL_SCRIPT_WRITE_AT:-0}"
  local script_write_failed=0
  local path

  (( UNIT_EXISTED == 1 && UPDATER_EXISTED == 1 &&
    UNIT_BACKUP_READY == 1 && UPDATER_BACKUP_READY == 1 )) || return 1
  unit_recovery_is_safe || return 1
  updater_recovery_is_safe || return 1
  [[ -x "$RECOVERY_UPDATER" ]] || return 1
  [[ -f "$RECOVERY_ENABLE_STATE" && ! -L "$RECOVERY_ENABLE_STATE" ]] || return 1
  [[ "$(<"$RECOVERY_ENABLE_STATE")" == "$ENABLE_STATE" ]] || return 1
  [[ -f "$PHASE_FILE" && ! -L "$PHASE_FILE" ]] || return 1
  [[ "$(<"$PHASE_FILE")" == "$UPDATER_PHASE" ]] || return 1
  path_is_safe_directory "$PREVIOUS_DIR" || return 1
  [[ -f "$SERVICE_TARGET" && ! -L "$SERVICE_TARGET" ]] || return 1
  [[ -f "$UPDATER_TARGET" && ! -L "$UPDATER_TARGET" ]] || return 1
  path_is_absent "$FAILED_ROOT" || return 1
  for path in "$RECOVERY_SCRIPT" "$RECOVERY_WORK_UNIT" "$RECOVERY_WORK_UPDATER" \
    "$RECOVERY_STEP"; do
    path_is_absent "$path" || return 1
  done
  if [[ -e "$DEPLOY_ROOT" || -L "$DEPLOY_ROOT" ]]; then
    path_is_safe_directory "$DEPLOY_ROOT" || return 1
    root_state=present
    root_identity="$("$STAT" -Lc '%d:%i' -- "$DEPLOY_ROOT")" || return 1
  fi
  if [[ -e "$BUILD_DIR" || -L "$BUILD_DIR" ]]; then
    path_is_safe_directory "$BUILD_DIR" || return 1
    build_state=present
    build_identity="$("$STAT" -Lc '%d:%i' -- "$BUILD_DIR")" || return 1
  fi

  lock_identity="$("$STAT" -Lc '%d:%i' -- "$LOCK_FILE")" || return 1
  phase_identity="$("$STAT" -Lc '%d:%i' -- "$PHASE_FILE")" || return 1
  unit_identity="$("$STAT" -c '%d:%i' -- "$RECOVERY_UNIT")" || return 1
  recovery_updater_identity="$("$STAT" -Lc '%d:%i' -- "$RECOVERY_UPDATER")" ||
    return 1
  enable_identity="$("$STAT" -Lc '%d:%i' -- "$RECOVERY_ENABLE_STATE")" || return 1
  previous_identity="$("$STAT" -Lc '%d:%i' -- "$PREVIOUS_DIR")" || return 1
  service_identity="$("$STAT" -Lc '%d:%i' -- "$SERVICE_TARGET")" || return 1
  updater_identity="$("$STAT" -Lc '%d:%i' -- "$UPDATER_TARGET")" || return 1

  RECOVERY_WORK_UNIT_TEMP="$(/usr/bin/mktemp "${RECOVERY_WORK_UNIT}.tmp.XXXXXX")" ||
    return 1
  if ! "$CP" -a -- "$RECOVERY_UNIT" "$RECOVERY_WORK_UNIT_TEMP" ||
    ! unit_material_is_safe "$RECOVERY_WORK_UNIT_TEMP" ||
    ! "$MV" -fT -- "$RECOVERY_WORK_UNIT_TEMP" "$RECOVERY_WORK_UNIT"; then
    cleanup_joint_generation || true
    return 1
  fi
  RECOVERY_WORK_UNIT_TEMP=""

  RECOVERY_WORK_UPDATER_TEMP="$(/usr/bin/mktemp "${RECOVERY_WORK_UPDATER}.tmp.XXXXXX")" || {
    cleanup_joint_generation || true
    return 1
  }
  if ! "$CP" -a -- "$RECOVERY_UPDATER" "$RECOVERY_WORK_UPDATER_TEMP" ||
    ! updater_material_is_safe "$RECOVERY_WORK_UPDATER_TEMP" ||
    [[ ! -x "$RECOVERY_WORK_UPDATER_TEMP" ]] ||
    ! "$MV" -fT -- "$RECOVERY_WORK_UPDATER_TEMP" "$RECOVERY_WORK_UPDATER"; then
    cleanup_joint_generation || true
    return 1
  fi
  RECOVERY_WORK_UPDATER_TEMP=""

  work_unit_identity="$("$STAT" -c '%d:%i' -- "$RECOVERY_WORK_UNIT")" || {
    cleanup_joint_generation || true
    return 1
  }
  work_updater_identity="$("$STAT" -Lc '%d:%i' -- "$RECOVERY_WORK_UPDATER")" || {
    cleanup_joint_generation || true
    return 1
  }
  recovery_token="${lock_identity}:${phase_identity}:${previous_identity}:${work_unit_identity}:${work_updater_identity}"

  RECOVERY_STEP_TEMP="$(/usr/bin/mktemp "${RECOVERY_STEP}.tmp.XXXXXX")" || {
    cleanup_joint_generation || true
    return 1
  }
  if ! printf 'prepared %s\n' "$recovery_token" >"$RECOVERY_STEP_TEMP" ||
    ! /bin/chmod 0600 "$RECOVERY_STEP_TEMP" ||
    ! "$MV" -fT -- "$RECOVERY_STEP_TEMP" "$RECOVERY_STEP"; then
    cleanup_joint_generation || true
    return 1
  fi
  RECOVERY_STEP_TEMP=""

  RECOVERY_SCRIPT_TEMP="$(/usr/bin/mktemp "${RECOVERY_SCRIPT}.tmp.XXXXXX")" || {
    cleanup_joint_generation || true
    return 1
  }
  if ! {
    script_printf '#!/usr/bin/env bash\n' || script_write_failed=1
    script_printf 'set -Eeuo pipefail\numask 077\n' || script_write_failed=1
    script_printf 'TEST_MODE=%q\n' "$TEST_MODE" || script_write_failed=1
    script_printf 'LOCK_FILE=%q\nPHASE_FILE=%q\n' "$LOCK_FILE" "$PHASE_FILE" ||
      script_write_failed=1
    script_printf 'RECOVERY_UNIT=%q\nRECOVERY_UPDATER=%q\nRECOVERY_ENABLE_STATE=%q\n' \
      "$RECOVERY_UNIT" "$RECOVERY_UPDATER" "$RECOVERY_ENABLE_STATE" || script_write_failed=1
    script_printf 'RECOVERY_WORK_UNIT=%q\nRECOVERY_WORK_UPDATER=%q\nSTEP_PATH=%q\n' \
      "$RECOVERY_WORK_UNIT" "$RECOVERY_WORK_UPDATER" "$RECOVERY_STEP" || script_write_failed=1
    script_printf 'SCRIPT_PATH=%q\nDEPLOY_ROOT=%q\nFAILED_ROOT=%q\n' \
      "$RECOVERY_SCRIPT" "$DEPLOY_ROOT" "$FAILED_ROOT" || script_write_failed=1
    script_printf 'BUILD_DIR=%q\nPREVIOUS_DIR=%q\n' "$BUILD_DIR" "$PREVIOUS_DIR" ||
      script_write_failed=1
    script_printf 'SERVICE_TARGET=%q\nUPDATER_TARGET=%q\n' \
      "$SERVICE_TARGET" "$UPDATER_TARGET" || script_write_failed=1
    script_printf 'SYSTEMCTL=%q\nFLOCK=%q\nSTAT=%q\nMV=%q\nRM=%q\n' \
      "$SYSTEMCTL" "$FLOCK" "$STAT" "$MV" "$RM" || script_write_failed=1
    script_printf 'EXPECTED_LOCK_ID=%q\nEXPECTED_PHASE=%q\nEXPECTED_PHASE_ID=%q\n' \
      "$lock_identity" "$UPDATER_PHASE" "$phase_identity" || script_write_failed=1
    script_printf 'EXPECTED_UNIT_ID=%q\nEXPECTED_RECOVERY_UPDATER_ID=%q\nEXPECTED_ENABLE_ID=%q\n' \
      "$unit_identity" "$recovery_updater_identity" "$enable_identity" || script_write_failed=1
    script_printf 'EXPECTED_WORK_UNIT_ID=%q\nEXPECTED_WORK_UPDATER_ID=%q\n' \
      "$work_unit_identity" "$work_updater_identity" || script_write_failed=1
    script_printf 'EXPECTED_PREVIOUS_ID=%q\nEXPECTED_SERVICE_ID=%q\nEXPECTED_UPDATER_ID=%q\n' \
      "$previous_identity" "$service_identity" "$updater_identity" || script_write_failed=1
    script_printf 'EXPECTED_ROOT_STATE=%q\nEXPECTED_ROOT_ID=%q\n' \
      "$root_state" "$root_identity" || script_write_failed=1
    script_printf 'EXPECTED_BUILD_STATE=%q\nEXPECTED_BUILD_ID=%q\n' \
      "$build_state" "$build_identity" || script_write_failed=1
    script_printf 'EXPECTED_ENABLE_STATE=%q\nEXPECTED_SERVICE_WAS_ACTIVE=%q\n' \
      "$ENABLE_STATE" "$SERVICE_WAS_ACTIVE" || script_write_failed=1
    script_printf 'EXPECTED_TOKEN=%q\n' "$recovery_token" || script_write_failed=1
    while IFS= read -r line; do
      script_printf '%s\n' "$line" || script_write_failed=1
    done <<'RECOVERY_BODY'

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

is_absent() {
  [[ ! -e "$1" && ! -L "$1" ]]
}

same_followed_inode() {
  local expected="$1" path="$2" actual
  actual="$("$STAT" -Lc '%d:%i' -- "$path")" || return 1
  [[ "$actual" == "$expected" ]]
}

same_path_inode() {
  local expected="$1" path="$2" actual
  actual="$("$STAT" -c '%d:%i' -- "$path")" || return 1
  [[ "$actual" == "$expected" ]]
}

safe_unit_with_id() {
  local expected="$1" path="$2"
  if [[ -f "$path" && ! -L "$path" ]]; then
    :
  elif [[ -L "$path" && "$(/usr/bin/readlink "$path")" == /dev/null ]]; then
    :
  else
    return 1
  fi
  same_path_inode "$expected" "$path"
}

safe_updater_with_id() {
  local expected="$1" path="$2"
  [[ -f "$path" && ! -L "$path" && -x "$path" ]] || return 1
  same_followed_inode "$expected" "$path"
}

safe_regular_with_id() {
  local expected="$1" path="$2"
  [[ -f "$path" && ! -L "$path" ]] || return 1
  same_followed_inode "$expected" "$path"
}

safe_directory_with_id() {
  local expected="$1" path="$2"
  [[ -d "$path" && ! -L "$path" ]] || return 1
  same_followed_inode "$expected" "$path"
}

validate_build_scene() {
  case "$EXPECTED_BUILD_STATE" in
    present)
      safe_directory_with_id "$EXPECTED_BUILD_ID" "$BUILD_DIR" ||
        die 'BUILD 现场与恢复脚本生成时不一致'
      ;;
    absent)
      is_absent "$BUILD_DIR" || die 'BUILD 现场与恢复脚本生成时不一致'
      ;;
    *) die '恢复脚本中的 BUILD 预期无效' ;;
  esac
}

validate_required_materials() {
  safe_unit_with_id "$EXPECTED_UNIT_ID" "$RECOVERY_UNIT" ||
    die '旧 unit 恢复材料已变化'
  safe_updater_with_id "$EXPECTED_RECOVERY_UPDATER_ID" "$RECOVERY_UPDATER" ||
    die '旧 updater 恢复材料已变化'
  safe_regular_with_id "$EXPECTED_ENABLE_ID" "$RECOVERY_ENABLE_STATE" ||
    die 'enable 状态恢复材料已变化'
  [[ "$(<"$RECOVERY_ENABLE_STATE")" == "$EXPECTED_ENABLE_STATE" ]] ||
    die 'enable 状态恢复材料内容已变化'
  safe_regular_with_id "$EXPECTED_PHASE_ID" "$PHASE_FILE" || die '阶段文件已变化'
  [[ "$(<"$PHASE_FILE")" == "$EXPECTED_PHASE" ]] || die '阶段文件内容已变化'
}

validate_cleanup_material_or_absent() {
  if ! is_absent "$RECOVERY_UNIT"; then
    safe_unit_with_id "$EXPECTED_UNIT_ID" "$RECOVERY_UNIT" ||
      die '旧 unit 恢复材料处于不确定现场'
  fi
  if ! is_absent "$RECOVERY_UPDATER"; then
    safe_updater_with_id "$EXPECTED_RECOVERY_UPDATER_ID" "$RECOVERY_UPDATER" ||
      die '旧 updater 恢复材料处于不确定现场'
  fi
  if ! is_absent "$RECOVERY_ENABLE_STATE"; then
    safe_regular_with_id "$EXPECTED_ENABLE_ID" "$RECOVERY_ENABLE_STATE" ||
      die 'enable 状态恢复材料处于不确定现场'
    [[ "$(<"$RECOVERY_ENABLE_STATE")" == "$EXPECTED_ENABLE_STATE" ]] ||
      die 'enable 状态恢复材料内容已变化'
  fi
  if ! is_absent "$PHASE_FILE"; then
    safe_regular_with_id "$EXPECTED_PHASE_ID" "$PHASE_FILE" ||
      die '阶段文件处于不确定现场'
    [[ "$(<"$PHASE_FILE")" == "$EXPECTED_PHASE" ]] || die '阶段文件内容已变化'
  fi
}

root_scene() {
  case "$EXPECTED_ROOT_STATE" in
    present)
      if safe_directory_with_id "$EXPECTED_ROOT_ID" "$DEPLOY_ROOT" &&
        is_absent "$FAILED_ROOT" &&
        safe_directory_with_id "$EXPECTED_PREVIOUS_ID" "$PREVIOUS_DIR"; then
        printf 'new_root\n'
      elif is_absent "$DEPLOY_ROOT" &&
        safe_directory_with_id "$EXPECTED_ROOT_ID" "$FAILED_ROOT" &&
        safe_directory_with_id "$EXPECTED_PREVIOUS_ID" "$PREVIOUS_DIR"; then
        printf 'new_staged\n'
      elif safe_directory_with_id "$EXPECTED_PREVIOUS_ID" "$DEPLOY_ROOT" &&
        safe_directory_with_id "$EXPECTED_ROOT_ID" "$FAILED_ROOT" &&
        is_absent "$PREVIOUS_DIR"; then
        printf 'old_restored\n'
      else
        return 1
      fi
      ;;
    absent)
      if is_absent "$DEPLOY_ROOT" && is_absent "$FAILED_ROOT" &&
        safe_directory_with_id "$EXPECTED_PREVIOUS_ID" "$PREVIOUS_DIR"; then
        printf 'root_absent\n'
      elif safe_directory_with_id "$EXPECTED_PREVIOUS_ID" "$DEPLOY_ROOT" &&
        is_absent "$FAILED_ROOT" && is_absent "$PREVIOUS_DIR"; then
        printf 'old_restored\n'
      else
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

unit_scene() {
  if safe_unit_with_id "$EXPECTED_SERVICE_ID" "$SERVICE_TARGET" &&
    safe_unit_with_id "$EXPECTED_WORK_UNIT_ID" "$RECOVERY_WORK_UNIT"; then
    printf 'new_unit\n'
  elif safe_unit_with_id "$EXPECTED_WORK_UNIT_ID" "$SERVICE_TARGET" &&
    is_absent "$RECOVERY_WORK_UNIT"; then
    printf 'old_unit\n'
  else
    return 1
  fi
}

updater_scene() {
  if safe_updater_with_id "$EXPECTED_UPDATER_ID" "$UPDATER_TARGET" &&
    safe_updater_with_id "$EXPECTED_WORK_UPDATER_ID" "$RECOVERY_WORK_UPDATER"; then
    printf 'new_updater\n'
  elif safe_updater_with_id "$EXPECTED_WORK_UPDATER_ID" "$UPDATER_TARGET" &&
    is_absent "$RECOVERY_WORK_UPDATER"; then
    printf 'old_updater\n'
  else
    return 1
  fi
}

ensure_stopped() {
  local active_state active_status
  "$SYSTEMCTL" stop 9router || die '停止 9Router 失败；恢复未修改下一项现场'
  if active_state="$("$SYSTEMCTL" is-active 9router 2>/dev/null)"; then
    die '停止后服务仍处于 active；恢复未修改下一项现场'
  else
    active_status=$?
  fi
  [[ "$active_status" -eq 3 &&
    ( "$active_state" == inactive || "$active_state" == failed ) ]] ||
    die '无法确认 9Router 已停止；恢复未修改下一项现场'
}

validate_restored_systemd_state() {
  local enable_state enable_status active_state active_status

  if enable_state="$("$SYSTEMCTL" is-enabled 9router 2>/dev/null)"; then
    enable_status=0
  else
    enable_status=$?
  fi
  case "$EXPECTED_ENABLE_STATE" in
    enabled)
      [[ "$enable_status" -eq 0 && "$enable_state" == enabled ]] ||
        die '恢复后的 enable 状态不是 enabled'
      ;;
    disabled|not-found)
      [[ "$enable_status" -eq 1 && "$enable_state" == disabled ]] ||
        die '恢复后的 enable 状态不是 disabled'
      ;;
    masked)
      [[ "$enable_status" -eq 1 && "$enable_state" == masked ]] ||
        die '恢复后的 enable 状态不是 masked'
      ;;
    *) die '恢复脚本中的 enable 状态无效' ;;
  esac

  if [[ "$EXPECTED_SERVICE_WAS_ACTIVE" == 1 ]]; then
    "$SYSTEMCTL" is-active --quiet 9router ||
      die '恢复后的原服务未处于 active'
  else
    if active_state="$("$SYSTEMCTL" is-active 9router 2>/dev/null)"; then
      die '恢复后的原服务意外处于 active'
    else
      active_status=$?
    fi
    [[ "$active_status" -eq 3 &&
      ( "$active_state" == inactive || "$active_state" == failed ) ]] ||
      die '恢复后的原服务运行状态无法确认'
  fi
}

restore_systemd_state() {
  "$SYSTEMCTL" daemon-reload || die 'systemd daemon-reload 失败；请重试同一恢复脚本'
  case "$EXPECTED_ENABLE_STATE" in
    enabled) "$SYSTEMCTL" enable 9router || die '恢复 enabled 状态失败' ;;
    disabled|not-found) "$SYSTEMCTL" disable 9router || die '恢复 disabled 状态失败' ;;
    masked) "$SYSTEMCTL" mask 9router || die '恢复 masked 状态失败' ;;
    *) die '恢复脚本中的 enable 状态无效' ;;
  esac
  if [[ "$EXPECTED_SERVICE_WAS_ACTIVE" == 1 ]]; then
    "$SYSTEMCTL" start 9router || die '重新启动原 9Router 服务失败'
  else
    ensure_stopped
  fi
  validate_restored_systemd_state
}

write_stage() {
  local next_stage="$1" step_temp
  step_temp="$(/usr/bin/mktemp "${STEP_PATH}.tmp.XXXXXX")" ||
    die '无法创建恢复阶段临时文件'
  if ! printf '%s %s\n' "$next_stage" "$EXPECTED_TOKEN" >"$step_temp" ||
    ! /bin/chmod 0600 "$step_temp" ||
    ! "$MV" -fT -- "$step_temp" "$STEP_PATH"; then
    "$RM" -f -- "$step_temp" || true
    die '无法原子推进恢复阶段；可在核对现场后重试同一脚本'
  fi
}

read_stage() {
  local stage_value token_value extra=''
  is_absent "$STEP_PATH" && return 2
  [[ -f "$STEP_PATH" && ! -L "$STEP_PATH" ]] || die '恢复阶段路径类型不安全'
  read -r stage_value token_value extra <"$STEP_PATH" || die '恢复阶段文件不可读'
  [[ -z "$extra" && "$token_value" == "$EXPECTED_TOKEN" ]] ||
    die '恢复阶段文件内容已变化'
  case "$stage_value" in
    prepared|root_restored|unit_restored|updater_restored|systemd_restored)
      printf '%s\n' "$stage_value"
      ;;
    *) die '恢复阶段文件状态无效' ;;
  esac
}

validate_restored_root() {
  local scene
  scene="$(root_scene)" || die '运行目录恢复现场不确定'
  [[ "$scene" == old_restored ]] || die '旧运行目录尚未恢复'
}

validate_final_scene() {
  local scene
  validate_build_scene
  scene="$(root_scene)" || return 1
  [[ "$scene" == old_restored ]] || return 1
  [[ "$(unit_scene)" == old_unit ]] || return 1
  [[ "$(updater_scene)" == old_updater ]] || return 1
  is_absent "$RECOVERY_UNIT" && is_absent "$RECOVERY_UPDATER" &&
    is_absent "$RECOVERY_ENABLE_STATE" && is_absent "$PHASE_FILE"
}

remove_checked_unit_material() {
  if is_absent "$RECOVERY_UNIT"; then
    return 0
  fi
  safe_unit_with_id "$EXPECTED_UNIT_ID" "$RECOVERY_UNIT" ||
    die '旧 unit 恢复材料处于不确定现场'
  if ! "$RM" -f -- "$RECOVERY_UNIT"; then
    is_absent "$RECOVERY_UNIT" || die '无法清理旧 unit 恢复材料'
    die '旧 unit 恢复材料已清理但命令报错；请重试同一脚本'
  fi
}

remove_checked_regular_material() {
  local expected="$1" path="$2" label="$3"
  if is_absent "$path"; then
    return 0
  fi
  safe_regular_with_id "$expected" "$path" || die "$label 处于不确定现场"
  if ! "$RM" -f -- "$path"; then
    is_absent "$path" || die "无法清理 $label"
    die "$label 已清理但命令报错；请重试同一脚本"
  fi
}

[[ "$TEST_MODE" == 1 || "$EUID" -eq 0 ]] || die '恢复脚本必须以 root 身份运行'
for command_path in "$SYSTEMCTL" "$FLOCK" "$STAT" "$MV" "$RM"; do
  [[ -x "$command_path" ]] || die "恢复所需命令不可执行：$command_path"
done
[[ -f "$SCRIPT_PATH" && ! -L "$SCRIPT_PATH" && -x "$SCRIPT_PATH" ]] ||
  die '固定恢复脚本路径不安全'
[[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" ]] || die '共享更新锁路径不安全'

exec 8>>"$LOCK_FILE"
"$FLOCK" -n 8 || die '已有 9Router 安装或更新事务正在执行；联合恢复未执行'
if [[ -e /proc/self/fd/8 ]]; then lock_fd_path=/proc/self/fd/8; else lock_fd_path=/dev/fd/8; fi
same_followed_inode "$EXPECTED_LOCK_ID" "$LOCK_FILE" ||
  die '共享更新锁 inode 已变化；联合恢复未执行'
same_followed_inode "$EXPECTED_LOCK_ID" "$lock_fd_path" ||
  die '共享更新锁 FD 与固定锁路径不一致；联合恢复未执行'
same_followed_inode "$EXPECTED_LOCK_ID" "$LOCK_FILE" ||
  die '共享更新锁路径在 FD 校验期间发生变化；联合恢复未执行'

validate_build_scene
systemd_state_fresh=0
if stage="$(read_stage)"; then
  :
else
  stage_status=$?
  if [[ "$stage_status" -eq 2 ]]; then
    if validate_final_scene; then
      restore_systemd_state
      "$RM" -f -- "$SCRIPT_PATH" || die '恢复已完成，但无法清理固定恢复脚本'
      printf '9Router 旧 unit、旧 updater、旧运行目录与服务状态已联合恢复。\n'
      exit 0
    fi
    die '恢复阶段文件缺失且现场不是已完成状态；联合恢复未执行'
  fi
  die '恢复阶段文件存在但不安全；联合恢复未执行'
fi
if [[ "$stage" == systemd_restored ]]; then
  validate_cleanup_material_or_absent
else
  validate_required_materials
fi

if [[ "$stage" == prepared ]]; then
  [[ "$(unit_scene)" == new_unit ]] || die 'unit 现场与 prepared 阶段不一致'
  [[ "$(updater_scene)" == new_updater ]] || die 'updater 现场与 prepared 阶段不一致'
  scene="$(root_scene)" || die '运行目录处于不确定现场；联合恢复未执行'
  ensure_stopped
  if [[ "$scene" == new_root ]]; then
    if ! "$MV" -T -- "$DEPLOY_ROOT" "$FAILED_ROOT"; then
      if is_absent "$DEPLOY_ROOT" &&
        safe_directory_with_id "$EXPECTED_ROOT_ID" "$FAILED_ROOT"; then
        die '失败代码已安全转存，但命令报错；请重试同一恢复脚本'
      fi
      die '无法安全转存失败代码目录；联合恢复已停止'
    fi
    scene=new_staged
  fi
  if [[ "$scene" == root_absent || "$scene" == new_staged ]]; then
    if ! "$MV" -T -- "$PREVIOUS_DIR" "$DEPLOY_ROOT"; then
      if safe_directory_with_id "$EXPECTED_PREVIOUS_ID" "$DEPLOY_ROOT" &&
        is_absent "$PREVIOUS_DIR"; then
        die '旧运行目录已恢复，但命令报错；请重试同一恢复脚本'
      fi
      die '无法安全恢复旧运行目录；联合恢复已停止'
    fi
  fi
  validate_restored_root
  write_stage root_restored
  stage=root_restored
fi

if [[ "$stage" == root_restored ]]; then
  validate_restored_root
  ensure_stopped
  unit_state="$(unit_scene)" || die 'unit 恢复现场不确定'
  [[ "$(updater_scene)" == new_updater ]] || die 'updater 在 unit 恢复前已变化'
  if [[ "$unit_state" == new_unit ]]; then
    if ! "$MV" -fT -- "$RECOVERY_WORK_UNIT" "$SERVICE_TARGET"; then
      if safe_unit_with_id "$EXPECTED_WORK_UNIT_ID" "$SERVICE_TARGET" &&
        is_absent "$RECOVERY_WORK_UNIT"; then
        die '旧 unit 已恢复，但命令报错；请重试同一恢复脚本'
      fi
      die '无法安全恢复旧 unit；联合恢复已停止'
    fi
  fi
  [[ "$(unit_scene)" == old_unit ]] || die '旧 unit 恢复后现场验证失败'
  write_stage unit_restored
  stage=unit_restored
fi

if [[ "$stage" == unit_restored ]]; then
  validate_restored_root
  [[ "$(unit_scene)" == old_unit ]] || die '已恢复 unit 现场发生变化'
  ensure_stopped
  updater_state="$(updater_scene)" || die 'updater 恢复现场不确定'
  if [[ "$updater_state" == new_updater ]]; then
    if ! "$MV" -fT -- "$RECOVERY_WORK_UPDATER" "$UPDATER_TARGET"; then
      if safe_updater_with_id "$EXPECTED_WORK_UPDATER_ID" "$UPDATER_TARGET" &&
        is_absent "$RECOVERY_WORK_UPDATER"; then
        die '旧 updater 已恢复，但命令报错；请重试同一恢复脚本'
      fi
      die '无法安全恢复旧 updater；联合恢复已停止'
    fi
  fi
  [[ "$(updater_scene)" == old_updater ]] || die '旧 updater 恢复后现场验证失败'
  write_stage updater_restored
  stage=updater_restored
fi

if [[ "$stage" == updater_restored ]]; then
  validate_restored_root
  [[ "$(unit_scene)" == old_unit ]] || die '已恢复 unit 现场发生变化'
  [[ "$(updater_scene)" == old_updater ]] || die '已恢复 updater 现场发生变化'
  ensure_stopped
  restore_systemd_state
  write_stage systemd_restored
  stage=systemd_restored
  systemd_state_fresh=1
fi

if [[ "$stage" == systemd_restored ]]; then
  validate_restored_root
  [[ "$(unit_scene)" == old_unit ]] || die '已恢复 unit 现场发生变化'
  [[ "$(updater_scene)" == old_updater ]] || die '已恢复 updater 现场发生变化'
  validate_cleanup_material_or_absent
  if [[ "$systemd_state_fresh" -eq 1 ]]; then
    validate_restored_systemd_state
  else
    restore_systemd_state
  fi
  remove_checked_unit_material
  if ! is_absent "$RECOVERY_UPDATER"; then
    safe_updater_with_id "$EXPECTED_RECOVERY_UPDATER_ID" "$RECOVERY_UPDATER" ||
      die '旧 updater 恢复材料处于不确定现场'
    if ! "$RM" -f -- "$RECOVERY_UPDATER"; then
      is_absent "$RECOVERY_UPDATER" || die '无法清理旧 updater 恢复材料'
      die '旧 updater 恢复材料已清理但命令报错；请重试同一脚本'
    fi
  fi
  remove_checked_regular_material "$EXPECTED_ENABLE_ID" \
    "$RECOVERY_ENABLE_STATE" 'enable 状态恢复材料'
  remove_checked_regular_material "$EXPECTED_PHASE_ID" "$PHASE_FILE" '阶段文件'
  if ! "$RM" -f -- "$STEP_PATH"; then
    is_absent "$STEP_PATH" || die '无法清理恢复阶段文件'
    die '恢复阶段文件已清理但命令报错；请重试同一脚本'
  fi
  "$RM" -f -- "$SCRIPT_PATH" || die '恢复完成，但无法清理固定恢复脚本'
  if [[ "$EXPECTED_ROOT_STATE" == present ]]; then
    printf '9Router 旧 unit、旧 updater、旧运行目录与服务状态已联合恢复；失败代码保留在 %s。\n' \
      "$FAILED_ROOT"
  else
    printf '9Router 旧 unit、旧 updater、旧运行目录与服务状态已联合恢复；切换失败时尚无新 ROOT。\n'
  fi
fi
RECOVERY_BODY
    (( script_write_failed == 0 ))
  } >"$RECOVERY_SCRIPT_TEMP"; then
    cleanup_joint_generation || true
    return 1
  fi
  if ! /bin/bash -n "$RECOVERY_SCRIPT_TEMP" ||
    ! /bin/chmod 0700 "$RECOVERY_SCRIPT_TEMP" ||
    ! "$MV" -fT -- "$RECOVERY_SCRIPT_TEMP" "$RECOVERY_SCRIPT"; then
    cleanup_joint_generation || true
    return 1
  fi
  RECOVERY_SCRIPT_TEMP=""
  if [[ ! -f "$RECOVERY_SCRIPT" || -L "$RECOVERY_SCRIPT" ||
    ! -x "$RECOVERY_SCRIPT" ]]; then
    cleanup_joint_generation || true
    return 1
  fi
}


write_first_install_cleanup_script() {
  local lock_identity phase_identity enable_identity root_identity
  local service_identity updater_identity cleanup_token
  local build_state=absent build_identity=''
  local previous_state=absent previous_identity=''
  local inspection_previous
  local script_write_count=0
  local script_write_fail_at="${NINEROUTER_TEST_FAIL_SCRIPT_WRITE_AT:-0}"
  local script_write_failed=0
  local path

  (( UNIT_EXISTED == 0 && UPDATER_EXISTED == 0 &&
    UNIT_BACKUP_READY == 0 && UPDATER_BACKUP_READY == 0 )) || return 1
  case "$DEPLOY_ROOT_EXISTED" in
    0)
      [[ "$ENABLE_STATE" == not-found ]] || return 1
      path_is_absent "$PREVIOUS_DIR" || return 1
      ;;
    1)
      [[ "$ENABLE_STATE" == disabled || "$ENABLE_STATE" == not-found ]] || return 1
      path_is_safe_directory "$PREVIOUS_DIR" || return 1
      previous_state=present
      previous_identity="$("$STAT" -Lc '%d:%i' -- "$PREVIOUS_DIR")" || return 1
      ;;
    *) return 1 ;;
  esac
  [[ -f "$RECOVERY_ENABLE_STATE" && ! -L "$RECOVERY_ENABLE_STATE" ]] || return 1
  [[ "$(<"$RECOVERY_ENABLE_STATE")" == "$ENABLE_STATE" ]] || return 1
  [[ -f "$PHASE_FILE" && ! -L "$PHASE_FILE" ]] || return 1
  [[ "$(<"$PHASE_FILE")" == "$UPDATER_PHASE" ]] || return 1
  path_is_safe_directory "$DEPLOY_ROOT" || return 1
  inspection_previous="$DEPLOY_ROOT/.previous-release-inspection"
  path_is_absent "$inspection_previous" || return 1
  [[ -f "$SERVICE_TARGET" && ! -L "$SERVICE_TARGET" ]] || return 1
  [[ -f "$UPDATER_TARGET" && ! -L "$UPDATER_TARGET" ]] || return 1
  path_is_absent "$RECOVERY_UNIT" || return 1
  path_is_absent "$RECOVERY_UPDATER" || return 1
  for path in "$FIRST_INSTALL_CLEANUP_SCRIPT" "$FIRST_INSTALL_CLEANUP_STEP"; do
    path_is_absent "$path" || return 1
  done
  if [[ -e "$BUILD_DIR" || -L "$BUILD_DIR" ]]; then
    path_is_safe_directory "$BUILD_DIR" || return 1
    build_state=present
    build_identity="$("$STAT" -Lc '%d:%i' -- "$BUILD_DIR")" || return 1
  fi

  lock_identity="$("$STAT" -Lc '%d:%i' -- "$LOCK_FILE")" || return 1
  phase_identity="$("$STAT" -Lc '%d:%i' -- "$PHASE_FILE")" || return 1
  enable_identity="$("$STAT" -Lc '%d:%i' -- "$RECOVERY_ENABLE_STATE")" || return 1
  root_identity="$("$STAT" -Lc '%d:%i' -- "$DEPLOY_ROOT")" || return 1
  service_identity="$("$STAT" -Lc '%d:%i' -- "$SERVICE_TARGET")" || return 1
  updater_identity="$("$STAT" -Lc '%d:%i' -- "$UPDATER_TARGET")" || return 1
  cleanup_token="${lock_identity}:${phase_identity}:${root_identity}:${service_identity}:${updater_identity}:${previous_identity}"

  FIRST_INSTALL_CLEANUP_STEP_TEMP="$(/usr/bin/mktemp "${FIRST_INSTALL_CLEANUP_STEP}.tmp.XXXXXX")" ||
    return 1
  if ! printf 'prepared %s\n' "$cleanup_token" >"$FIRST_INSTALL_CLEANUP_STEP_TEMP" ||
    ! /bin/chmod 0600 "$FIRST_INSTALL_CLEANUP_STEP_TEMP" ||
    ! "$MV" -fT -- "$FIRST_INSTALL_CLEANUP_STEP_TEMP" "$FIRST_INSTALL_CLEANUP_STEP"; then
    cleanup_first_install_generation || true
    return 1
  fi
  FIRST_INSTALL_CLEANUP_STEP_TEMP=""

  FIRST_INSTALL_CLEANUP_SCRIPT_TEMP="$(/usr/bin/mktemp "${FIRST_INSTALL_CLEANUP_SCRIPT}.tmp.XXXXXX")" || {
    cleanup_first_install_generation || true
    return 1
  }
  if ! {
    script_printf '#!/usr/bin/env bash\n' || script_write_failed=1
    script_printf 'set -Eeuo pipefail\numask 077\n' || script_write_failed=1
    script_printf 'TEST_MODE=%q\n' "$TEST_MODE" || script_write_failed=1
    script_printf 'LOCK_FILE=%q\nPHASE_FILE=%q\n' "$LOCK_FILE" "$PHASE_FILE" ||
      script_write_failed=1
    script_printf 'RECOVERY_UNIT=%q\nRECOVERY_UPDATER=%q\nRECOVERY_ENABLE_STATE=%q\n' \
      "$RECOVERY_UNIT" "$RECOVERY_UPDATER" "$RECOVERY_ENABLE_STATE" || script_write_failed=1
    script_printf 'SCRIPT_PATH=%q\nSTEP_PATH=%q\nDEPLOY_ROOT=%q\n' \
      "$FIRST_INSTALL_CLEANUP_SCRIPT" "$FIRST_INSTALL_CLEANUP_STEP" "$DEPLOY_ROOT" ||
      script_write_failed=1
    script_printf 'BUILD_DIR=%q\nPREVIOUS_DIR=%q\nINSPECTION_PREVIOUS=%q\n' \
      "$BUILD_DIR" "$PREVIOUS_DIR" "$inspection_previous" || script_write_failed=1
    script_printf 'SERVICE_TARGET=%q\nUPDATER_TARGET=%q\n' \
      "$SERVICE_TARGET" "$UPDATER_TARGET" || script_write_failed=1
    script_printf 'SYSTEMCTL=%q\nFLOCK=%q\nSTAT=%q\nMV=%q\nRM=%q\n' \
      "$SYSTEMCTL" "$FLOCK" "$STAT" "$MV" "$RM" || script_write_failed=1
    script_printf 'EXPECTED_LOCK_ID=%q\nEXPECTED_PHASE=%q\nEXPECTED_PHASE_ID=%q\n' \
      "$lock_identity" "$UPDATER_PHASE" "$phase_identity" || script_write_failed=1
    script_printf 'EXPECTED_ENABLE_ID=%q\nEXPECTED_ROOT_ID=%q\n' \
      "$enable_identity" "$root_identity" || script_write_failed=1
    script_printf 'EXPECTED_SERVICE_ID=%q\nEXPECTED_UPDATER_ID=%q\n' \
      "$service_identity" "$updater_identity" || script_write_failed=1
    script_printf 'EXPECTED_ENABLE_STATE=%q\nEXPECTED_PREVIOUS_STATE=%q\nEXPECTED_PREVIOUS_ID=%q\n' \
      "$ENABLE_STATE" "$previous_state" "$previous_identity" || script_write_failed=1
    script_printf 'EXPECTED_BUILD_STATE=%q\nEXPECTED_BUILD_ID=%q\n' \
      "$build_state" "$build_identity" || script_write_failed=1
    script_printf 'EXPECTED_TOKEN=%q\n' "$cleanup_token" || script_write_failed=1
    while IFS= read -r line; do
      script_printf '%s\n' "$line" || script_write_failed=1
    done <<'CLEANUP_BODY'

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

is_absent() {
  [[ ! -e "$1" && ! -L "$1" ]]
}

same_followed_inode() {
  local expected="$1" path="$2" actual
  actual="$("$STAT" -Lc '%d:%i' -- "$path")" || return 1
  [[ "$actual" == "$expected" ]]
}

safe_regular_with_id() {
  local expected="$1" path="$2"
  [[ -f "$path" && ! -L "$path" ]] || return 1
  same_followed_inode "$expected" "$path"
}

safe_directory_with_id() {
  local expected="$1" path="$2"
  [[ -d "$path" && ! -L "$path" ]] || return 1
  same_followed_inode "$expected" "$path"
}

validate_static_scene() {
  safe_directory_with_id "$EXPECTED_ROOT_ID" "$DEPLOY_ROOT" ||
    die '失败代码目录在收尾期间发生变化'
  is_absent "$RECOVERY_UNIT" && is_absent "$RECOVERY_UPDATER" ||
    die '检测到旧入口恢复材料；拒绝按首次安装收尾'
  case "$EXPECTED_BUILD_STATE" in
    present)
      safe_directory_with_id "$EXPECTED_BUILD_ID" "$BUILD_DIR" ||
        die 'BUILD 现场与收尾脚本生成时不一致'
      ;;
    absent)
      is_absent "$BUILD_DIR" || die 'BUILD 现场与收尾脚本生成时不一致'
      ;;
    *) die '收尾脚本中的 BUILD 预期无效' ;;
  esac
}

previous_scene() {
  case "$EXPECTED_PREVIOUS_STATE" in
    absent)
      if is_absent "$PREVIOUS_DIR" && is_absent "$INSPECTION_PREVIOUS"; then
        printf 'archived\n'
      else
        return 1
      fi
      ;;
    present)
      if safe_directory_with_id "$EXPECTED_PREVIOUS_ID" "$PREVIOUS_DIR" &&
        is_absent "$INSPECTION_PREVIOUS"; then
        printf 'unarchived\n'
      elif is_absent "$PREVIOUS_DIR" &&
        safe_directory_with_id "$EXPECTED_PREVIOUS_ID" "$INSPECTION_PREVIOUS"; then
        printf 'archived\n'
      else
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

ensure_stopped() {
  local active_state active_status
  "$SYSTEMCTL" stop 9router || die '停止失败服务失败；收尾未修改下一项现场'
  if active_state="$("$SYSTEMCTL" is-active 9router 2>/dev/null)"; then
    die '停止后服务仍处于 active；收尾未修改下一项现场'
  else
    active_status=$?
  fi
  [[ "$active_status" -eq 3 &&
    ( "$active_state" == inactive || "$active_state" == failed ) ]] ||
    die '无法确认失败服务已停止；收尾未修改下一项现场'
}

validate_cleanup_systemd_state() {
  local allow_missing="${1:-0}"
  local enable_state enable_status active_state active_status

  if enable_state="$("$SYSTEMCTL" is-enabled 9router 2>/dev/null)"; then
    enable_status=0
  else
    enable_status=$?
  fi
  if [[ "$enable_status" -eq 1 && "$enable_state" == disabled ]]; then
    :
  elif [[ "$allow_missing" == 1 &&
    ( "$enable_status" -eq 1 || "$enable_status" -eq 4 ) &&
    "$enable_state" == not-found ]]; then
    :
  else
    die '首次安装收尾后的 enable 状态不是 disabled/not-found'
  fi

  if active_state="$("$SYSTEMCTL" is-active 9router 2>/dev/null)"; then
    die '首次安装收尾后的服务仍处于 active'
  else
    active_status=$?
  fi
  if [[ "$active_status" -eq 3 &&
    ( "$active_state" == inactive || "$active_state" == failed ) ]]; then
    return 0
  fi
  [[ "$allow_missing" == 1 && "$active_status" -eq 4 &&
    "$active_state" == unknown ]] ||
    die '首次安装收尾后的服务运行状态无法确认'
}

write_stage() {
  local next_stage="$1" step_temp
  step_temp="$(/usr/bin/mktemp "${STEP_PATH}.tmp.XXXXXX")" ||
    die '无法创建收尾阶段临时文件'
  if ! printf '%s %s\n' "$next_stage" "$EXPECTED_TOKEN" >"$step_temp" ||
    ! /bin/chmod 0600 "$step_temp" ||
    ! "$MV" -fT -- "$step_temp" "$STEP_PATH"; then
    "$RM" -f -- "$step_temp" || true
    die '无法原子推进收尾阶段；可在核对现场后重试同一脚本'
  fi
}

read_stage() {
  local stage_value token_value extra=''
  is_absent "$STEP_PATH" && return 2
  [[ -f "$STEP_PATH" && ! -L "$STEP_PATH" ]] || die '收尾阶段路径类型不安全'
  read -r stage_value token_value extra <"$STEP_PATH" || die '收尾阶段文件不可读'
  [[ -z "$extra" && "$token_value" == "$EXPECTED_TOKEN" ]] ||
    die '收尾阶段文件内容已变化'
  case "$stage_value" in
    prepared|disabled|unit_removed|updater_removed|systemd_reloaded)
      printf '%s\n' "$stage_value"
      ;;
    *) die '收尾阶段文件状态无效' ;;
  esac
}

validate_required_markers() {
  safe_regular_with_id "$EXPECTED_ENABLE_ID" "$RECOVERY_ENABLE_STATE" ||
    die 'enable 状态恢复材料已变化'
  [[ "$(<"$RECOVERY_ENABLE_STATE")" == "$EXPECTED_ENABLE_STATE" ]] ||
    die 'enable 状态恢复材料内容已变化'
  safe_regular_with_id "$EXPECTED_PHASE_ID" "$PHASE_FILE" || die '阶段文件已变化'
  [[ "$(<"$PHASE_FILE")" == "$EXPECTED_PHASE" ]] || die '阶段文件内容已变化'
}

validate_markers_or_absent() {
  if ! is_absent "$RECOVERY_ENABLE_STATE"; then
    safe_regular_with_id "$EXPECTED_ENABLE_ID" "$RECOVERY_ENABLE_STATE" ||
      die 'enable 状态恢复材料处于不确定现场'
    [[ "$(<"$RECOVERY_ENABLE_STATE")" == "$EXPECTED_ENABLE_STATE" ]] ||
      die 'enable 状态恢复材料内容已变化'
  fi
  if ! is_absent "$PHASE_FILE"; then
    safe_regular_with_id "$EXPECTED_PHASE_ID" "$PHASE_FILE" ||
      die '阶段文件处于不确定现场'
    [[ "$(<"$PHASE_FILE")" == "$EXPECTED_PHASE" ]] || die '阶段文件内容已变化'
  fi
}

validate_final_scene() {
  validate_static_scene
  [[ "$(previous_scene)" == archived ]] || return 1
  is_absent "$SERVICE_TARGET" && is_absent "$UPDATER_TARGET" &&
    is_absent "$RECOVERY_ENABLE_STATE" && is_absent "$PHASE_FILE"
}

remove_checked_marker() {
  local expected="$1" path="$2" label="$3"
  if is_absent "$path"; then return 0; fi
  safe_regular_with_id "$expected" "$path" || die "$label 处于不确定现场"
  if ! "$RM" -f -- "$path"; then
    is_absent "$path" || die "无法清理 $label"
    die "$label 已清理但命令报错；请重试同一脚本"
  fi
}

[[ "$TEST_MODE" == 1 || "$EUID" -eq 0 ]] || die '首次安装收尾脚本必须以 root 身份运行'
for command_path in "$SYSTEMCTL" "$FLOCK" "$STAT" "$MV" "$RM"; do
  [[ -x "$command_path" ]] || die "收尾所需命令不可执行：$command_path"
done
[[ -f "$SCRIPT_PATH" && ! -L "$SCRIPT_PATH" && -x "$SCRIPT_PATH" ]] ||
  die '固定首次安装收尾脚本路径不安全'
[[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" ]] || die '共享更新锁路径不安全'

exec 8>>"$LOCK_FILE"
"$FLOCK" -n 8 || die '已有 9Router 安装或更新事务正在执行；首次安装收尾未执行'
if [[ -e /proc/self/fd/8 ]]; then lock_fd_path=/proc/self/fd/8; else lock_fd_path=/dev/fd/8; fi
same_followed_inode "$EXPECTED_LOCK_ID" "$LOCK_FILE" ||
  die '共享更新锁 inode 已变化；首次安装收尾未执行'
same_followed_inode "$EXPECTED_LOCK_ID" "$lock_fd_path" ||
  die '共享更新锁 FD 与固定锁路径不一致；首次安装收尾未执行'
same_followed_inode "$EXPECTED_LOCK_ID" "$LOCK_FILE" ||
  die '共享更新锁路径在 FD 校验期间发生变化；首次安装收尾未执行'

validate_static_scene
if stage="$(read_stage)"; then
  :
else
  stage_status=$?
  if [[ "$stage_status" -eq 2 ]]; then
    if validate_final_scene; then
      validate_cleanup_systemd_state 1
      "$RM" -f -- "$SCRIPT_PATH" || die '首次安装收尾已完成，但无法清理固定脚本'
      printf '首次安装入口与事务标记已安全清理；失败代码目录保留在 %s。\n' "$DEPLOY_ROOT"
      exit 0
    fi
    die '收尾阶段文件缺失且现场不是已完成状态；首次安装收尾未执行'
  fi
  die '收尾阶段文件存在但不安全；首次安装收尾未执行'
fi
if [[ "$stage" == systemd_reloaded ]]; then
  validate_markers_or_absent
else
  validate_required_markers
fi

if [[ "$stage" == prepared ]]; then
  safe_regular_with_id "$EXPECTED_SERVICE_ID" "$SERVICE_TARGET" ||
    die '本次新 unit 现场已变化'
  safe_regular_with_id "$EXPECTED_UPDATER_ID" "$UPDATER_TARGET" ||
    die '本次新 updater 现场已变化'
  ensure_stopped
  "$SYSTEMCTL" disable 9router || die 'disable 失败；首次安装收尾已停止'
  validate_cleanup_systemd_state 0
  previous_state="$(previous_scene)" || die 'previous 检查现场不确定'
  if [[ "$previous_state" == unarchived ]]; then
    if ! "$MV" -T -- "$PREVIOUS_DIR" "$INSPECTION_PREVIOUS"; then
      if is_absent "$PREVIOUS_DIR" &&
        safe_directory_with_id "$EXPECTED_PREVIOUS_ID" "$INSPECTION_PREVIOUS"; then
        die 'previous 已转存供检查，但命令报错；请重试同一收尾脚本'
      fi
      die '无法安全转存 previous 供检查；首次安装收尾已停止'
    fi
  fi
  [[ "$(previous_scene)" == archived ]] || die 'previous 转存后现场验证失败'
  write_stage disabled
  stage=disabled
fi

if [[ "$stage" == disabled ]]; then
  [[ "$(previous_scene)" == archived ]] || die 'disabled 阶段 previous 现场已变化'
  if ! is_absent "$SERVICE_TARGET"; then
    safe_regular_with_id "$EXPECTED_SERVICE_ID" "$SERVICE_TARGET" ||
      die '本次新 unit 现场已变化'
  fi
  safe_regular_with_id "$EXPECTED_UPDATER_ID" "$UPDATER_TARGET" ||
    die '本次新 updater 现场已变化'
  validate_cleanup_systemd_state 1
  if ! is_absent "$SERVICE_TARGET"; then
    if ! "$RM" -f -- "$SERVICE_TARGET"; then
      is_absent "$SERVICE_TARGET" &&
        die '本次新 unit 已移除，但命令报错；请重试同一收尾脚本'
      die '无法移除本次新 unit；首次安装收尾已停止'
    fi
  fi
  write_stage unit_removed
  stage=unit_removed
fi

if [[ "$stage" == unit_removed ]]; then
  [[ "$(previous_scene)" == archived ]] || die 'unit_removed 阶段 previous 现场已变化'
  is_absent "$SERVICE_TARGET" || die 'unit_removed 阶段仍存在 unit'
  if ! is_absent "$UPDATER_TARGET"; then
    safe_regular_with_id "$EXPECTED_UPDATER_ID" "$UPDATER_TARGET" ||
      die '本次新 updater 现场已变化'
  fi
  validate_cleanup_systemd_state 1
  if ! is_absent "$UPDATER_TARGET"; then
    if ! "$RM" -f -- "$UPDATER_TARGET"; then
      is_absent "$UPDATER_TARGET" &&
        die '本次新 updater 已移除，但命令报错；请重试同一收尾脚本'
      die '无法移除本次新 updater；首次安装收尾已停止'
    fi
  fi
  write_stage updater_removed
  stage=updater_removed
fi

if [[ "$stage" == updater_removed ]]; then
  [[ "$(previous_scene)" == archived ]] || die 'updater_removed 阶段 previous 现场已变化'
  is_absent "$SERVICE_TARGET" && is_absent "$UPDATER_TARGET" ||
    die 'updater_removed 阶段仍存在本次安装入口'
  "$SYSTEMCTL" daemon-reload || die 'systemd daemon-reload 失败；请重试同一收尾脚本'
  validate_cleanup_systemd_state 1
  write_stage systemd_reloaded
  stage=systemd_reloaded
fi

if [[ "$stage" == systemd_reloaded ]]; then
  [[ "$(previous_scene)" == archived ]] || die 'systemd_reloaded 阶段 previous 现场已变化'
  is_absent "$SERVICE_TARGET" && is_absent "$UPDATER_TARGET" ||
    die 'systemd_reloaded 阶段入口现场已变化'
  validate_markers_or_absent
  validate_cleanup_systemd_state 1
  remove_checked_marker "$EXPECTED_ENABLE_ID" \
    "$RECOVERY_ENABLE_STATE" 'enable 状态恢复材料'
  remove_checked_marker "$EXPECTED_PHASE_ID" "$PHASE_FILE" '阶段文件'
  if ! "$RM" -f -- "$STEP_PATH"; then
    is_absent "$STEP_PATH" || die '无法清理收尾阶段文件'
    die '收尾阶段文件已清理但命令报错；请重试同一脚本'
  fi
  "$RM" -f -- "$SCRIPT_PATH" || die '收尾完成，但无法清理固定收尾脚本'
  printf '首次安装入口与事务标记已安全清理；失败代码目录保留在 %s。\n' "$DEPLOY_ROOT"
fi
CLEANUP_BODY
    (( script_write_failed == 0 ))
  } >"$FIRST_INSTALL_CLEANUP_SCRIPT_TEMP"; then
    cleanup_first_install_generation || true
    return 1
  fi
  if ! /bin/bash -n "$FIRST_INSTALL_CLEANUP_SCRIPT_TEMP" ||
    ! /bin/chmod 0700 "$FIRST_INSTALL_CLEANUP_SCRIPT_TEMP" ||
    ! "$MV" -fT -- "$FIRST_INSTALL_CLEANUP_SCRIPT_TEMP" \
      "$FIRST_INSTALL_CLEANUP_SCRIPT"; then
    cleanup_first_install_generation || true
    return 1
  fi
  FIRST_INSTALL_CLEANUP_SCRIPT_TEMP=""
  if [[ ! -f "$FIRST_INSTALL_CLEANUP_SCRIPT" ||
    -L "$FIRST_INSTALL_CLEANUP_SCRIPT" || ! -x "$FIRST_INSTALL_CLEANUP_SCRIPT" ]]; then
    cleanup_first_install_generation || true
    return 1
  fi
}


report_joint_recovery() {
  if (( UNIT_EXISTED == 0 && UPDATER_EXISTED == 0 &&
    UNIT_BACKUP_READY == 0 && UPDATER_BACKUP_READY == 0 )) &&
    [[ "$ENABLE_STATE" == not-found || "$ENABLE_STATE" == disabled ]]; then
    if write_first_install_cleanup_script; then
      printf '首次安装安全收尾：%s\n' "$FIRST_INSTALL_CLEANUP_SCRIPT" >&2
    else
      printf '首次安装收尾现场未通过严格验证；未生成脚本，请保留现场并人工核对。\n' >&2
    fi
    return 0
  fi
  if (( UNIT_EXISTED != 1 || UPDATER_EXISTED != 1 ||
    UNIT_BACKUP_READY != 1 || UPDATER_BACKUP_READY != 1 )); then
    printf '没有旧 unit 与旧 updater 可供联合恢复；这是首次安装或旧入口材料不完整，不生成联合恢复脚本。\n' >&2
    return 0
  fi
  if ! write_joint_recovery_script; then
    printf '联合恢复现场或材料未通过严格验证；未生成脚本，请保留现场并人工核对。\n' >&2
    return 0
  fi
  printf '人工联合恢复：%s\n' "$RECOVERY_SCRIPT" >&2
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
        old_move_intent|new_move_intent)
          if intent_scene_is_unchanged; then
            restore_pre_switch || true
          else
            preserve_uncertain_intent
          fi
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

  for override in UPDATER_TARGET SERVICE_TARGET DATA_DIR ROOT BUILD_DIR PREVIOUS_DIR LOCK_FILE PHASE_FILE RECOVERY_UNIT \
    RECOVERY_UPDATER RECOVERY_ENABLE_STATE RECOVERY_SCRIPT FIRST_INSTALL_CLEANUP_SCRIPT \
    SYSTEMCTL NODE NPM GIT CURL FLOCK STAT MKDIR CP MV RM INSTALL; do
    env_name="NINEROUTER_${override}"
    [[ -n "${!env_name+x}" ]] || die "root 测试模式缺少 $env_name"
  done

  UPDATER_TARGET="$NINEROUTER_UPDATER_TARGET"
  DEPLOY_ROOT="$NINEROUTER_ROOT"
  BUILD_DIR="$NINEROUTER_BUILD_DIR"
  PREVIOUS_DIR="$NINEROUTER_PREVIOUS_DIR"
  SERVICE_TARGET="$NINEROUTER_SERVICE_TARGET"
  DATA_DIR="$NINEROUTER_DATA_DIR"
  LOCK_FILE="$NINEROUTER_LOCK_FILE"
  PHASE_FILE="$NINEROUTER_PHASE_FILE"
  RECOVERY_UNIT="$NINEROUTER_RECOVERY_UNIT"
  RECOVERY_UPDATER="$NINEROUTER_RECOVERY_UPDATER"
  RECOVERY_ENABLE_STATE="$NINEROUTER_RECOVERY_ENABLE_STATE"
  RECOVERY_SCRIPT="$NINEROUTER_RECOVERY_SCRIPT"
  FIRST_INSTALL_CLEANUP_SCRIPT="$NINEROUTER_FIRST_INSTALL_CLEANUP_SCRIPT"
  SYSTEMCTL="$NINEROUTER_SYSTEMCTL"
  NODE="$NINEROUTER_NODE"
  NPM="$NINEROUTER_NPM"
  GIT="$NINEROUTER_GIT"
  CURL="$NINEROUTER_CURL"
  FLOCK="$NINEROUTER_FLOCK"
  STAT="$NINEROUTER_STAT"
  MKDIR="$NINEROUTER_MKDIR"
  CP="$NINEROUTER_CP"
  MV="$NINEROUTER_MV"
  RM="$NINEROUTER_RM"
  INSTALL="$NINEROUTER_INSTALL"

  for target in DATA_DIR LOCK_FILE PHASE_FILE RECOVERY_UNIT \
    RECOVERY_UPDATER RECOVERY_ENABLE_STATE RECOVERY_SCRIPT FIRST_INSTALL_CLEANUP_SCRIPT \
    SYSTEMCTL NODE NPM GIT CURL FLOCK STAT MKDIR CP MV RM INSTALL; do
    validate_test_path "$target" "${!target}"
  done
  validate_test_path UPDATER_TARGET "$UPDATER_TARGET" 1
  validate_test_path SERVICE_TARGET "$SERVICE_TARGET" 1
  validate_test_path DEPLOY_ROOT "$DEPLOY_ROOT"
  validate_test_path BUILD_DIR "$BUILD_DIR"
  validate_test_path PREVIOUS_DIR "$PREVIOUS_DIR"
else
  for override in NINEROUTER_TEST_MODE NINEROUTER_TEST_ROOT NINEROUTER_UPDATER_TARGET \
    NINEROUTER_SERVICE_TARGET NINEROUTER_DATA_DIR NINEROUTER_LOCK_FILE NINEROUTER_PHASE_FILE \
    NINEROUTER_ROOT NINEROUTER_BUILD_DIR NINEROUTER_PREVIOUS_DIR \
    NINEROUTER_RECOVERY_UNIT NINEROUTER_RECOVERY_UPDATER NINEROUTER_RECOVERY_ENABLE_STATE \
    NINEROUTER_RECOVERY_SCRIPT NINEROUTER_FIRST_INSTALL_CLEANUP_SCRIPT \
    NINEROUTER_SYSTEMCTL NINEROUTER_NODE NINEROUTER_NPM NINEROUTER_GIT NINEROUTER_CURL \
    NINEROUTER_FLOCK NINEROUTER_STAT NINEROUTER_MKDIR NINEROUTER_CP NINEROUTER_MV \
    NINEROUTER_RM NINEROUTER_INSTALL; do
    [[ -z "${!override+x}" ]] || die "root 环境拒绝 $override 覆盖"
  done

  UPDATER_TARGET=/usr/local/sbin/9router-update
  DEPLOY_ROOT=/opt/9router
  BUILD_DIR=/opt/9router-build
  PREVIOUS_DIR=/opt/9router.previous
  SERVICE_TARGET=/etc/systemd/system/9router.service
  DATA_DIR=/root/.9router
  LOCK_FILE=/run/9router-update.lock
  PHASE_FILE=/run/9router-update.phase
  RECOVERY_UNIT=/run/9router-install-recovery.unit
  RECOVERY_UPDATER=/run/9router-install-recovery.updater
  RECOVERY_ENABLE_STATE=/run/9router-install-recovery.enable-state
  RECOVERY_SCRIPT=/run/9router-install-recover
  FIRST_INSTALL_CLEANUP_SCRIPT=/run/9router-install-cleanup
  SYSTEMCTL=/usr/bin/systemctl
  NODE=/opt/node-v24.15.0-npm/node/bin/node
  NPM=/opt/node-v24.15.0-npm/node/bin/npm
  GIT=/usr/bin/git
  CURL=/usr/bin/curl
  FLOCK=/usr/bin/flock
  STAT=/usr/bin/stat
  MKDIR=/bin/mkdir
  CP=/bin/cp
  MV=/bin/mv
  RM=/bin/rm
  INSTALL=/usr/bin/install
fi

RECOVERY_WORK_UNIT="${RECOVERY_UNIT}.work"
RECOVERY_WORK_UPDATER="${RECOVERY_UPDATER}.work"
RECOVERY_STEP="${RECOVERY_SCRIPT}.step"
FIRST_INSTALL_CLEANUP_STEP="${FIRST_INSTALL_CLEANUP_SCRIPT}.step"
FAILED_ROOT="${DEPLOY_ROOT}.failed"
if [[ "$TEST_MODE" == 1 ]]; then
  validate_test_path RECOVERY_WORK_UNIT "$RECOVERY_WORK_UNIT"
  validate_test_path RECOVERY_WORK_UPDATER "$RECOVERY_WORK_UPDATER"
  validate_test_path RECOVERY_STEP "$RECOVERY_STEP"
  validate_test_path FIRST_INSTALL_CLEANUP_STEP "$FIRST_INSTALL_CLEANUP_STEP"
  validate_test_path FAILED_ROOT "$FAILED_ROOT"
fi

require_executable Node "$NODE"
require_executable npm "$NPM"
require_executable git "$GIT"
require_executable curl "$CURL"
require_executable flock "$FLOCK"
require_executable stat "$STAT"
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
path_is_absent "$FAILED_ROOT" ||
  die "检测到失败代码检查目录，拒绝改写安装入口；请先检查并移走或清理：$FAILED_ROOT"

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

if [[ "$ENABLE_STATE" == masked && "$SERVICE_WAS_ACTIVE" -eq 1 ]]; then
  die '检测到 9router 同时为 masked 且 active；请先 unmask 并确认运行状态后再安装'
fi

if [[ -e "$DEPLOY_ROOT" || -L "$DEPLOY_ROOT" ]]; then
  path_is_safe_directory "$DEPLOY_ROOT" ||
    die "正式部署路径必须是非符号链接目录：$DEPLOY_ROOT"
  DEPLOY_ROOT_EXISTED=1
  DEPLOY_ROOT_INITIAL_ID="$("$STAT" -Lc '%d:%i' -- "$DEPLOY_ROOT")" ||
    die "无法记录正式部署目录 inode：$DEPLOY_ROOT"
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
