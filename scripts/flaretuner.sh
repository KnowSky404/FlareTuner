#!/usr/bin/env bash
set -euo pipefail

APP_NAME="FlareTuner"
VERSION="0.2.0"

ETC_DIR="${FLARETUNER_ETC_DIR:-/etc}"
SYSCTL_ROOT="${FLARETUNER_SYSCTL_ROOT:-}"
BOOT_ID_FILE="${FLARETUNER_BOOT_ID:-/proc/sys/kernel/random/boot_id}"

MANAGED_CONF="${FLARETUNER_MANAGED_CONF:-${FLARETUNER_ETC_DIR:-/etc}/sysctl.d/99-flaretuner.conf}"
STATE_DIR="${FLARETUNER_STATE_DIR:-/var/lib/flaretuner}"
BACKUP_DIR="$STATE_DIR/backup"
LATEST_BACKUP_FILE="$STATE_DIR/latest-backup.env"
TC_LIMIT_FILE="$STATE_DIR/tc-limit.env"
OS_RELEASE_FILE="${FLARETUNER_OS_RELEASE:-/etc/os-release}"
SYSCTL_CMD="${FLARETUNER_SYSCTL_CMD:-sysctl}"
MODPROBE_CMD="${FLARETUNER_MODPROBE_CMD:-modprobe}"
LSMOD_CMD="${FLARETUNER_LSMOD_CMD:-lsmod}"
UNAME_CMD="${FLARETUNER_UNAME_CMD:-uname}"
ID_CMD="${FLARETUNER_ID_CMD:-id}"
MEMINFO_FILE="${FLARETUNER_MEMINFO:-/proc/meminfo}"
NET_CLASS_DIR="${FLARETUNER_NET_CLASS_DIR:-/sys/class/net}"
TC_CMD="${FLARETUNER_TC_CMD:-tc}"
STAT_CMD="${FLARETUNER_STAT_CMD:-stat}"

die() {
  echo "Error: $*" >&2
  exit 1
}

info() {
  echo "==> $*"
}

os_release_value() {
  local key="$1"
  local line value

  [[ -r "$OS_RELEASE_FILE" ]] || return 1

  while IFS= read -r line; do
    [[ "$line" == "$key="* ]] || continue
    value="${line#*=}"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    printf '%s\n' "$value"
    return 0
  done <"$OS_RELEASE_FILE"

  return 1
}

os_id() {
  os_release_value ID || printf 'unknown\n'
}

os_pretty_name() {
  os_release_value PRETTY_NAME || os_id
}

is_supported_os() {
  case "$(os_id)" in
    debian|ubuntu)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

require_supported_os() {
  if ! is_supported_os; then
    die "$APP_NAME supports Debian and Ubuntu only. Detected: $(os_pretty_name)"
  fi
}

is_root() {
  [[ "$("$ID_CMD" -u)" == "0" ]]
}

require_root() {
  if ! is_root; then
    die "please run as root"
  fi
}

read_input() {
  local prompt="$1"
  local target_var="$2"
  local input_value

  if ! IFS= read -r -p "$prompt" input_value; then
    echo "Input ended; aborting." >&2
    return 1
  fi

  printf -v "$target_var" '%s' "$input_value"
}

sysctl_get() {
  local key="$1"
  "$SYSCTL_CMD" -n "$key" 2>/dev/null
}

bbr_available() {
  local controls
  controls="$(sysctl_get net.ipv4.tcp_available_congestion_control || true)"
  [[ " $controls " == *" bbr "* ]]
}

tcp_bbr_loaded() {
  "$LSMOD_CMD" 2>/dev/null | awk '{print $1}' | grep -qx 'tcp_bbr'
}

try_load_bbr() {
  bbr_available && return 0
  is_root || return 1

  if "$MODPROBE_CMD" tcp_bbr 2>/dev/null; then
    bbr_available && return 0
  fi

  return 1
}

