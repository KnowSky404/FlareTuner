#!/usr/bin/env bash
set -euo pipefail

APP_NAME="FlareTuner"
VERSION="0.1.0"

MANAGED_CONF="${FLARETUNER_MANAGED_CONF:-${FLARETUNER_ETC_DIR:-/etc}/sysctl.d/99-flaretuner.conf}"
STATE_DIR="${FLARETUNER_STATE_DIR:-/var/lib/flaretuner}"
BACKUP_DIR="$STATE_DIR/backup"
LATEST_BACKUP_FILE="$STATE_DIR/latest-backup.env"
OS_RELEASE_FILE="${FLARETUNER_OS_RELEASE:-/etc/os-release}"
SYSCTL_CMD="${FLARETUNER_SYSCTL_CMD:-sysctl}"
MODPROBE_CMD="${FLARETUNER_MODPROBE_CMD:-modprobe}"
LSMOD_CMD="${FLARETUNER_LSMOD_CMD:-lsmod}"
UNAME_CMD="${FLARETUNER_UNAME_CMD:-uname}"
ID_CMD="${FLARETUNER_ID_CMD:-id}"

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
  local value

  if ! IFS= read -r -p "$prompt" value; then
    echo "Input ended; aborting." >&2
    return 1
  fi

  printf -v "$target_var" '%s' "$value"
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

try_load_bbr() {
  bbr_available && return 0
  is_root || return 1

  if "$MODPROBE_CMD" tcp_bbr 2>/dev/null; then
    bbr_available && return 0
  fi

  return 1
}

timestamp() {
  date +%Y%m%d%H%M%S
}

write_latest_backup_metadata() {
  local previous_exists="$1"
  local backup_path="$2"

  mkdir -p "$STATE_DIR"
  {
    printf 'PREVIOUS_EXISTS=%s\n' "$previous_exists"
    printf 'BACKUP_PATH=%s\n' "$backup_path"
  } >"$LATEST_BACKUP_FILE"
}

metadata_path_is_safe() {
  local path="$1"

  [[ "$path" != *".."* ]] || return 1
  [[ "$path" =~ ^[A-Za-z0-9._/:-]*$ ]]
}

load_backup_metadata() {
  local line key value
  local seen_previous_exists=0
  local seen_backup_path=0

  PARSED_PREVIOUS_EXISTS=""
  PARSED_BACKUP_PATH=""
  [[ -r "$LATEST_BACKUP_FILE" ]] || die "no FlareTuner backup metadata found at $LATEST_BACKUP_FILE"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || die "invalid backup metadata line: $line"
    key="${line%%=*}"
    value="${line#*=}"

    case "$key" in
      PREVIOUS_EXISTS)
        [[ "$seen_previous_exists" == "0" ]] || die "duplicate backup metadata key: PREVIOUS_EXISTS"
        [[ "$value" == "0" || "$value" == "1" ]] || die "invalid backup metadata: PREVIOUS_EXISTS=$value"
        PARSED_PREVIOUS_EXISTS="$value"
        seen_previous_exists=1
        ;;
      BACKUP_PATH)
        [[ "$seen_backup_path" == "0" ]] || die "duplicate backup metadata key: BACKUP_PATH"
        metadata_path_is_safe "$value" || die "unsafe backup metadata path"
        PARSED_BACKUP_PATH="$value"
        seen_backup_path=1
        ;;
      *)
        die "unknown backup metadata key: $key"
        ;;
    esac
  done <"$LATEST_BACKUP_FILE"

  [[ "$seen_previous_exists" == "1" ]] || die "backup metadata is missing PREVIOUS_EXISTS"
  [[ "$seen_backup_path" == "1" ]] || die "backup metadata is missing BACKUP_PATH"
}

