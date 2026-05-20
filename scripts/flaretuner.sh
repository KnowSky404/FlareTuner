#!/usr/bin/env bash
set -euo pipefail

APP_NAME="FlareTuner"
VERSION="0.1.0"

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
  local canonical_backup_dir canonical_backup_path

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

  canonical_backup_dir="$(readlink -f "$BACKUP_DIR")" || die "cannot canonicalize backup dir: $BACKUP_DIR"
  canonical_backup_path="$(readlink -f "$backup_path")" || die "cannot canonicalize backup path: $backup_path"
  case "$canonical_backup_path" in
    "$canonical_backup_dir"/*)
      ;;
    *)
      die "backup path escapes FlareTuner backup dir: $backup_path"
      ;;
  esac
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
  echo "tcp_bbr loaded: $(tcp_bbr_loaded && printf 'yes' || printf 'no')"
  echo "Current congestion control: $current_cc"
  echo "Available congestion controls: $available_cc"
  echo "Default qdisc: $default_qdisc"
  if [[ -f "$MANAGED_CONF" ]]; then
    echo "Managed config: present ($MANAGED_CONF)"
  else
    echo "Managed config: not installed ($MANAGED_CONF)"
  fi
  if [[ -f "$LATEST_BACKUP_FILE" ]]; then
    load_backup_metadata
    if [[ "$PARSED_PREVIOUS_EXISTS" == "1" ]]; then
      echo "Latest backup: $PARSED_BACKUP_PATH"
    else
      echo "Latest backup: none (previous state had no managed config)"
    fi
  else
    echo "Latest backup: none"
  fi
  if [[ -f "$TC_LIMIT_FILE" ]]; then
    load_tc_limit_metadata
    echo "TC egress limit: ${PARSED_TC_IFACE} at ${PARSED_TC_RATE_MBPS} Mbps"
  else
    echo "TC egress limit: none"
  fi
}

validate_iface_name() {
  local iface="$1"

  [[ "$iface" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 1
  [[ "$iface" != *".."* ]] || return 1
  [[ "$iface" != "." && "$iface" != "-" && "$iface" != ":" ]]
}

validate_positive_mbps() {
  local mbps="$1"

  [[ "$mbps" =~ ^[0-9]+$ ]] || return 1
  (( mbps > 0 ))
}

write_tc_limit_metadata() {
  local iface="$1"
  local rate_mbps="$2"

  mkdir -p "$STATE_DIR"
  {
    printf 'IFACE=%s\n' "$iface"
    printf 'RATE_MBPS=%s\n' "$rate_mbps"
  } >"$TC_LIMIT_FILE"
}

load_tc_limit_metadata() {
  local line key value
  local seen_iface=0
  local seen_rate=0

  PARSED_TC_IFACE=""
  PARSED_TC_RATE_MBPS=""
  [[ -r "$TC_LIMIT_FILE" ]] || die "no FlareTuner tc limit metadata found at $TC_LIMIT_FILE"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || die "invalid tc metadata line: $line"
    key="${line%%=*}"
    value="${line#*=}"

    case "$key" in
      IFACE)
        [[ "$seen_iface" == "0" ]] || die "duplicate tc metadata key: IFACE"
        validate_iface_name "$value" || die "invalid tc metadata interface: $value"
        PARSED_TC_IFACE="$value"
        seen_iface=1
        ;;
      RATE_MBPS)
        [[ "$seen_rate" == "0" ]] || die "duplicate tc metadata key: RATE_MBPS"
        validate_positive_mbps "$value" || die "invalid tc metadata rate: $value"
        PARSED_TC_RATE_MBPS="$value"
        seen_rate=1
        ;;
      *)
        die "unknown tc metadata key: $key"
        ;;
    esac
  done <"$TC_LIMIT_FILE"

  [[ "$seen_iface" == "1" ]] || die "tc metadata is missing IFACE"
  [[ "$seen_rate" == "1" ]] || die "tc metadata is missing RATE_MBPS"
}

apply_tc_egress_limit() {
  local iface="$1"
  local rate_mbps="$2"

  require_root
  validate_iface_name "$iface" || die "invalid interface name: $iface"
  validate_positive_mbps "$rate_mbps" || die "target bandwidth must be a positive integer Mbps value"

  "$TC_CMD" qdisc replace dev "$iface" root handle 1: htb default 10
  "$TC_CMD" class replace dev "$iface" parent 1: classid 1:10 htb rate "${rate_mbps}mbit" ceil "${rate_mbps}mbit"
  "$TC_CMD" qdisc replace dev "$iface" parent 1:10 handle 10: fq
  write_tc_limit_metadata "$iface" "$rate_mbps"
  echo "Applied tc egress limit: $iface at $rate_mbps Mbps"
}

clear_tc_egress_limit() {
  require_root
  load_tc_limit_metadata

  "$TC_CMD" qdisc del dev "$PARSED_TC_IFACE" root
  rm -f "$TC_LIMIT_FILE"
  echo "Cleared tc egress limit: $PARSED_TC_IFACE"
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

restore_latest_backup() {
  require_root

  restore_managed_config_from_metadata
  "$SYSCTL_CMD" --system
  show_status
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

  echo "This will replace the root qdisc on $iface with a FlareTuner-managed egress limit at $rate Mbps."
  read_input "Type yes to apply this tc limit: " confirmation || return 1
  if [[ "$confirmation" != "yes" ]]; then
    echo "tc limit cancelled."
    return 1
  fi

  apply_tc_egress_limit "$iface" "$rate"
}

main() {
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
        if ! run_apply_tc_limit_flow; then
          echo "Operation cancelled."
        fi
        ;;
      6)
        clear_tc_egress_limit
        ;;
      7)
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