# Only trusted, non-writable filesystem components may protect ownership records.
safe_path() {
  local path="$1" part uid mode links
  [[ "$path" == /* && "$path" != *'/../'* && "$path" != */.. && "$path" != *'/./'* ]] || return 1
  part="$path"
  while [[ "$part" != / ]]; do
    [[ ! -L "$part" ]] || return 1
    if [[ -e "$part" ]]; then
      [[ -d "$part" || -f "$part" ]] || return 1
      read -r uid mode links < <("$STAT_CMD" -c '%u %a %h' -- "$part") || return 1
      [[ "$uid" == 0 ]] || return 1
      if (( (8#$mode & 0022) != 0 )); then
        [[ "$part" == /tmp && -d "$part" && $((8#$mode & 01000)) != 0 ]] || return 1
      fi
      [[ -d "$part" || "$links" == 1 ]] || return 1
    fi
    part="$(dirname -- "$part")"
  done
}

require_safe_path() {
  safe_path "$1" || die "unsafe path, ownership, permissions or symlink: $1"
}

file_hash() {
  if [[ -f "$1" && ! -L "$1" ]]; then sha256sum -- "$1" | awk '{print $1}';
  elif [[ ! -e "$1" && ! -L "$1" ]]; then echo absent;
  else return 1; fi
}

atomic_publish() {
  local source="$1" destination="$2" temp
  safe_path "$destination" || return 1
  temp="$(mktemp "$(dirname -- "$destination")/.flaretuner.XXXXXX")" || return 1
  TX_TEMP_FILES+=("$temp")
  if ! cat -- "$source" >"$temp" || ! chmod 600 "$temp" || ! mv -T -- "$temp" "$destination"; then
    rm -f -- "$temp"
    return 1
  fi
}

snapshot_metadata() {
  TX_META_PATH="$1"
  require_safe_path "$TX_META_PATH"
  TX_META_BEFORE_HASH="$(file_hash "$TX_META_PATH")" || return 1
  TX_META_AFTER_HASH="$TX_META_BEFORE_HASH"
  if [[ "$TX_META_BEFORE_HASH" != absent ]]; then cp -- "$TX_META_PATH" "$TX_DIR/before-metadata.env" || return 1; fi
}

commit_metadata() {
  TX_META_AFTER_HASH="$(file_hash "$1")" || return 1
  [[ "$(file_hash "$TX_META_PATH")" == "$TX_META_BEFORE_HASH" ]] || return 1
  atomic_publish "$1" "$TX_META_PATH"
}

rollback_metadata() {
  [[ -n "$TX_META_PATH" ]] || return 0
  safe_path "$TX_META_PATH" || return 1
  local current
  current="$(file_hash "$TX_META_PATH")" || return 1
  [[ "$current" != "$TX_META_BEFORE_HASH" ]] || return 0
  [[ "$current" == "$TX_META_AFTER_HASH" ]] || return 1
  if [[ "$TX_META_BEFORE_HASH" == absent ]]; then rm -- "$TX_META_PATH";
  else atomic_publish "$TX_DIR/before-metadata.env" "$TX_META_PATH"; fi
}

begin_operation() {
  require_root
  require_supported_os
  umask 077
  require_safe_path "$STATE_DIR"
  mkdir -p -- "$STATE_DIR" || die 'cannot create state directory'
  require_safe_path "$STATE_DIR/.lock"
  exec {TX_LOCK_FD}>"$STATE_DIR/.lock" || die 'cannot open operation lock'
  flock -n "$TX_LOCK_FD" || die 'another FlareTuner operation is running'
  local pending
  for pending in "$STATE_DIR"/transaction.*; do
    [[ ! -e "$pending" && ! -L "$pending" ]] || die "unfinished transaction requires manual recovery: $pending"
  done
  TX_DIR="$(mktemp -d "$STATE_DIR/transaction.XXXXXX")" || die 'cannot create transaction journal'
  TX_ARMED=0
  TX_KIND="$1"
  TX_TEMP_FILES=()
  TX_META_PATH=
  printf '%s\n' "$TX_KIND" >"$TX_DIR/operation" || die 'cannot write transaction journal'
  trap 'finish_operation $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

finish_operation() {
  local status="$1" rollback_status=0 temp
  trap - EXIT INT TERM HUP
  set +e
  if [[ "$TX_ARMED" == 1 ]]; then
    echo "Operation failed/interrupted; attempting guarded $TX_KIND rollback." >&2
    if [[ "$TX_KIND" == sysctl ]]; then rollback_sysctl; else rollback_tc; fi
    rollback_status=$?
    if [[ "$rollback_status" == 0 ]]; then rollback_metadata; rollback_status=$?; fi
    [[ "$status" != 0 ]] || status=1
  fi
  for temp in "${TX_TEMP_FILES[@]}"; do rm -f -- "$temp"; done
  if [[ "$rollback_status" != 0 ]]; then
    printf 'operation_status=%s\nrollback_status=%s\n' "$status" "$rollback_status" >"$TX_DIR/result"
    echo "Recovery incomplete or unsafe; journal retained at $TX_DIR. Manual recovery required." >&2
    status=2
  else
    if ! rm -r -- "$TX_DIR"; then
      echo "Cannot remove completed transaction journal: $TX_DIR" >&2
      status=2
    fi
  fi
  exit "$status"
}

# Parse without executing configuration. These managed keys have no interface names.
config_entries() {
  awk '
    /^[[:space:]]*([#;]|$)/ {next}
    {
      line=$0; sub(/^[[:space:]]*/, "", line); sub(/[[:space:]]*$/, "", line)
      if (index(line,"=")==0) {
        if (line ~ /^-[^[:space:]=]+$/) {
          key=substr(line,2); gsub(/\//,".",key); print "!exclude\t" key
        } else print "!unknown\t" line
        next
      }
      key=substr(line,1,index(line,"=")-1); val=substr(line,index(line,"=")+1)
      gsub(/[[:space:]]/, "", key); sub(/^-/, "", key); gsub(/\//,".",key)
      sub(/[[:space:]]*[#;].*$/, "", val); gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      gsub(/[[:space:]]+/, " ", val)
      print key "\t" val
    }' "$1"
}

normalize_value() { awk '{$1=$1; print}'; }

# Report all declarations in effective files, not a guessed single boot-time winner.
sysctl_sources() {
  local dir file name
  local -A selected=()
  for dir in "$ETC_DIR/sysctl.d" "$SYSCTL_ROOT/run/sysctl.d" "$SYSCTL_ROOT/usr/local/lib/sysctl.d" "$SYSCTL_ROOT/usr/lib/sysctl.d" "$SYSCTL_ROOT/lib/sysctl.d"; do
    [[ ! -e "$dir" || ( -d "$dir" && -r "$dir" && -x "$dir" ) ]] || return 1
    for file in "$dir"/*.conf; do
      [[ -e "$file" || -L "$file" ]] || continue
      name="${file##*/}"
      [[ ! ${selected[$name]+yes} ]] || continue
      selected[$name]="$file"
    done
  done
  for name in "${!selected[@]}"; do printf '%s\t%s\n' "$name" "${selected[$name]}"; done | LC_ALL=C sort
  # procps --system loads this last; systemd does not load it directly.
  if [[ -e "$ETC_DIR/sysctl.conf" || -L "$ETC_DIR/sysctl.conf" ]]; then
    printf '~sysctl.conf\t%s\n' "$ETC_DIR/sysctl.conf"
  fi
}

check_sysctl_conflicts() {
  local candidate="$1" inventory file name key value target desired found=0 bad=0 owner
  local -A targets=()
  while IFS=$'\t' read -r key value; do
    [[ "$key" == net.* && -n "$value" ]] || { echo 'Sysctl sources: unknown candidate syntax'; return 1; }
    [[ ! ${targets[$key]+yes} ]] || { echo 'Sysctl sources: duplicate candidate key'; return 1; }
    targets[$key]="$value"
  done < <(config_entries "$candidate")
  (( ${#targets[@]} > 0 )) || return 1
  inventory="$(sysctl_sources)" || { echo 'Sysctl sources: unknown/unreadable directory'; return 1; }
  # A vendor file with this basename would disappear after publishing our file.
  for file in "$SYSCTL_ROOT/run/sysctl.d/99-flaretuner.conf" "$SYSCTL_ROOT/usr/local/lib/sysctl.d/99-flaretuner.conf" "$SYSCTL_ROOT/usr/lib/sysctl.d/99-flaretuner.conf" "$SYSCTL_ROOT/lib/sysctl.d/99-flaretuner.conf"; do
    if [[ -e "$file" || -L "$file" ]]; then echo "Sysctl sources: foreign reserved basename $file"; bad=1; fi
  done
  while IFS=$'\t' read -r name file; do
    [[ -n "$file" && "$file" != "$MANAGED_CONF" ]] || continue
    [[ "$(readlink -f -- "$file")" != /dev/null ]] || continue
    if [[ "$(readlink -f -- "$file")" == "$(readlink -m -- "$MANAGED_CONF")" ]]; then echo "Sysctl sources: unknown managed config alias $file"; bad=1; continue; fi
    if [[ ! -f "$file" || ! -r "$file" ]]; then echo "Sysctl sources: unknown $file"; bad=1; continue; fi
    owner=external
    if grep -Eiq 'managed by|sing-box|ansible|puppet|chef|cloud-init' "$file"; then owner=tool-managed; fi
    while IFS=$'\t' read -r key value; do
      if [[ "$key" == '!exclude' ]]; then
        for target in "${!targets[@]}"; do
          if [[ "$target" == $value ]]; then echo "Sysctl sources: uncertain exclusion $target ($file)"; bad=1; fi
        done
        continue
      fi
      if [[ "$key" == '!unknown' ]]; then echo "Sysctl sources: unknown syntax $file: $value"; bad=1; continue; fi
      for target in "${!targets[@]}"; do
        if [[ "$target" == $key ]]; then
          found=1; desired="${targets[$target]}"
          if [[ "$value" == "$desired" && "$key" == "$target" ]]; then
            echo "Sysctl sources: same $target ($owner: $file)"
          else
            echo "Sysctl sources: different/uncertain $target=$value ($owner: $file)"; bad=1
          fi
        fi
      done
    done < <(config_entries "$file")
  done <<<"$inventory"
  [[ "$found" != 0 || "$bad" != 0 ]] || echo 'Sysctl sources: no overlapping declarations'
  [[ "$bad" == 0 ]]
}

source_fingerprint() {
  local inventory name file
  inventory="$(sysctl_sources)" || return 1
  {
    while IFS=$'\t' read -r name file; do
      [[ -n "$file" && "$file" != "$MANAGED_CONF" ]] || continue
      printf '%s\n' "$file"
      if [[ "$(readlink -f -- "$file")" == /dev/null ]]; then echo masked;
      elif [[ -f "$file" && -r "$file" ]]; then sha256sum -- "$file" || return 1;
      else return 1; fi
    done <<<"$inventory"
  } | sha256sum | awk '{print $1}'
}

verify_config_runtime() {
  local file="$1" key value actual count=0
  [[ -r "$file" ]] || return 1
  while IFS=$'\t' read -r key value; do
    [[ "$key" == net.* && -n "$value" ]] || return 1
    actual="$(sysctl_get "$key")" || return 1
    actual="$(printf '%s\n' "$actual" | normalize_value)"
    if [[ "$actual" != "$value" ]]; then
      echo "Runtime drift: $key='$actual', expected '$value'" >&2
      return 1
    fi
    count=$((count + 1))
  done < <(config_entries "$file")
  (( count > 0 ))
}

snapshot_runtime() {
  local candidate="$1" destination="$2" key value actual
  : >"$destination" || return 1
  while IFS=$'\t' read -r key value; do
    actual="$(sysctl_get "$key")" || return 1
    actual="$(printf '%s\n' "$actual" | normalize_value)"
    [[ -n "$actual" ]] || return 1
    printf '%s = %s\n' "$key" "$actual" >>"$destination" || return 1
  done < <(config_entries "$candidate")
}

metadata_path_is_safe() {
  [[ "$1" != *'..'* && "$1" =~ ^[A-Za-z0-9._/:-]*$ ]]
}

load_backup_metadata() {
  local key value line
  local -A seen=()
  PARSED_PREVIOUS_EXISTS= PARSED_BACKUP_PATH= PARSED_APPLIED_HASH= PARSED_RUNTIME_PATH= PARSED_BACKUP_HASH= PARSED_RUNTIME_HASH=
  require_safe_path "$LATEST_BACKUP_FILE"
  [[ -f "$LATEST_BACKUP_FILE" && -r "$LATEST_BACKUP_FILE" ]] || die 'no FlareTuner backup metadata found'
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || die 'invalid backup metadata line'
    key="${line%%=*}"; value="${line#*=}"
    [[ "$key" =~ ^[A-Z_]+$ ]] || die 'invalid metadata key'
    [[ ! ${seen[$key]+yes} ]] || die "duplicate backup metadata key: $key"
    seen[$key]=1
    case "$key" in
      PREVIOUS_EXISTS) [[ "$value" == 0 || "$value" == 1 ]] || die 'invalid previous state'; PARSED_PREVIOUS_EXISTS="$value" ;;
      BACKUP_PATH) metadata_path_is_safe "$value" || die 'unsafe backup path'; PARSED_BACKUP_PATH="$value" ;;
      BACKUP_HASH|RUNTIME_HASH)
        [[ "$value" == absent || "$value" =~ ^[a-f0-9]{64}$ ]] || die 'invalid backup digest'
        if [[ "$key" == BACKUP_HASH ]]; then PARSED_BACKUP_HASH="$value"; else PARSED_RUNTIME_HASH="$value"; fi ;;
      APPLIED_HASH) [[ "$value" =~ ^[a-f0-9]{64}$ ]] || die 'invalid applied hash'; PARSED_APPLIED_HASH="$value" ;;
      RUNTIME_PATH) metadata_path_is_safe "$value" || die 'unsafe runtime path'; PARSED_RUNTIME_PATH="$value" ;;
      *) die "unknown backup metadata key: $key" ;;
    esac
  done <"$LATEST_BACKUP_FILE"
  [[ -n "$PARSED_PREVIOUS_EXISTS" && ${seen[BACKUP_PATH]+yes} ]] || die 'incomplete backup metadata'
  [[ "$PARSED_PREVIOUS_EXISTS" != 0 || -z "$PARSED_BACKUP_PATH" ]] || die 'unexpected backup path'
}

validate_backup_path() {
  local path="$1"
  [[ "$path" == "$BACKUP_DIR/"* && -n "${path##*/}" ]] || die 'backup path outside FlareTuner backup dir'
  require_safe_path "$path"
  [[ -f "$path" && -r "$path" && "$(readlink -f -- "$(dirname -- "$path")")" == "$(readlink -f -- "$BACKUP_DIR")" ]] || die 'invalid backup file'
}

prepare_sysctl_transaction() {
  require_safe_path "$MANAGED_CONF"
  require_safe_path "$BACKUP_DIR"
  mkdir -p -- "$(dirname -- "$MANAGED_CONF")" "$BACKUP_DIR" || return 1
  TX_BEFORE_HASH="$(file_hash "$MANAGED_CONF")" || return 1
  if [[ "$TX_BEFORE_HASH" != absent ]]; then
    grep -q '^# Managed by FlareTuner ' "$MANAGED_CONF" || die 'managed pathname contains foreign configuration'
    cp -- "$MANAGED_CONF" "$TX_DIR/before.conf" || return 1
  fi
  if [[ -e "$LATEST_BACKUP_FILE" || -L "$LATEST_BACKUP_FILE" ]]; then
    load_backup_metadata
    [[ -z "$PARSED_APPLIED_HASH" || "$TX_BEFORE_HASH" == "$PARSED_APPLIED_HASH" ]] || die 'managed config drift; refusing overwrite'
  fi
  TX_SOURCES="$(source_fingerprint)" || return 1
  sysctl_sources >"$TX_DIR/sources.list" || return 1
  printf '%s\n' "$TX_SOURCES" >"$TX_DIR/sources.sha256" || return 1
}

validate_sysctl_recovery_runtime() {
  local key value current file expected matched
  while IFS=$'\t' read -r key value; do
    current="$(sysctl_get "$key" | normalize_value)" || return 1
    matched=0
    for file in runtime.conf after.conf before.conf restore.conf; do
      [[ -f "$TX_DIR/$file" ]] || continue
      expected="$(config_entries "$TX_DIR/$file" | awk -F '\t' -v key="$key" '$1==key {print $2}')"
      if [[ -n "$expected" && "$current" == "$expected" ]]; then matched=1; break; fi
    done
    [[ "$matched" == 1 ]] || return 1
  done < <(config_entries "$TX_DIR/runtime.conf")
}

rollback_sysctl() {
  local key value recovery_status=0
  safe_path "$MANAGED_CONF" || return 1
  if [[ "$(file_hash "$MANAGED_CONF")" != "$TX_AFTER_HASH" && "$(file_hash "$MANAGED_CONF")" == "$TX_BEFORE_HASH" ]]; then
    verify_config_runtime "$TX_DIR/runtime.conf"
    return $?
  fi
  [[ "$(file_hash "$MANAGED_CONF")" == "$TX_AFTER_HASH" && "$(source_fingerprint)" == "$TX_SOURCES" ]] || return 1
  validate_sysctl_recovery_runtime || return 1
  if [[ "$TX_BEFORE_HASH" == absent ]]; then rm -- "$MANAGED_CONF" || return 1;
  else atomic_publish "$TX_DIR/before.conf" "$MANAGED_CONF" || return 1; fi
  # A broad reload error must not skip restoration of our saved runtime keys.
  if ! "$SYSCTL_CMD" --system; then
    echo 'Rollback reload failed; continuing guarded managed-runtime recovery.' >&2
    recovery_status=1
  fi
  [[ "$(file_hash "$MANAGED_CONF")" == "$TX_BEFORE_HASH" && "$(source_fingerprint)" == "$TX_SOURCES" ]] || return 1
  validate_sysctl_recovery_runtime || return 1
  while IFS=$'\t' read -r key value; do
    "$SYSCTL_CMD" -w "$key=$value" || recovery_status=1
  done < <(config_entries "$TX_DIR/runtime.conf")
  verify_config_runtime "$TX_DIR/runtime.conf" || recovery_status=1
  [[ "$(file_hash "$MANAGED_CONF")" == "$TX_BEFORE_HASH" && "$(source_fingerprint)" == "$TX_SOURCES" ]] || recovery_status=1
  return "$recovery_status"
}

apply_config() (
  begin_operation sysctl
  local config="$1" backup_path='' runtime_path
  printf '%s\n' "$config" >"$TX_DIR/after.conf" || exit 1
  prepare_sysctl_transaction || die 'cannot prepare sysctl transaction'
  check_sysctl_conflicts "$TX_DIR/after.conf" || die 'unsafe sysctl configuration conflict'
  if [[ "$TX_BEFORE_HASH" != absent ]] && cmp -s "$MANAGED_CONF" "$TX_DIR/after.conf" && verify_config_runtime "$MANAGED_CONF"; then
    echo 'Configuration and runtime already match; no config writes or backups.'
    exit 0
  fi
  try_load_bbr || die 'BBR is not available on this kernel'
  snapshot_runtime "$TX_DIR/after.conf" "$TX_DIR/runtime.conf" || die 'cannot snapshot every managed runtime key'
  if [[ "$TX_BEFORE_HASH" != absent ]]; then
    backup_path="$(mktemp "$BACKUP_DIR/config.XXXXXX")" || exit 1
    cp -- "$TX_DIR/before.conf" "$backup_path" || exit 1
  fi
  runtime_path="$(mktemp "$BACKUP_DIR/runtime.XXXXXX")" || exit 1
  cp -- "$TX_DIR/runtime.conf" "$runtime_path" || exit 1
  TX_AFTER_HASH="$(file_hash "$TX_DIR/after.conf")" || exit 1
  printf 'PREVIOUS_EXISTS=%s\nBACKUP_PATH=%s\nAPPLIED_HASH=%s\nRUNTIME_PATH=%s\nBACKUP_HASH=%s\nRUNTIME_HASH=%s\n' \
    "$([[ "$TX_BEFORE_HASH" != absent ]] && echo 1 || echo 0)" "$backup_path" "$TX_AFTER_HASH" "$runtime_path" "$(file_hash "${backup_path:-$TX_DIR/nonexistent}")" "$(file_hash "$runtime_path")" >"$TX_DIR/latest-backup.env" || exit 1
  [[ "$(file_hash "$MANAGED_CONF")" == "$TX_BEFORE_HASH" && "$(source_fingerprint)" == "$TX_SOURCES" ]] || die 'sysctl sources changed before apply'
  snapshot_metadata "$LATEST_BACKUP_FILE" || exit 1
  TX_ARMED=1
  atomic_publish "$TX_DIR/after.conf" "$MANAGED_CONF" || die 'cannot publish managed configuration'
  "$SYSCTL_CMD" --system || exit 1
  verify_config_runtime "$TX_DIR/after.conf" || exit 1
  [[ "$(file_hash "$MANAGED_CONF")" == "$TX_AFTER_HASH" && "$(source_fingerprint)" == "$TX_SOURCES" ]] || die 'sysctl sources changed during apply'
  commit_metadata "$TX_DIR/latest-backup.env" || die 'cannot commit backup metadata'
  TX_ARMED=0
  echo 'Applied and verified all managed sysctl settings.'
)

restore_latest_backup() (
  begin_operation sysctl
  load_backup_metadata
  [[ -n "$PARSED_APPLIED_HASH" && -n "$PARSED_RUNTIME_PATH" ]] || die 'legacy backup lacks ownership/runtime evidence; manual recovery required'
  validate_backup_path "$PARSED_RUNTIME_PATH"
  [[ "$(file_hash "$PARSED_RUNTIME_PATH")" == "$PARSED_RUNTIME_HASH" ]] || die 'runtime backup digest mismatch'
  [[ "$(file_hash "$MANAGED_CONF")" == "$PARSED_APPLIED_HASH" ]] || die 'managed config drift; refusing restore'
  prepare_sysctl_transaction || exit 1
  cp -- "$PARSED_RUNTIME_PATH" "$TX_DIR/after.conf" || exit 1
  check_sysctl_conflicts "$TX_DIR/after.conf" || exit 1
  verify_config_runtime "$MANAGED_CONF" || die 'runtime drift; refusing restore'
  snapshot_runtime "$MANAGED_CONF" "$TX_DIR/runtime.conf" || exit 1
  snapshot_metadata "$LATEST_BACKUP_FILE" || exit 1
  [[ "$(file_hash "$MANAGED_CONF")" == "$TX_BEFORE_HASH" && "$(source_fingerprint)" == "$TX_SOURCES" ]] || die 'sysctl sources changed before restore'
  if [[ "$PARSED_PREVIOUS_EXISTS" == 1 ]]; then
    validate_backup_path "$PARSED_BACKUP_PATH"
    [[ "$(file_hash "$PARSED_BACKUP_PATH")" == "$PARSED_BACKUP_HASH" ]] || die 'config backup digest mismatch'
    cp -- "$PARSED_BACKUP_PATH" "$TX_DIR/restore.conf" || exit 1
    TX_AFTER_HASH="$(file_hash "$TX_DIR/restore.conf")" || exit 1
    TX_ARMED=1
    atomic_publish "$TX_DIR/restore.conf" "$MANAGED_CONF" || exit 1
  else
    TX_AFTER_HASH=absent
    TX_ARMED=1
    rm -- "$MANAGED_CONF" || exit 1
  fi
  "$SYSCTL_CMD" --system || exit 1
  local key value
  while IFS=$'\t' read -r key value; do "$SYSCTL_CMD" -w "$key=$value" || exit 1; done < <(config_entries "$TX_DIR/after.conf")
  verify_config_runtime "$TX_DIR/after.conf" || exit 1
  [[ "$(file_hash "$MANAGED_CONF")" == "$TX_AFTER_HASH" && "$(source_fingerprint)" == "$TX_SOURCES" ]] || exit 1
  TX_META_AFTER_HASH=absent
  rm -- "$LATEST_BACKUP_FILE" || exit 1
  TX_ARMED=0
  echo 'Restored managed file and verified saved runtime settings.'
)

validate_iface_name() {
  [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.:-]{0,14}$ && "$1" != *'..'* ]]
}

validate_positive_mbps() {
  [[ "$1" =~ ^[1-9][0-9]{0,6}$ ]]
}

read_tc_state() {
  local iface="$1" filters parent boot index
  [[ -d "$NET_CLASS_DIR/$iface" && -r "$NET_CLASS_DIR/$iface/ifindex" ]] || return 1
  read -r index <"$NET_CLASS_DIR/$iface/ifindex" || return 1
  read -r boot <"$BOOT_ID_FILE" || return 1
  [[ "$index" =~ ^[1-9][0-9]*$ && "$boot" =~ ^[A-Za-z0-9-]+$ ]] || return 1
  LIVE_ID="$boot:$index"
  LIVE_QDISC="$("$TC_CMD" qdisc show dev "$iface")" || return 1
  # htb direct_packets_stat and qdisc refcnt are runtime counters, not policy.
  LIVE_QDISC="$(printf '%s\n' "$LIVE_QDISC" | sed -E 's/ refcnt [0-9]+//g; s/ direct_packets_stat [0-9]+//g; s/[[:space:]]+$//; s/^[[:space:]]+//' | LC_ALL=C sort)"
  LIVE_CLASS="$("$TC_CMD" class show dev "$iface" | LC_ALL=C sort)" || return 1
  LIVE_FILTERS=''
  for parent in root 'parent 1:' 'parent 1:10'; do
    if [[ "$parent" == root ]]; then filters="$("$TC_CMD" filter show dev "$iface" root)" || return 1;
    else filters="$("$TC_CMD" filter show dev "$iface" parent "${parent#parent }")" || return 1; fi
    LIVE_FILTERS+="$filters"
  done
  LIVE_HASH="$(printf '%s\n%s\n%s\n%s\n' "$LIVE_ID" "$LIVE_QDISC" "$LIVE_CLASS" "$LIVE_FILTERS" | sha256sum | awk '{print $1}')"
}

tc_default_state() {
  [[ -z "$LIVE_CLASS" && -z "$LIVE_FILTERS" && "$LIVE_QDISC" != *$'\n'* && "$LIVE_QDISC" =~ ^qdisc\ [a-zA-Z0-9_]+\ 0:\ root(\ |$) ]]
}

tc_initial_state() {
  tc_default_state && [[ "$LIVE_QDISC" == 'qdisc noqueue 0: root' ]]
}

tc_rate_bits() {
  # iproute2 formats rates as bit/Kbit/Mbit/Gbit, with decimal SI units.
  awk -v v="$1" 'BEGIN {
    if (v !~ /^[0-9]+([.][0-9]+)?(bit|Kbit|Mbit|Gbit|Tbit)$/) exit 1
    n=v+0; if(v ~ /Kbit$/) n*=1000; else if(v ~ /Mbit$/) n*=1000000;
    else if(v ~ /Gbit$/) n*=1000000000; else if(v ~ /Tbit$/) n*=1000000000000;
    printf "%.0f\n",n
  }'
}

tc_expected_shape() {
  local -a tokens=()
  local stage="$1" rate="$2" q count=0 roots=0 leaves=0 token previous='' actual_rate='' actual_ceil=''
  [[ -z "$LIVE_FILTERS" ]] || return 1
  while IFS= read -r q; do
    case "$q" in
      'qdisc htb 1: root '*) [[ "$q" =~ default\ (0x)?10(\ |$) ]] || return 1; roots=$((roots + 1)) ;;
      'qdisc fq 10: parent 1:10 '*) [[ "$stage" == 3 ]] || return 1; leaves=$((leaves + 1)) ;;
      *)
        [[ "$stage" == 2 && "$q" =~ ^qdisc\ pfifo\ [0-9a-f]+:\ parent\ 1:10\ limit\ [0-9]+p$ ]] || return 1
        leaves=$((leaves + 1))
        ;;
    esac
    count=$((count + 1))
  done <<<"$LIVE_QDISC"
  [[ "$roots" == 1 ]] || return 1
  if [[ "$stage" == 3 ]]; then [[ "$count" == 2 && "$leaves" == 1 ]] || return 1;
  elif [[ "$stage" == 2 ]]; then
    # Some kernels omit the automatic handle-zero pfifo leaf from dumps.
    [[ "$count" == 1 || "$count" == 2 ]] || return 1
  else [[ "$count" == 1 ]] || return 1; fi
  if [[ "$stage" == 1 ]]; then [[ -z "$LIVE_CLASS" ]]; return; fi
  [[ "$LIVE_CLASS" == 'class htb 1:10 root '* && "$LIVE_CLASS" != *$'\n'* ]] || return 1
  read -r -a tokens <<<"$LIVE_CLASS"
  for token in "${tokens[@]}"; do
    case "$previous" in rate) actual_rate="$(tc_rate_bits "$token")" || return 1;; ceil) actual_ceil="$(tc_rate_bits "$token")" || return 1;; esac
    previous="$token"
  done
  [[ "$actual_rate" == "$((10#$rate * 1000000))" && "$actual_ceil" == "$actual_rate" ]]
}

load_tc_limit_metadata() {
  local key value line
  local -A seen=()
  PARSED_TC_IFACE= PARSED_TC_RATE_MBPS= PARSED_TC_ID= PARSED_TC_HASH=
  require_safe_path "$TC_LIMIT_FILE"
  [[ -f "$TC_LIMIT_FILE" && -r "$TC_LIMIT_FILE" ]] || die 'no FlareTuner tc limit metadata found'
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || die 'invalid tc metadata line'
    key="${line%%=*}"; value="${line#*=}"
    [[ "$key" =~ ^[A-Z_]+$ ]] || die 'invalid metadata key'
    [[ ! ${seen[$key]+yes} ]] || die "duplicate tc metadata key: $key"
    seen[$key]=1
    case "$key" in
      IFACE) validate_iface_name "$value" || die 'invalid tc interface'; PARSED_TC_IFACE="$value" ;;
      RATE_MBPS) validate_positive_mbps "$value" || die 'invalid tc rate'; PARSED_TC_RATE_MBPS="$value" ;;
      IDENTITY) [[ "$value" =~ ^[A-Za-z0-9-]+:[1-9][0-9]*$ ]] || die 'invalid tc identity'; PARSED_TC_ID="$value" ;;
      FINGERPRINT) [[ "$value" =~ ^[a-f0-9]{64}$ ]] || die 'invalid tc fingerprint'; PARSED_TC_HASH="$value" ;;
      *) die "unknown tc metadata key: $key" ;;
    esac
  done <"$TC_LIMIT_FILE"
  [[ -n "$PARSED_TC_IFACE" && -n "$PARSED_TC_RATE_MBPS" ]] || die 'incomplete tc metadata'
  [[ -n "$PARSED_TC_ID" && -n "$PARSED_TC_HASH" ]] || die 'legacy tc metadata cannot prove ownership; manual inspection required'
}