validate_backup_path() {
  local backup_path="$1"

  [[ -n "$backup_path" ]] || die "backup metadata is missing BACKUP_PATH"
  metadata_path_is_safe "$backup_path" || die "unsafe backup metadata path"
  case "$backup_path" in
    "$BACKUP_DIR"/*)
      ;;
    *)
      die "backup path is outside FlareTuner backup dir: $backup_path"
      ;;
  esac
  [[ ! -L "$backup_path" ]] || die "backup file must not be a symlink: $backup_path"
  [[ -f "$backup_path" && -r "$backup_path" ]] || die "backup file not found: $backup_path"
}

backup_managed_config() {
  local backup_path=""

  mkdir -p "$BACKUP_DIR"
  if [[ -e "$MANAGED_CONF" ]]; then
    backup_path="$BACKUP_DIR/99-flaretuner.conf.$(timestamp).bak"
    cp "$MANAGED_CONF" "$backup_path"
    write_latest_backup_metadata 1 "$backup_path"
  else
    write_latest_backup_metadata 0 ""
  fi
}

restore_managed_config_from_metadata() {
  load_backup_metadata

  case "$PARSED_PREVIOUS_EXISTS" in
    1)
      validate_backup_path "$PARSED_BACKUP_PATH"
      mkdir -p "$(dirname "$MANAGED_CONF")"
      cp "$PARSED_BACKUP_PATH" "$MANAGED_CONF"
      ;;
    0)
      [[ -z "$PARSED_BACKUP_PATH" ]] || die "backup metadata has BACKUP_PATH but PREVIOUS_EXISTS=0"
      rm -f "$MANAGED_CONF"
      ;;
    *)
      die "invalid backup metadata: PREVIOUS_EXISTS=$PARSED_PREVIOUS_EXISTS"
      ;;
  esac
}

verify_active_settings() {
  local active_cc active_qdisc

  active_cc="$(sysctl_get net.ipv4.tcp_congestion_control || true)"
  active_qdisc="$(sysctl_get net.core.default_qdisc || true)"

  if [[ "$active_cc" != "bbr" ]]; then
    echo "Error: active congestion control is '$active_cc', expected 'bbr'" >&2
    return 1
  fi
  if [[ "$active_qdisc" != "fq" ]]; then
    echo "Error: active default qdisc is '$active_qdisc', expected 'fq'" >&2
    return 1
  fi
}

apply_config() {
  local config="$1"
  local apply_status=0

  require_root
  require_supported_os
  if ! try_load_bbr; then
    die "BBR is not available on this kernel"
  fi

  backup_managed_config
  mkdir -p "$(dirname "$MANAGED_CONF")"
  printf '%s\n' "$config" >"$MANAGED_CONF"
  if ! "$SYSCTL_CMD" --system; then
    apply_status=1
  elif ! verify_active_settings; then
    apply_status=1
  fi

  if [[ "$apply_status" != "0" ]]; then
    echo "FlareTuner apply failed; restoring previous managed config." >&2
    restore_managed_config_from_metadata
    "$SYSCTL_CMD" --system || true
    return 1
  fi

  show_status
}

show_status() {
  local current_cc available_cc default_qdisc kernel

  current_cc="$(sysctl_get net.ipv4.tcp_congestion_control || printf 'unknown')"
  available_cc="$(sysctl_get net.ipv4.tcp_available_congestion_control || printf 'unknown')"
  default_qdisc="$(sysctl_get net.core.default_qdisc || printf 'unknown')"
  kernel="$("$UNAME_CMD" -r 2>/dev/null || printf 'unknown')"

  echo "$APP_NAME status"
  echo "OS: $(os_pretty_name)"
  echo "Kernel: $kernel"
  echo "Root: $(is_root && printf 'yes' || printf 'no')"
  echo "Supported OS: $(is_supported_os && printf 'yes' || printf 'no')"
  echo "BBR available: $(bbr_available && printf 'yes' || printf 'no')"
  echo "Current congestion control: $current_cc"
  echo "Available congestion controls: $available_cc"
  echo "Default qdisc: $default_qdisc"
  echo "Managed config: $MANAGED_CONF"
  echo "Latest backup: $LATEST_BACKUP_FILE"
}

profile_values() {
  local workload="$1"
  local memory="$2"
  local bandwidth="$3"
  local profile="$4"

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
}

render_config() {
  local workload="$1"
  local memory="$2"
  local bandwidth="$3"
  local profile="$4"

  profile_values "$workload" "$memory" "$bandwidth" "$profile"

  cat <<EOF
# Managed by FlareTuner $VERSION
# Workload: $workload
# Memory tier: $memory
# Bandwidth tier: $bandwidth
# Profile: $profile

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

select_profile_inputs() {
  SELECTED_WORKLOAD="$(choose_option "Workload" web proxy download low-memory)" || return 1
  SELECTED_MEMORY="$(choose_option "Memory tier" under-512m 512m-1g 1g-4g 4g-plus)" || return 1
  SELECTED_BANDWIDTH="$(choose_option "Bandwidth tier" under-100m 100m-500m 500m-1g 1g-plus)" || return 1
  SELECTED_PROFILE="$(choose_option "Tuning profile" conservative balanced aggressive)" || return 1
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
  config="$(render_config "$SELECTED_WORKLOAD" "$SELECTED_MEMORY" "$SELECTED_BANDWIDTH" "$SELECTED_PROFILE")"
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

restore_latest_backup() {
  require_root

  restore_managed_config_from_metadata
  "$SYSCTL_CMD" --system
  show_status
}

main() {
  echo "$APP_NAME $VERSION"

  while true; do
    echo
    echo "1) Generate and apply tuning"
    echo "2) Preview tuning only"
    echo "3) Restore last FlareTuner backup"
    echo "4) Show current network tuning status"
    echo "5) Exit"

    local choice
    if ! read_input "Choose [1-5]: " choice; then
      return 0
    fi
    case "$choice" in
      1)
        if ! run_generate_flow apply; then
          echo "Operation cancelled."
        fi
        ;;
      2)
        if ! run_generate_flow preview; then
          echo "Operation cancelled."
        fi
        ;;
      3)
        restore_latest_backup
        ;;
      4)
        show_status
        ;;
      5)
        return 0
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