tc_owned_state() {
  [[ "$LIVE_ID" == "$PARSED_TC_ID" && "$LIVE_HASH" == "$PARSED_TC_HASH" ]] && tc_expected_shape 3 "$PARSED_TC_RATE_MBPS"
}

tc_guard() {
  read_tc_state "$TX_TC_IFACE" && [[ "$LIVE_ID" == "$TX_TC_ID" && "$LIVE_HASH" == "$TX_TC_HASH" ]]
}

capture_tc_step() {
  local stage="$1" rate="$2"
  read_tc_state "$TX_TC_IFACE" || return 1
  [[ "$LIVE_ID" == "$TX_TC_ID" ]] && tc_expected_shape "$stage" "$rate" || return 1
  TX_TC_HASH="$LIVE_HASH"
  printf '%s\n' "$LIVE_QDISC" >"$TX_DIR/current.qdisc" || return 1
  printf '%s\n' "$LIVE_CLASS" >"$TX_DIR/current.class" || return 1
  printf '%s\n' "$TX_TC_HASH" >"$TX_DIR/current.sha256"
}

rollback_tc() {
  tc_guard || return 1
  case "$TX_TC_MODE" in
    create)
      # No successful mutation: nothing to remove.
      [[ "$TX_TC_HASH" != "$TX_TC_BEFORE_HASH" ]] || return 0
      "$TC_CMD" qdisc del dev "$TX_TC_IFACE" root handle 1: || return 1
      read_tc_state "$TX_TC_IFACE" && [[ "$LIVE_HASH" == "$TX_TC_BEFORE_HASH" ]] || return 1
      ;;
    update)
      [[ "$TX_TC_HASH" != "$TX_TC_BEFORE_HASH" ]] || return 0
      "$TC_CMD" class change dev "$TX_TC_IFACE" parent 1: classid 1:10 htb rate "${TX_TC_OLD_RATE}mbit" ceil "${TX_TC_OLD_RATE}mbit" || return 1
      read_tc_state "$TX_TC_IFACE" && [[ "$LIVE_HASH" == "$TX_TC_BEFORE_HASH" ]] || return 1
      ;;
    clear) return 0 ;;
    *) return 1 ;;
  esac
}

apply_tc_egress_limit() (
  local iface="$1" rate="$2"
  validate_iface_name "$iface" || die 'invalid interface name'
  validate_positive_mbps "$rate" || die 'target bandwidth must be an integer from 1 to 9999999 Mbps'
  begin_operation tc
  read_tc_state "$iface" || die 'interface missing or tc state unreadable'
  TX_TC_MODE=create
  TX_TC_OLD_RATE=''
  if [[ -e "$TC_LIMIT_FILE" || -L "$TC_LIMIT_FILE" ]]; then
    load_tc_limit_metadata
    [[ "$iface" == "$PARSED_TC_IFACE" ]] || die 'clear the previously recorded interface before switching targets'
    if tc_owned_state; then
      if [[ "$rate" == "$PARSED_TC_RATE_MBPS" ]]; then echo 'TC limit already matches; no changes.'; exit 0; fi
      TX_TC_MODE=update
      TX_TC_OLD_RATE="$PARSED_TC_RATE_MBPS"
    else die 'tc metadata is stale or live resources drifted; inspect/clear safely first'; fi
  else
    tc_initial_state || die 'foreign tc policy or uncertain root; only an unshaped noqueue root can be claimed'
  fi
  TX_TC_IFACE="$iface" TX_TC_ID="$LIVE_ID" TX_TC_HASH="$LIVE_HASH" TX_TC_BEFORE_HASH="$LIVE_HASH"
  printf '%s\n' "$LIVE_QDISC" >"$TX_DIR/before.qdisc" || exit 1
  printf '%s\n' "$LIVE_CLASS" >"$TX_DIR/before.class" || exit 1
  printf 'IFACE=%s\nIDENTITY=%s\nMODE=%s\nOLD_RATE=%s\nNEW_RATE=%s\n' "$iface" "$LIVE_ID" "$TX_TC_MODE" "$TX_TC_OLD_RATE" "$rate" >"$TX_DIR/tc-recovery.env" || exit 1
  snapshot_metadata "$TC_LIMIT_FILE" || exit 1
  TX_ARMED=1
  tc_guard || die 'tc drift before mutation'
  if [[ "$TX_TC_MODE" == create ]]; then
    "$TC_CMD" qdisc add dev "$iface" root handle 1: htb default 10 || exit 1
    capture_tc_step 1 "$rate" || exit 1
    tc_guard || exit 1
    "$TC_CMD" class add dev "$iface" parent 1: classid 1:10 htb rate "${rate}mbit" ceil "${rate}mbit" || exit 1
    capture_tc_step 2 "$rate" || exit 1
    tc_guard || exit 1
    # Replace only the freshly verified automatic pfifo child of our class.
    "$TC_CMD" qdisc replace dev "$iface" parent 1:10 handle 10: fq || exit 1
  else
    "$TC_CMD" class change dev "$iface" parent 1: classid 1:10 htb rate "${rate}mbit" ceil "${rate}mbit" || exit 1
  fi
  capture_tc_step 3 "$rate" || exit 1
  printf 'IFACE=%s\nRATE_MBPS=%s\nIDENTITY=%s\nFINGERPRINT=%s\n' "$iface" "$rate" "$LIVE_ID" "$LIVE_HASH" >"$TX_DIR/tc-limit.env" || exit 1
  tc_guard || exit 1
  commit_metadata "$TX_DIR/tc-limit.env" || die 'cannot commit tc metadata'
  TX_ARMED=0
  echo "Applied and verified tc egress limit: $iface at $rate Mbps"
)

clear_tc_egress_limit() (
  begin_operation tc
  if [[ ! -e "$TC_LIMIT_FILE" && ! -L "$TC_LIMIT_FILE" ]]; then echo 'TC egress limit: none; nothing to clear.'; exit 0; fi
  load_tc_limit_metadata
  if [[ ! -d "$NET_CLASS_DIR/$PARSED_TC_IFACE" ]]; then
    rm -- "$TC_LIMIT_FILE" || exit 1
    echo 'Removed stale tc metadata; interface is absent.'; exit 0
  fi
  read_tc_state "$PARSED_TC_IFACE" || die 'cannot inspect live tc state'
  if tc_default_state; then
    rm -- "$TC_LIMIT_FILE" || exit 1
    echo 'Removed stale tc metadata; no managed qdisc remains.'; exit 0
  fi
  tc_owned_state || die 'tc ownership conflict/drift; refusing root deletion'
  TX_TC_IFACE="$PARSED_TC_IFACE" TX_TC_ID="$LIVE_ID" TX_TC_HASH="$LIVE_HASH" TX_TC_BEFORE_HASH="$LIVE_HASH" TX_TC_MODE=clear
  cp -- "$TC_LIMIT_FILE" "$TX_DIR/before-metadata.env" || exit 1
  printf '%s\n' "$LIVE_QDISC" >"$TX_DIR/before.qdisc" || exit 1
  printf '%s\n' "$LIVE_CLASS" >"$TX_DIR/before.class" || exit 1
  tc_guard || exit 1
  # Clearing cannot be recreated atomically; retain evidence if interrupted.
  TX_ARMED=1
  "$TC_CMD" qdisc del dev "$TX_TC_IFACE" root handle 1: || exit 1
  read_tc_state "$TX_TC_IFACE" && tc_default_state || exit 1
  rm -- "$TC_LIMIT_FILE" || exit 1
  TX_ARMED=0
  echo "Cleared tc egress limit: $TX_TC_IFACE"
)

show_status() {
  local current_cc available_cc default_qdisc kernel pending
  current_cc="$(sysctl_get net.ipv4.tcp_congestion_control || printf unknown)"
  available_cc="$(sysctl_get net.ipv4.tcp_available_congestion_control || printf unknown)"
  default_qdisc="$(sysctl_get net.core.default_qdisc || printf unknown)"
  kernel="$("$UNAME_CMD" -r 2>/dev/null || printf unknown)"
  echo "$APP_NAME status"
  echo "OS: $(os_pretty_name)"
  echo "Kernel: $kernel"
  echo "Root: $(is_root && printf yes || printf no)"
  echo "Supported OS: $(is_supported_os && printf yes || printf no)"
  echo "BBR available: $(bbr_available && printf yes || printf no)"
  echo "tcp_bbr loaded: $(tcp_bbr_loaded && printf yes || printf no)"
  echo "Current congestion control: $current_cc"
  echo "Available congestion controls: $available_cc"
  echo "Default qdisc: $default_qdisc (system default; not device root state)"
  if [[ -e "$MANAGED_CONF" || -L "$MANAGED_CONF" ]]; then
    echo "Managed config: present ($MANAGED_CONF)"
    if safe_path "$MANAGED_CONF"; then
      if verify_config_runtime "$MANAGED_CONF"; then echo 'Managed runtime: consistent'; else echo 'Managed runtime: drift/unknown'; fi
      check_sysctl_conflicts "$MANAGED_CONF" || echo 'Sysctl conflict: detected/unknown'
    else echo 'Managed config: unsafe ownership/path'; fi
  else
    echo "Managed config: not installed ($MANAGED_CONF)"
    check_sysctl_conflicts <(render_config web 1g-4g under-100m conservative) || echo 'Sysctl conflict: detected/unknown'
  fi
  if [[ -e "$LATEST_BACKUP_FILE" || -L "$LATEST_BACKUP_FILE" ]]; then
    (
      load_backup_metadata
      if [[ -n "$PARSED_APPLIED_HASH" ]]; then
        if [[ "$(file_hash "$MANAGED_CONF")" == "$PARSED_APPLIED_HASH" ]]; then echo 'Managed file ownership: consistent';
        else echo 'Managed file ownership: drift'; fi
      else echo 'Managed file ownership: unverified legacy metadata'; fi
      if [[ "$PARSED_PREVIOUS_EXISTS" == 1 ]]; then echo "Latest backup: $PARSED_BACKUP_PATH";
      else echo 'Latest backup: none (previous state had no managed config)'; fi
    ) || echo 'Latest backup: invalid/unsafe metadata'
  else echo 'Latest backup: none'; fi
  if [[ -e "$TC_LIMIT_FILE" || -L "$TC_LIMIT_FILE" ]]; then
    (
      load_tc_limit_metadata
      echo "TC metadata: $PARSED_TC_IFACE at $PARSED_TC_RATE_MBPS Mbps"
      if read_tc_state "$PARSED_TC_IFACE"; then
        echo "Device qdisc ($PARSED_TC_IFACE): $LIVE_QDISC"
        if tc_owned_state; then echo 'TC egress limit: active and verified';
        elif tc_default_state; then echo 'TC egress limit: stale metadata; no managed qdisc';
        else echo 'TC egress limit: drift/ownership conflict'; fi
      else echo 'TC egress limit: missing interface or unreadable runtime'; fi
    ) || echo 'TC egress limit: invalid/unsafe metadata'
  else echo 'TC egress limit: none'; fi
  for pending in "$STATE_DIR"/transaction.*; do
    [[ ! -e "$pending" && ! -L "$pending" ]] || echo "Unfinished transaction: $pending (manual recovery required)"
  done
  return 0
}

profile_values() {
  local workload="$1"
  local memory="$2"
  local bandwidth="$3"
  local profile="$4"
  local path_profile="${5:-normal}"

  SOMAXCONN=2048
  SYN_BACKLOG=2048
  NETDEV_BACKLOG=5000
  RMEM_MAX=16777216
  WMEM_MAX=16777216
  TCP_RMEM="4096 87380 16777216"
  TCP_WMEM="4096 65536 16777216"

  case "$memory" in
    under-512m)
      RMEM_MAX=4194304
      WMEM_MAX=4194304
      TCP_RMEM="4096 87380 4194304"
      TCP_WMEM="4096 65536 4194304"
      SOMAXCONN=1024
      SYN_BACKLOG=1024
      NETDEV_BACKLOG=1000
      ;;
    512m-1g)
      RMEM_MAX=8388608
      WMEM_MAX=8388608
      TCP_RMEM="4096 87380 8388608"
      TCP_WMEM="4096 65536 8388608"
      SOMAXCONN=2048
      SYN_BACKLOG=2048
      NETDEV_BACKLOG=2500
      ;;
    1g-4g)
      RMEM_MAX=16777216
      WMEM_MAX=16777216
      TCP_RMEM="4096 87380 16777216"
      TCP_WMEM="4096 65536 16777216"
      ;;
    4g-plus)
      RMEM_MAX=33554432
      WMEM_MAX=33554432
      TCP_RMEM="4096 87380 33554432"
      TCP_WMEM="4096 65536 33554432"
      SOMAXCONN=4096
      SYN_BACKLOG=4096
      NETDEV_BACKLOG=10000
      ;;
    *)
      die "unknown memory tier: $memory"
      ;;
  esac

  case "$bandwidth" in
    under-100m)
      ;;
    100m-500m)
      NETDEV_BACKLOG=$(( NETDEV_BACKLOG < 5000 ? 5000 : NETDEV_BACKLOG ))
      ;;
    500m-1g)
      RMEM_MAX=$(( RMEM_MAX < 33554432 ? 33554432 : RMEM_MAX ))
      WMEM_MAX=$(( WMEM_MAX < 33554432 ? 33554432 : WMEM_MAX ))
      TCP_RMEM="4096 87380 $RMEM_MAX"
      TCP_WMEM="4096 65536 $WMEM_MAX"
      NETDEV_BACKLOG=$(( NETDEV_BACKLOG < 10000 ? 10000 : NETDEV_BACKLOG ))
      ;;
    1g-plus)
      RMEM_MAX=$(( RMEM_MAX < 67108864 ? 67108864 : RMEM_MAX ))
      WMEM_MAX=$(( WMEM_MAX < 67108864 ? 67108864 : WMEM_MAX ))
      TCP_RMEM="4096 87380 $RMEM_MAX"
      TCP_WMEM="4096 65536 $WMEM_MAX"
      NETDEV_BACKLOG=$(( NETDEV_BACKLOG < 15000 ? 15000 : NETDEV_BACKLOG ))
      ;;
    *)
      die "unknown bandwidth tier: $bandwidth"
      ;;
  esac

  case "$workload" in
    web)
      SOMAXCONN=$(( SOMAXCONN < 4096 ? 4096 : SOMAXCONN ))
      SYN_BACKLOG=$(( SYN_BACKLOG < 4096 ? 4096 : SYN_BACKLOG ))
      ;;
    proxy)
      NETDEV_BACKLOG=$(( NETDEV_BACKLOG < 10000 ? 10000 : NETDEV_BACKLOG ))
      ;;
    download)
      RMEM_MAX=$(( RMEM_MAX < 33554432 ? 33554432 : RMEM_MAX ))
      WMEM_MAX=$(( WMEM_MAX < 33554432 ? 33554432 : WMEM_MAX ))
      TCP_RMEM="4096 87380 $RMEM_MAX"
      TCP_WMEM="4096 65536 $WMEM_MAX"
      ;;
    low-memory)
      RMEM_MAX=$(( RMEM_MAX > 4194304 ? 4194304 : RMEM_MAX ))
      WMEM_MAX=$(( WMEM_MAX > 4194304 ? 4194304 : WMEM_MAX ))
      TCP_RMEM="4096 87380 $RMEM_MAX"
      TCP_WMEM="4096 65536 $WMEM_MAX"
      SOMAXCONN=$(( SOMAXCONN > 1024 ? 1024 : SOMAXCONN ))
      SYN_BACKLOG=$(( SYN_BACKLOG > 1024 ? 1024 : SYN_BACKLOG ))
      NETDEV_BACKLOG=$(( NETDEV_BACKLOG > 1000 ? 1000 : NETDEV_BACKLOG ))
      ;;
    *)
      die "unknown workload: $workload"
      ;;
  esac

  case "$profile" in
    conservative)
      SOMAXCONN=$(( SOMAXCONN > 4096 ? 4096 : SOMAXCONN ))
      SYN_BACKLOG=$(( SYN_BACKLOG > 4096 ? 4096 : SYN_BACKLOG ))
      NETDEV_BACKLOG=$(( NETDEV_BACKLOG > 10000 ? 10000 : NETDEV_BACKLOG ))
      ;;
    balanced)
      ;;
    aggressive)
      if [[ "$workload" != "low-memory" && "$memory" != "under-512m" ]]; then
        SOMAXCONN=$(( SOMAXCONN < 8192 ? 8192 : SOMAXCONN ))
        SYN_BACKLOG=$(( SYN_BACKLOG < 8192 ? 8192 : SYN_BACKLOG ))
      fi
      ;;
    *)
      die "unknown tuning profile: $profile"
      ;;
  esac

  case "$path_profile" in
    normal)
      ;;
    high-latency)
      if [[ "$workload" != "low-memory" && "$memory" != "under-512m" ]]; then
        RMEM_MAX=$(( RMEM_MAX < 33554432 ? 33554432 : RMEM_MAX ))
        WMEM_MAX=$(( WMEM_MAX < 33554432 ? 33554432 : WMEM_MAX ))
        TCP_RMEM="4096 87380 $RMEM_MAX"
        TCP_WMEM="4096 65536 $WMEM_MAX"
      fi
      ;;
    qos-sensitive)
      RMEM_MAX=$(( RMEM_MAX > 16777216 ? 16777216 : RMEM_MAX ))
      WMEM_MAX=$(( WMEM_MAX > 16777216 ? 16777216 : WMEM_MAX ))
      TCP_RMEM="4096 87380 $RMEM_MAX"
      TCP_WMEM="4096 65536 $WMEM_MAX"
      SOMAXCONN=$(( SOMAXCONN > 4096 ? 4096 : SOMAXCONN ))
      SYN_BACKLOG=$(( SYN_BACKLOG > 4096 ? 4096 : SYN_BACKLOG ))
      NETDEV_BACKLOG=$(( NETDEV_BACKLOG > 5000 ? 5000 : NETDEV_BACKLOG ))
      ;;
    *)
      die "unknown path profile: $path_profile"
      ;;
  esac
}

render_config() {
  local workload="$1"
  local memory="$2"
  local bandwidth="$3"
  local profile="$4"
  local path_profile="${5:-normal}"
  local target_mbps="${6:-auto}"

  profile_values "$workload" "$memory" "$bandwidth" "$profile" "$path_profile"

  cat <<EOF
# Managed by FlareTuner $VERSION
# Restore with: sudo bash scripts/flaretuner.sh, then choose the restore menu.
# Workload: $workload
# Memory tier: $memory
# Bandwidth tier: $bandwidth
# Profile: $profile
# Path profile: $path_profile
# Target bandwidth Mbps: $target_mbps

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = $SOMAXCONN
net.ipv4.tcp_max_syn_backlog = $SYN_BACKLOG
net.core.netdev_max_backlog = $NETDEV_BACKLOG
net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $WMEM_MAX
net.ipv4.tcp_rmem = $TCP_RMEM
net.ipv4.tcp_wmem = $TCP_WMEM
net.ipv4.tcp_slow_start_after_idle = 0
EOF
}

choose_option() {
  local prompt="$1"
  shift
  local options=("$@")
  local choice

  while true; do
    echo "$prompt" >&2
    local index=1
    local option
    for option in "${options[@]}"; do
      echo "  $index) $option" >&2
      index=$((index + 1))
    done
    if ! read_input "Choose [1-${#options[@]}]: " choice; then
      return 1
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      printf '%s\n' "${options[$((choice - 1))]}"
      return 0
    fi
    echo "Invalid choice: $choice" >&2
  done
}

detect_memory_tier() {
  local mem_kb=""

  if [[ -r "$MEMINFO_FILE" ]]; then
    while read -r key value _unit; do
      if [[ "$key" == "MemTotal:" && "$value" =~ ^[0-9]+$ ]]; then
        mem_kb="$value"
        break
      fi
    done <"$MEMINFO_FILE"
  fi

  if [[ -z "$mem_kb" ]]; then
    printf '512m-1g\n'
  elif (( mem_kb < 524288 )); then
    printf 'under-512m\n'
  elif (( mem_kb < 1048576 )); then
    printf '512m-1g\n'
  elif (( mem_kb < 4194304 )); then
    printf '1g-4g\n'
  else
    printf '4g-plus\n'
  fi
}

detect_bandwidth_tier() {
  local iface speed max_speed=0

  if [[ -d "$NET_CLASS_DIR" ]]; then
    for iface in "$NET_CLASS_DIR"/*; do
      [[ -d "$iface" ]] || continue
      [[ "$(basename "$iface")" != "lo" ]] || continue
      [[ -r "$iface/speed" ]] || continue
      read -r speed <"$iface/speed" || speed=""
      [[ "$speed" =~ ^[0-9]+$ ]] || continue
      (( speed > max_speed )) && max_speed="$speed"
    done
  fi

  if (( max_speed >= 1000 )); then
    printf '1g-plus\n'
  elif (( max_speed >= 500 )); then
    printf '500m-1g\n'
  elif (( max_speed >= 100 )); then
    printf '100m-500m\n'
  else
    printf 'under-100m\n'
  fi
}

bandwidth_tier_from_mbps() {
  local mbps="$1"

  [[ "$mbps" =~ ^[0-9]+$ ]] || die "target bandwidth must be a positive integer Mbps value"
  (( mbps > 0 )) || die "target bandwidth must be greater than 0 Mbps"

  if (( mbps >= 1000 )); then
    printf '1g-plus\n'
  elif (( mbps >= 500 )); then
    printf '500m-1g\n'
  elif (( mbps >= 100 )); then
    printf '100m-500m\n'
  else
    printf 'under-100m\n'
  fi
}

recommended_profile_defaults() {
  local memory="${1:-$(detect_memory_tier)}"
  local bandwidth="${2:-$(detect_bandwidth_tier)}"
  local path_profile="${3:-normal}"
  local target_mbps="${4:-}"

  RECOMMENDED_MEMORY="$memory"
  if [[ -n "$target_mbps" ]]; then
    RECOMMENDED_BANDWIDTH="$(bandwidth_tier_from_mbps "$target_mbps")"
  else
    RECOMMENDED_BANDWIDTH="$bandwidth"
  fi
  RECOMMENDED_PATH_PROFILE="$path_profile"
  RECOMMENDED_TARGET_MBPS="${target_mbps:-auto}"

  if [[ "$memory" == "under-512m" ]]; then
    RECOMMENDED_WORKLOAD="low-memory"
    RECOMMENDED_PROFILE="conservative"
  elif [[ "$path_profile" == "qos-sensitive" ]]; then
    RECOMMENDED_WORKLOAD="proxy"
    RECOMMENDED_PROFILE="conservative"
  elif [[ "$path_profile" == "high-latency" ]]; then
    RECOMMENDED_WORKLOAD="proxy"
    RECOMMENDED_PROFILE="balanced"
  elif [[ "$RECOMMENDED_BANDWIDTH" == "1g-plus" && "$memory" != "512m-1g" ]]; then
    RECOMMENDED_WORKLOAD="download"
    RECOMMENDED_PROFILE="balanced"
  else
    RECOMMENDED_WORKLOAD="web"
    RECOMMENDED_PROFILE="conservative"
  fi
}

choose_option_with_default() {
  local prompt="$1"
  local default="$2"
  shift 2
  local options=("$@")
  local choice

  while true; do
    echo "$prompt (recommended: $default)" >&2
    local index=1
    local option marker
    for option in "${options[@]}"; do
      marker=""
      [[ "$option" == "$default" ]] && marker=" [recommended]"
      echo "  $index) $option$marker" >&2
      index=$((index + 1))
    done
    if ! read_input "Choose [1-${#options[@]}] or press Enter for $default: " choice; then
      return 1
    fi
    if [[ -z "$choice" ]]; then
      printf '%s\n' "$default"
      return 0
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      printf '%s\n' "${options[$((choice - 1))]}"
      return 0
    fi
    echo "Invalid choice: $choice" >&2
  done
}

read_optional_target_mbps() {
  local default="${1:-auto}"
  local value=""

  while true; do
    if ! read_input "Target bandwidth Mbps [Enter for $default]: " value; then
      return 1
    fi
    if [[ -z "$value" ]]; then
      printf '%s\n' "$default"
      return 0
    fi
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 )); then
      printf '%s\n' "$value"
      return 0
    fi
    echo "Invalid target bandwidth: $value" >&2
  done
}

select_profile_inputs() {
  local detected_memory detected_bandwidth target_mbps path_profile recommendation_target_mbps=""

  detected_memory="$(detect_memory_tier)"
  detected_bandwidth="$(detect_bandwidth_tier)"
  target_mbps="$(read_optional_target_mbps auto)" || return 1
  path_profile="$(choose_option_with_default "Path profile" normal normal high-latency qos-sensitive)" || return 1
  if [[ "$target_mbps" != "auto" ]]; then
    recommendation_target_mbps="$target_mbps"
  fi
  recommended_profile_defaults "$detected_memory" "$detected_bandwidth" "$path_profile" "$recommendation_target_mbps"

  SELECTED_WORKLOAD="$(choose_option_with_default "Workload" "$RECOMMENDED_WORKLOAD" web proxy download low-memory)" || return 1
  SELECTED_MEMORY="$(choose_option_with_default "Memory tier" "$RECOMMENDED_MEMORY" under-512m 512m-1g 1g-4g 4g-plus)" || return 1
  SELECTED_BANDWIDTH="$(choose_option_with_default "Bandwidth tier" "$RECOMMENDED_BANDWIDTH" under-100m 100m-500m 500m-1g 1g-plus)" || return 1
  SELECTED_PROFILE="$(choose_option_with_default "Tuning profile" "$RECOMMENDED_PROFILE" conservative balanced aggressive)" || return 1
  SELECTED_PATH_PROFILE="$path_profile"
  SELECTED_TARGET_MBPS="$target_mbps"
}

explain_config() {
  local workload="$1"
  local memory="$2"
  local bandwidth="$3"
  local profile="$4"

  echo "Profile summary"
  echo "Workload: $workload"
  echo "Memory tier: $memory"
  echo "Bandwidth tier: $bandwidth"
  echo "Tuning profile: $profile"
  echo "Path profile: ${SELECTED_PATH_PROFILE:-normal}"
  echo "Target bandwidth Mbps: ${SELECTED_TARGET_MBPS:-auto}"
  echo "This profile enables fq + BBR and tunes queue, backlog, and TCP buffer limits."
}

run_generate_flow() {
  local mode="${1:-preview}"
  local config confirmation

  require_supported_os

  case "$mode" in
    apply)
      require_root
      ;;
    preview)
      echo "BBR available: $(bbr_available && printf 'yes' || printf 'no')"
      ;;
    *)
      die "unknown generate mode: $mode"
      ;;
  esac

  select_profile_inputs || return 1
  SELECTED_PATH_PROFILE="${SELECTED_PATH_PROFILE:-normal}"
  SELECTED_TARGET_MBPS="${SELECTED_TARGET_MBPS:-auto}"
  config="$(render_config "$SELECTED_WORKLOAD" "$SELECTED_MEMORY" "$SELECTED_BANDWIDTH" "$SELECTED_PROFILE" "$SELECTED_PATH_PROFILE" "$SELECTED_TARGET_MBPS")"
  show_status
  echo
  printf '%s\n' "$config"
  echo
  explain_config "$SELECTED_WORKLOAD" "$SELECTED_MEMORY" "$SELECTED_BANDWIDTH" "$SELECTED_PROFILE"

  case "$mode" in
    apply)
      echo
      if ! read_input "Type yes to apply this configuration: " confirmation; then
        return 1
      fi
      if [[ "$confirmation" != "yes" ]]; then
        echo "Apply cancelled."
        return 1
      fi
      apply_config "$config"
      ;;
    preview)
      ;;
  esac
}

run_apply_tc_limit_flow() {
  local default_rate="${SELECTED_TARGET_MBPS:-90}"
  local iface rate confirmation

  require_root
  read_input "Interface to limit, for example eth0: " iface || return 1
  validate_iface_name "$iface" || die "invalid interface name: $iface"
  rate="$(read_optional_target_mbps "$default_rate")" || return 1
  [[ "$rate" != "auto" ]] || die "tc egress limit requires a numeric Mbps value"
  validate_positive_mbps "$rate" || die "target bandwidth must be a positive integer Mbps value"

  echo "This will apply a verified FlareTuner egress limit on $iface at $rate Mbps; foreign policy is refused."
  read_input "Type yes to apply this tc limit: " confirmation || return 1
  if [[ "$confirmation" != "yes" ]]; then
    echo "tc limit cancelled."
    return 1
  fi

  apply_tc_egress_limit "$iface" "$rate"
}

main() {
  local operation_status=0
  echo "$APP_NAME $VERSION"

  while true; do
    echo
    echo "1) Generate and apply tuning"
    echo "2) Preview tuning only"
    echo "3) Restore last FlareTuner backup"
    echo "4) Show current network tuning status"
    echo "5) Apply tc egress bandwidth limit"
    echo "6) Clear FlareTuner tc egress limit"
    echo "7) Exit"

    local choice
    if ! read_input "Choose [1-7]: " choice; then
      return "$operation_status"
    fi
    case "$choice" in
      1)
        if ! run_generate_flow apply; then
          echo "Operation failed or cancelled."
          operation_status=1
        fi
        ;;
      2)
        if ! run_generate_flow preview; then
          echo "Operation failed or cancelled."
          operation_status=1
        fi
        ;;
      3)
        if ! restore_latest_backup; then operation_status=1; fi
        ;;
      4)
        show_status
        ;;
      5)
        if ! run_apply_tc_limit_flow; then
          echo "Operation failed or cancelled."
          operation_status=1
        fi
        ;;
      6)
        if ! clear_tc_egress_limit; then operation_status=1; fi
        ;;
      7)
        return "$operation_status"
        ;;
      *)
        echo "Invalid choice: $choice" >&2
        ;;
    esac
  done
}

if [[ "${FLARETUNER_TESTING:-0}" != "1" ]]; then
  main "$@"
fi
