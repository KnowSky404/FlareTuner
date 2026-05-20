#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/flaretuner.sh"

pass_count=0
TEST_TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TEST_TMP_DIR"
  unset FLARETUNER_TESTING FLARETUNER_OS_RELEASE FLARETUNER_SYSCTL_CMD FLARETUNER_MODPROBE_CMD FLARETUNER_LSMOD_CMD FLARETUNER_ID_CMD FLARETUNER_TC_CMD
  unset FLARETUNER_ETC_DIR FLARETUNER_STATE_DIR FLARETUNER_MEMINFO FLARETUNER_NET_CLASS_DIR
  unset SELECTED_WORKLOAD SELECTED_MEMORY SELECTED_BANDWIDTH SELECTED_PROFILE SELECTED_PATH_PROFILE SELECTED_TARGET_MBPS
  unset RECOMMENDED_WORKLOAD RECOMMENDED_MEMORY RECOMMENDED_BANDWIDTH RECOMMENDED_PROFILE RECOMMENDED_PATH_PROFILE RECOMMENDED_TARGET_MBPS
  unset -f sysctl modprobe lsmod id tc select_profile_inputs 2>/dev/null || true
}

reset_test_env() {
  unset FLARETUNER_TESTING FLARETUNER_OS_RELEASE FLARETUNER_SYSCTL_CMD FLARETUNER_MODPROBE_CMD FLARETUNER_LSMOD_CMD FLARETUNER_ID_CMD FLARETUNER_TC_CMD
  unset FLARETUNER_ETC_DIR FLARETUNER_STATE_DIR FLARETUNER_MEMINFO FLARETUNER_NET_CLASS_DIR
  unset SELECTED_WORKLOAD SELECTED_MEMORY SELECTED_BANDWIDTH SELECTED_PROFILE SELECTED_PATH_PROFILE SELECTED_TARGET_MBPS
  unset RECOMMENDED_WORKLOAD RECOMMENDED_MEMORY RECOMMENDED_BANDWIDTH RECOMMENDED_PROFILE RECOMMENDED_PATH_PROFILE RECOMMENDED_TARGET_MBPS
  unset -f sysctl modprobe lsmod id tc select_profile_inputs 2>/dev/null || true
}

trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "$label: expected to find '$needle'"
  fi
}

assert_equals() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "$actual" != "$expected" ]]; then
    fail "$label: expected '$expected', got '$actual'"
  fi
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  local content
  content="$(<"$file")"
  assert_contains "$content" "$needle" "$label"
}

run_test() {
  local name="$1"
  shift
  reset_test_env
  "$@"
  reset_test_env
  pass_count=$((pass_count + 1))
  echo "ok $pass_count - $name"
}

test_render_low_memory_config() {
  FLARETUNER_TESTING=1 source "$SCRIPT"
  local config
  config="$(render_config "low-memory" "under-512m" "under-100m" "conservative")"
  assert_contains "$config" "# Managed by FlareTuner" "managed header"
  assert_contains "$config" "# Restore with: sudo bash scripts/flaretuner.sh" "restore header"
  assert_contains "$config" "net.core.default_qdisc = fq" "baseline qdisc"
  assert_contains "$config" "net.ipv4.tcp_congestion_control = bbr" "baseline bbr"
  assert_contains "$config" "net.core.rmem_max = 4194304" "low memory rmem"
  assert_contains "$config" "net.core.wmem_max = 4194304" "low memory wmem"
  assert_contains "$config" "net.ipv4.tcp_slow_start_after_idle = 0" "slow start setting"
}

test_render_high_throughput_config() {
  FLARETUNER_TESTING=1 source "$SCRIPT"
  local config
  config="$(render_config "download" "4g-plus" "1g-plus" "aggressive")"
  assert_contains "$config" "net.core.somaxconn = 8192" "high throughput somaxconn"
  assert_contains "$config" "net.ipv4.tcp_max_syn_backlog = 8192" "high throughput syn backlog"
  assert_contains "$config" "net.core.rmem_max = 67108864" "high throughput rmem"
  assert_contains "$config" "net.core.wmem_max = 67108864" "high throughput wmem"
}

test_render_qos_sensitive_proxy_config_caps_buffers() {
  FLARETUNER_TESTING=1 source "$SCRIPT"
  local config
  config="$(render_config "proxy" "4g-plus" "1g-plus" "balanced" "qos-sensitive" "90")"
  assert_contains "$config" "# Path profile: qos-sensitive" "qos path header"
  assert_contains "$config" "# Target bandwidth Mbps: 90" "target bandwidth header"
  assert_contains "$config" "net.core.netdev_max_backlog = 5000" "qos-sensitive netdev cap"
  assert_contains "$config" "net.core.rmem_max = 16777216" "qos-sensitive rmem cap"
  assert_contains "$config" "net.core.wmem_max = 16777216" "qos-sensitive wmem cap"
}

test_supported_debian_detection() {
  local os_release
  os_release="$TEST_TMP_DIR/debian-os-release"
  cat >"$os_release" <<'EOF'
ID=debian
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
EOF

  FLARETUNER_TESTING=1 FLARETUNER_OS_RELEASE="$os_release" source "$SCRIPT"

  assert_equals "$(os_id)" "debian" "debian os id"
  if ! is_supported_os; then
    fail "debian should be supported"
  fi
}

test_unsupported_alpine_detection() {
  local os_release
  os_release="$TEST_TMP_DIR/alpine-os-release"
  cat >"$os_release" <<'EOF'
ID=alpine
PRETTY_NAME="Alpine Linux"
EOF

  FLARETUNER_TESTING=1 FLARETUNER_OS_RELEASE="$os_release" source "$SCRIPT"

  assert_equals "$(os_id)" "alpine" "alpine os id"
  if is_supported_os; then
    fail "alpine should not be supported"
  fi
}

test_bbr_available_from_sysctl_output() {
  sysctl() {
    if [[ "$1" == "-n" && "$2" == "net.ipv4.tcp_available_congestion_control" ]]; then
      echo "reno cubic bbr"
      return 0
    fi
    return 1
  }

  FLARETUNER_TESTING=1 FLARETUNER_SYSCTL_CMD=sysctl source "$SCRIPT"

  if ! bbr_available; then
    fail "bbr should be available"
  fi
}

test_choose_option_handles_eof() {
  FLARETUNER_TESTING=1 source "$SCRIPT"

  local output status
  set +e
  output="$(choose_option Test one two </dev/null 2>&1)"
  status=$?
  set -e

  assert_equals "$status" "1" "choose_option EOF status"
  assert_contains "$output" "Input ended; aborting." "choose_option EOF message"
}

test_detect_memory_tier_from_meminfo() {
  local meminfo
  meminfo="$TEST_TMP_DIR/meminfo"
  printf 'MemTotal:        786432 kB\n' >"$meminfo"

  FLARETUNER_TESTING=1 FLARETUNER_MEMINFO="$meminfo" source "$SCRIPT"

  assert_equals "$(detect_memory_tier)" "512m-1g" "detected memory tier"
}

test_detect_bandwidth_tier_from_sysfs_speed() {
  local net_dir
  net_dir="$TEST_TMP_DIR/net"
  mkdir -p "$net_dir/lo" "$net_dir/eth0" "$net_dir/eth1"
  printf '1000\n' >"$net_dir/eth0/speed"
  printf '100\n' >"$net_dir/eth1/speed"

  FLARETUNER_TESTING=1 FLARETUNER_NET_CLASS_DIR="$net_dir" source "$SCRIPT"

  assert_equals "$(detect_bandwidth_tier)" "1g-plus" "detected bandwidth tier"
}

test_recommended_profile_defaults_for_low_memory() {
  FLARETUNER_TESTING=1 source "$SCRIPT"

  recommended_profile_defaults under-512m 1g-plus normal ""

  assert_equals "$RECOMMENDED_WORKLOAD" "low-memory" "low-memory workload recommendation"
  assert_equals "$RECOMMENDED_MEMORY" "under-512m" "low-memory memory recommendation"
  assert_equals "$RECOMMENDED_BANDWIDTH" "1g-plus" "low-memory bandwidth recommendation"
  assert_equals "$RECOMMENDED_PROFILE" "conservative" "low-memory profile recommendation"
}

test_bandwidth_tier_from_target_mbps() {
  FLARETUNER_TESTING=1 source "$SCRIPT"

  assert_equals "$(bandwidth_tier_from_mbps 90)" "under-100m" "90 Mbps tier"
  assert_equals "$(bandwidth_tier_from_mbps 100)" "100m-500m" "100 Mbps tier"
  assert_equals "$(bandwidth_tier_from_mbps 500)" "500m-1g" "500 Mbps tier"
  assert_equals "$(bandwidth_tier_from_mbps 1000)" "1g-plus" "1000 Mbps tier"
}

test_recommended_profile_defaults_for_qos_sensitive_target() {
  FLARETUNER_TESTING=1 source "$SCRIPT"

  recommended_profile_defaults 1g-4g 500m-1g qos-sensitive 90

  assert_equals "$RECOMMENDED_WORKLOAD" "proxy" "qos-sensitive workload recommendation"
  assert_equals "$RECOMMENDED_BANDWIDTH" "under-100m" "qos-sensitive target bandwidth recommendation"
  assert_equals "$RECOMMENDED_PROFILE" "conservative" "qos-sensitive profile recommendation"
  assert_equals "$RECOMMENDED_PATH_PROFILE" "qos-sensitive" "qos-sensitive path recommendation"
  assert_equals "$RECOMMENDED_TARGET_MBPS" "90" "qos-sensitive target mbps recommendation"
}

test_choose_option_with_default_accepts_blank_default() {
  FLARETUNER_TESTING=1 source "$SCRIPT"

  local selected
  selected="$(printf '\n' | choose_option_with_default "Workload" proxy web proxy download low-memory)"

  assert_equals "$selected" "proxy" "blank choice should accept default"
}

test_choose_option_with_default_allows_manual_override() {
  FLARETUNER_TESTING=1 source "$SCRIPT"

  local selected
  selected="$(printf '3\n' | choose_option_with_default "Workload" proxy web proxy download low-memory)"

  assert_equals "$selected" "download" "numeric choice should override default"
}

test_select_profile_inputs_uses_detected_defaults() {
  local meminfo net_dir
  meminfo="$TEST_TMP_DIR/select-meminfo"
  net_dir="$TEST_TMP_DIR/select-net"
  printf 'MemTotal:        262144 kB\n' >"$meminfo"
  mkdir -p "$net_dir/eth0"
  printf '1000\n' >"$net_dir/eth0/speed"

  FLARETUNER_TESTING=1 \
    FLARETUNER_MEMINFO="$meminfo" \
    FLARETUNER_NET_CLASS_DIR="$net_dir" \
    source "$SCRIPT"

  select_profile_inputs <<< $'90\n\n\n\n\n\n'

  assert_equals "$SELECTED_WORKLOAD" "low-memory" "selected default workload"
  assert_equals "$SELECTED_MEMORY" "under-512m" "selected default memory"
  assert_equals "$SELECTED_BANDWIDTH" "under-100m" "selected target bandwidth"
  assert_equals "$SELECTED_PROFILE" "conservative" "selected default profile"
  assert_equals "$SELECTED_PATH_PROFILE" "normal" "selected default path profile"
  assert_equals "$SELECTED_TARGET_MBPS" "90" "selected custom target mbps"
}

test_preview_does_not_load_bbr() {
  local os_release
  os_release="$TEST_TMP_DIR/preview-os-release"
  cat >"$os_release" <<'EOF'
ID=debian
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
EOF

  sysctl() {
    if [[ "$1" == "-n" && "$2" == "net.ipv4.tcp_available_congestion_control" ]]; then
      echo "reno cubic"
      return 0
    fi
    return 1
  }

  modprobe() {
    fail "preview should not call modprobe"
  }

  FLARETUNER_TESTING=1 \
    FLARETUNER_OS_RELEASE="$os_release" \
    FLARETUNER_SYSCTL_CMD=sysctl \
    FLARETUNER_MODPROBE_CMD=modprobe \
    source "$SCRIPT"

  select_profile_inputs() {
    SELECTED_WORKLOAD=web
    SELECTED_MEMORY=1g-4g
    SELECTED_BANDWIDTH=100m-500m
    SELECTED_PROFILE=balanced
  }

  local output
  output="$(run_generate_flow preview)"
  assert_contains "$output" "BBR available: no" "preview BBR status"
  assert_contains "$output" "# Managed by FlareTuner" "preview config"
}

test_status_reports_managed_config_backup_and_loaded_bbr() {
  local root etc_dir state_dir managed_conf backup_file
  root="$TEST_TMP_DIR/status"
  etc_dir="$root/etc"
  state_dir="$root/state"
  managed_conf="$etc_dir/sysctl.d/99-flaretuner.conf"
  backup_file="$state_dir/backup/99-flaretuner.conf.test.bak"
  mkdir -p "$etc_dir/sysctl.d" "$state_dir/backup"
  printf 'managed\n' >"$managed_conf"
  printf 'backup\n' >"$backup_file"
  cat >"$state_dir/latest-backup.env" <<EOF
PREVIOUS_EXISTS=1
BACKUP_PATH=$backup_file
EOF

  sysctl() {
    case "$1 $2" in
      "-n net.ipv4.tcp_congestion_control")
        echo "bbr"
        return 0
        ;;
      "-n net.ipv4.tcp_available_congestion_control")
        echo "reno cubic bbr"
        return 0
        ;;
      "-n net.core.default_qdisc")
        echo "fq"
        return 0
        ;;
    esac
    return 1
  }

  lsmod() {
    echo "tcp_bbr 20480 0"
  }

  id() {
    if [[ "$1" == "-u" ]]; then
      echo "0"
      return 0
    fi
    return 1
  }

  FLARETUNER_TESTING=1 \
    FLARETUNER_ETC_DIR="$etc_dir" \
    FLARETUNER_STATE_DIR="$state_dir" \
    FLARETUNER_SYSCTL_CMD=sysctl \
    FLARETUNER_LSMOD_CMD=lsmod \
    FLARETUNER_ID_CMD=id \
    source "$SCRIPT"

  local output
  output="$(show_status)"
  assert_contains "$output" "tcp_bbr loaded: yes" "status loaded bbr"
  assert_contains "$output" "Managed config: present ($managed_conf)" "status managed present"
  assert_contains "$output" "Latest backup: $backup_file" "status latest backup"
}

test_status_reports_absent_managed_config_and_no_backup() {
  local root etc_dir state_dir
  root="$TEST_TMP_DIR/status-empty"
  etc_dir="$root/etc"
  state_dir="$root/state"
  mkdir -p "$etc_dir/sysctl.d" "$state_dir"

  sysctl() {
    return 1
  }

  lsmod() {
    return 0
  }

  id() {
    if [[ "$1" == "-u" ]]; then
      echo "1000"
      return 0
    fi
    return 1
  }

  FLARETUNER_TESTING=1 \
    FLARETUNER_ETC_DIR="$etc_dir" \
    FLARETUNER_STATE_DIR="$state_dir" \
    FLARETUNER_SYSCTL_CMD=sysctl \
    FLARETUNER_LSMOD_CMD=lsmod \
    FLARETUNER_ID_CMD=id \
    source "$SCRIPT"

  local output
  output="$(show_status)"
  assert_contains "$output" "Managed config: not installed ($etc_dir/sysctl.d/99-flaretuner.conf)" "status managed absent"
  assert_contains "$output" "Latest backup: none" "status no backup"
}

test_apply_writes_managed_config_and_metadata() {
  local root os_release etc_dir state_dir
  root="$TEST_TMP_DIR/apply"
  os_release="$root/os-release"
  etc_dir="$root/etc"
  state_dir="$root/state"
  mkdir -p "$etc_dir/sysctl.d" "$state_dir"
  cat >"$os_release" <<'EOF'
ID=ubuntu
PRETTY_NAME="Ubuntu 24.04 LTS"
EOF

  sysctl() {
    if [[ "$1" == "-n" && "$2" == "net.ipv4.tcp_available_congestion_control" ]]; then
      echo "reno cubic bbr"
      return 0
    fi
    if [[ "$1" == "-n" && "$2" == "net.ipv4.tcp_congestion_control" ]]; then
      echo "bbr"
      return 0
    fi
    if [[ "$1" == "-n" && "$2" == "net.core.default_qdisc" ]]; then
      echo "fq"
      return 0
    fi
    if [[ "$1" == "--system" ]]; then
      return 0
    fi
    return 1
  }

  id() {
    if [[ "$1" == "-u" ]]; then
      echo "0"
      return 0
    fi
    return 1
  }

  FLARETUNER_TESTING=1 \
    FLARETUNER_OS_RELEASE="$os_release" \
    FLARETUNER_ETC_DIR="$etc_dir" \
    FLARETUNER_STATE_DIR="$state_dir" \
    FLARETUNER_SYSCTL_CMD=sysctl \
    FLARETUNER_ID_CMD=id \
    source "$SCRIPT"

  apply_config "$(render_config web 1g-4g 100m-500m balanced)"

  local managed_content metadata
  managed_content="$(<"$etc_dir/sysctl.d/99-flaretuner.conf")"
  metadata="$(<"$state_dir/latest-backup.env")"
  assert_contains "$managed_content" "net.ipv4.tcp_congestion_control = bbr" "managed config bbr"
  assert_contains "$metadata" "PREVIOUS_EXISTS=0" "backup metadata previous missing"
}

test_restore_removes_managed_file_when_no_previous_file() {
  local root os_release etc_dir state_dir managed_conf
  root="$TEST_TMP_DIR/restore"
  os_release="$root/os-release"
  etc_dir="$root/etc"
  state_dir="$root/state"
  managed_conf="$etc_dir/sysctl.d/99-flaretuner.conf"
  mkdir -p "$etc_dir/sysctl.d" "$state_dir"
  cat >"$os_release" <<'EOF'
ID=ubuntu
PRETTY_NAME="Ubuntu 24.04 LTS"
EOF
  printf 'net.ipv4.tcp_congestion_control = bbr\n' >"$managed_conf"
  cat >"$state_dir/latest-backup.env" <<'EOF'
PREVIOUS_EXISTS=0
BACKUP_PATH=
EOF

  sysctl() {
    if [[ "$1" == "--system" ]]; then
      return 0
    fi
    return 0
  }

  id() {
    if [[ "$1" == "-u" ]]; then
      echo "0"
      return 0
    fi
    return 1
  }

  FLARETUNER_TESTING=1 \
    FLARETUNER_OS_RELEASE="$os_release" \
    FLARETUNER_ETC_DIR="$etc_dir" \
    FLARETUNER_STATE_DIR="$state_dir" \
    FLARETUNER_SYSCTL_CMD=sysctl \
    FLARETUNER_ID_CMD=id \
    source "$SCRIPT"

  restore_latest_backup

  if [[ -e "$managed_conf" ]]; then
    fail "managed config should be removed when no previous file existed"
  fi
}

test_restore_previous_file_from_backup_dir() {
  local root os_release etc_dir state_dir managed_conf backup_path
  root="$TEST_TMP_DIR/restore-previous"
  os_release="$root/os-release"
  etc_dir="$root/etc"
  state_dir="$root/state"
  managed_conf="$etc_dir/sysctl.d/99-flaretuner.conf"
  backup_path="$state_dir/backup/99-flaretuner.conf.good.bak"
  mkdir -p "$etc_dir/sysctl.d" "$state_dir/backup"
  cat >"$os_release" <<'EOF'
ID=ubuntu
PRETTY_NAME="Ubuntu 24.04 LTS"
EOF
  printf 'new config\n' >"$managed_conf"
  printf 'previous config\n' >"$backup_path"
  {
    printf 'PREVIOUS_EXISTS=1\n'
    printf 'BACKUP_PATH=%s\n' "$backup_path"
  } >"$state_dir/latest-backup.env"

  sysctl() {
    [[ "$1" == "--system" ]]
  }

  id() {
    if [[ "$1" == "-u" ]]; then
      echo "0"
      return 0
    fi
    return 1
  }

  FLARETUNER_TESTING=1 \
    FLARETUNER_OS_RELEASE="$os_release" \
    FLARETUNER_ETC_DIR="$etc_dir" \
    FLARETUNER_STATE_DIR="$state_dir" \
    FLARETUNER_SYSCTL_CMD=sysctl \
    FLARETUNER_ID_CMD=id \
    source "$SCRIPT"

  restore_latest_backup

  assert_file_contains "$managed_conf" "previous config" "restore previous backup"
}

test_restore_rejects_shell_code_metadata_without_side_effects() {
  local root os_release etc_dir state_dir managed_conf marker sysctl_marker
  root="$TEST_TMP_DIR/restore-shell-code"
  os_release="$root/os-release"
  etc_dir="$root/etc"
  state_dir="$root/state"
  managed_conf="$etc_dir/sysctl.d/99-flaretuner.conf"
  marker="$root/executed"
  sysctl_marker="$root/sysctl-ran"
  mkdir -p "$etc_dir/sysctl.d" "$state_dir"
  cat >"$os_release" <<'EOF'
ID=ubuntu
PRETTY_NAME="Ubuntu 24.04 LTS"
EOF
  printf 'keep me\n' >"$managed_conf"
  {
    printf 'PREVIOUS_EXISTS=0\n'
    printf 'BACKUP_PATH=\n'
    printf 'EVIL=$(touch %s)\n' "$marker"
  } >"$state_dir/latest-backup.env"

  sysctl() {
    printf 'ran\n' >"$sysctl_marker"
    return 0
  }

  id() {
    if [[ "$1" == "-u" ]]; then
      echo "0"
      return 0
    fi
    return 1
  }

  FLARETUNER_TESTING=1 \
    FLARETUNER_OS_RELEASE="$os_release" \
    FLARETUNER_ETC_DIR="$etc_dir" \
    FLARETUNER_STATE_DIR="$state_dir" \
    FLARETUNER_SYSCTL_CMD=sysctl \
    FLARETUNER_ID_CMD=id \
    source "$SCRIPT"

  local status
  set +e
  ( restore_latest_backup ) >/dev/null 2>&1
  status=$?
  set -e

  if [[ "$status" == "0" ]]; then
    fail "restore should reject unknown shell-like metadata key"
  fi
  if [[ -e "$marker" ]]; then
    fail "metadata shell code should not execute"
  fi
  if [[ -e "$sysctl_marker" ]]; then
    fail "restore should not run sysctl for invalid metadata"
  fi
  assert_file_contains "$managed_conf" "keep me" "invalid metadata should not alter managed config"
}

test_restore_rejects_backup_path_outside_backup_dir() {
  local root os_release etc_dir state_dir managed_conf outside_backup
  root="$TEST_TMP_DIR/restore-outside"
  os_release="$root/os-release"
  etc_dir="$root/etc"
  state_dir="$root/state"
  managed_conf="$etc_dir/sysctl.d/99-flaretuner.conf"
  outside_backup="$root/outside.bak"
  mkdir -p "$etc_dir/sysctl.d" "$state_dir/backup"
  cat >"$os_release" <<'EOF'
ID=ubuntu
PRETTY_NAME="Ubuntu 24.04 LTS"
EOF
  printf 'keep me\n' >"$managed_conf"
  printf 'outside\n' >"$outside_backup"
  {
    printf 'PREVIOUS_EXISTS=1\n'
    printf 'BACKUP_PATH=%s\n' "$outside_backup"
  } >"$state_dir/latest-backup.env"

  sysctl() {
    fail "restore should not run sysctl for outside backup path"
  }

  id() {
    if [[ "$1" == "-u" ]]; then
      echo "0"
      return 0
    fi
    return 1
  }

  FLARETUNER_TESTING=1 \
    FLARETUNER_OS_RELEASE="$os_release" \
    FLARETUNER_ETC_DIR="$etc_dir" \
    FLARETUNER_STATE_DIR="$state_dir" \
    FLARETUNER_SYSCTL_CMD=sysctl \
    FLARETUNER_ID_CMD=id \
    source "$SCRIPT"

  local status
  set +e
  ( restore_latest_backup ) >/dev/null 2>&1
  status=$?
  set -e

  if [[ "$status" == "0" ]]; then
    fail "restore should reject backup path outside backup dir"
  fi
  assert_file_contains "$managed_conf" "keep me" "outside backup should not alter managed config"
}

test_restore_rejects_missing_backup_file() {
  local root os_release etc_dir state_dir managed_conf missing_backup
  root="$TEST_TMP_DIR/restore-missing"
  os_release="$root/os-release"
  etc_dir="$root/etc"
  state_dir="$root/state"
  managed_conf="$etc_dir/sysctl.d/99-flaretuner.conf"
  missing_backup="$state_dir/backup/missing.bak"
  mkdir -p "$etc_dir/sysctl.d" "$state_dir/backup"
  cat >"$os_release" <<'EOF'
ID=ubuntu
PRETTY_NAME="Ubuntu 24.04 LTS"
EOF
  printf 'keep me\n' >"$managed_conf"
  {
    printf 'PREVIOUS_EXISTS=1\n'
    printf 'BACKUP_PATH=%s\n' "$missing_backup"
  } >"$state_dir/latest-backup.env"

  sysctl() {
    fail "restore should not run sysctl for missing backup file"
  }

  id() {
    if [[ "$1" == "-u" ]]; then
      echo "0"
      return 0
    fi
    return 1
  }

  FLARETUNER_TESTING=1 \
    FLARETUNER_OS_RELEASE="$os_release" \
    FLARETUNER_ETC_DIR="$etc_dir" \
    FLARETUNER_STATE_DIR="$state_dir" \
    FLARETUNER_SYSCTL_CMD=sysctl \
    FLARETUNER_ID_CMD=id \
    source "$SCRIPT"

  local status
  set +e
  ( restore_latest_backup ) >/dev/null 2>&1
  status=$?
  set -e

  if [[ "$status" == "0" ]]; then
    fail "restore should reject missing backup file"
  fi
  assert_file_contains "$managed_conf" "keep me" "missing backup should not alter managed config"
}

test_restore_rejects_symlink_backup_file() {
  local root os_release etc_dir state_dir managed_conf real_backup symlink_backup
  root="$TEST_TMP_DIR/restore-symlink"
  os_release="$root/os-release"
  etc_dir="$root/etc"
  state_dir="$root/state"
  managed_conf="$etc_dir/sysctl.d/99-flaretuner.conf"
  real_backup="$state_dir/backup/real.bak"
  symlink_backup="$state_dir/backup/link.bak"
  mkdir -p "$etc_dir/sysctl.d" "$state_dir/backup"
  cat >"$os_release" <<'EOF'
ID=ubuntu
PRETTY_NAME="Ubuntu 24.04 LTS"
EOF
  printf 'keep me\n' >"$managed_conf"
  printf 'backup\n' >"$real_backup"
  ln -s "$real_backup" "$symlink_backup"
  {
    printf 'PREVIOUS_EXISTS=1\n'
    printf 'BACKUP_PATH=%s\n' "$symlink_backup"
  } >"$state_dir/latest-backup.env"

  sysctl() {
    fail "restore should not run sysctl for symlink backup file"
  }

  id() {
    if [[ "$1" == "-u" ]]; then
      echo "0"
      return 0
    fi
    return 1
  }

  FLARETUNER_TESTING=1 \
    FLARETUNER_OS_RELEASE="$os_release" \
    FLARETUNER_ETC_DIR="$etc_dir" \
    FLARETUNER_STATE_DIR="$state_dir" \
    FLARETUNER_SYSCTL_CMD=sysctl \
    FLARETUNER_ID_CMD=id \
    source "$SCRIPT"

  local status
  set +e
  ( restore_latest_backup ) >/dev/null 2>&1
  status=$?
  set -e

  if [[ "$status" == "0" ]]; then
    fail "restore should reject symlink backup file"
  fi
  assert_file_contains "$managed_conf" "keep me" "symlink backup should not alter managed config"
}

test_restore_rejects_symlink_parent_directory_escape() {
  local root os_release etc_dir state_dir managed_conf outside_dir escaped_backup symlink_dir
  root="$TEST_TMP_DIR/restore-symlink-dir"
  os_release="$root/os-release"
  etc_dir="$root/etc"
  state_dir="$root/state"
  managed_conf="$etc_dir/sysctl.d/99-flaretuner.conf"
  outside_dir="$root/outside"
  escaped_backup="$state_dir/backup/linkdir/evil.bak"
  symlink_dir="$state_dir/backup/linkdir"
  mkdir -p "$etc_dir/sysctl.d" "$state_dir/backup" "$outside_dir"
  cat >"$os_release" <<'EOF'
ID=ubuntu
PRETTY_NAME="Ubuntu 24.04 LTS"
EOF
  printf 'keep me\n' >"$managed_conf"
  printf 'escaped backup\n' >"$outside_dir/evil.bak"
  ln -s "$outside_dir" "$symlink_dir"
  {
    printf 'PREVIOUS_EXISTS=1\n'
    printf 'BACKUP_PATH=%s\n' "$escaped_backup"
  } >"$state_dir/latest-backup.env"

  sysctl() {
    fail "restore should not run sysctl for symlinked backup parent directory"
  }

  id() {
    if [[ "$1" == "-u" ]]; then
      echo "0"
      return 0
    fi
    return 1
  }

  FLARETUNER_TESTING=1 \
    FLARETUNER_OS_RELEASE="$os_release" \
    FLARETUNER_ETC_DIR="$etc_dir" \
    FLARETUNER_STATE_DIR="$state_dir" \
    FLARETUNER_SYSCTL_CMD=sysctl \
    FLARETUNER_ID_CMD=id \
    source "$SCRIPT"

  local status
  set +e
  ( restore_latest_backup ) >/dev/null 2>&1
  status=$?
  set -e

  if [[ "$status" == "0" ]]; then
    fail "restore should reject symlinked backup parent directory"
  fi
  assert_file_contains "$managed_conf" "keep me" "symlinked parent should not alter managed config"
}

test_apply_restores_previous_file_when_sysctl_fails() {
  local root os_release etc_dir state_dir managed_conf
  root="$TEST_TMP_DIR/apply-failure"
  os_release="$root/os-release"
  etc_dir="$root/etc"
  state_dir="$root/state"
  managed_conf="$etc_dir/sysctl.d/99-flaretuner.conf"
  mkdir -p "$etc_dir/sysctl.d" "$state_dir"
  cat >"$os_release" <<'EOF'
ID=ubuntu
PRETTY_NAME="Ubuntu 24.04 LTS"
EOF
  printf 'previous config\n' >"$managed_conf"

  sysctl() {
    if [[ "$1" == "-n" && "$2" == "net.ipv4.tcp_available_congestion_control" ]]; then
      echo "reno cubic bbr"
      return 0
    fi
    if [[ "$1" == "--system" ]]; then
      return 1
    fi
    return 1
  }

  id() {
    if [[ "$1" == "-u" ]]; then
      echo "0"
      return 0
    fi
    return 1
  }

  FLARETUNER_TESTING=1 \
    FLARETUNER_OS_RELEASE="$os_release" \
    FLARETUNER_ETC_DIR="$etc_dir" \
    FLARETUNER_STATE_DIR="$state_dir" \
    FLARETUNER_SYSCTL_CMD=sysctl \
    FLARETUNER_ID_CMD=id \
    source "$SCRIPT"

  local status
  set +e
  apply_config "$(render_config web 1g-4g 100m-500m balanced)" >/dev/null 2>&1
  status=$?
  set -e

  if [[ "$status" == "0" ]]; then
    fail "apply should fail when sysctl --system fails"
  fi
  assert_file_contains "$managed_conf" "previous config" "apply failure should restore previous managed config"
}

test_apply_restores_previous_file_when_verification_fails() {
  local root os_release etc_dir state_dir managed_conf
  root="$TEST_TMP_DIR/apply-verification-failure"
  os_release="$root/os-release"
  etc_dir="$root/etc"
  state_dir="$root/state"
  managed_conf="$etc_dir/sysctl.d/99-flaretuner.conf"
  mkdir -p "$etc_dir/sysctl.d" "$state_dir"
  cat >"$os_release" <<'EOF'
ID=ubuntu
PRETTY_NAME="Ubuntu 24.04 LTS"
EOF
  printf 'previous config\n' >"$managed_conf"

  sysctl() {
    if [[ "$1" == "-n" && "$2" == "net.ipv4.tcp_available_congestion_control" ]]; then
      echo "reno cubic bbr"
      return 0
    fi
    if [[ "$1" == "-n" && "$2" == "net.ipv4.tcp_congestion_control" ]]; then
      echo "bbr"
      return 0
    fi
    if [[ "$1" == "-n" && "$2" == "net.core.default_qdisc" ]]; then
      echo "pfifo_fast"
      return 0
    fi
    if [[ "$1" == "--system" ]]; then
      return 0
    fi
    return 1
  }

  id() {
    if [[ "$1" == "-u" ]]; then
      echo "0"
      return 0
    fi
    return 1
  }

  FLARETUNER_TESTING=1 \
    FLARETUNER_OS_RELEASE="$os_release" \
    FLARETUNER_ETC_DIR="$etc_dir" \
    FLARETUNER_STATE_DIR="$state_dir" \
    FLARETUNER_SYSCTL_CMD=sysctl \
    FLARETUNER_ID_CMD=id \
    source "$SCRIPT"

  local status
  set +e
  ( apply_config "$(render_config web 1g-4g 100m-500m balanced)" ) >/dev/null 2>&1
  status=$?
  set -e

  if [[ "$status" == "0" ]]; then
    fail "apply should fail when active verification fails"
  fi
  assert_file_contains "$managed_conf" "previous config" "verification failure should restore previous managed config"
}

test_apply_tc_egress_limit_records_metadata_and_commands() {
  local root state_dir log_file
  root="$TEST_TMP_DIR/tc-apply"
  state_dir="$root/state"
  log_file="$root/tc.log"
  mkdir -p "$state_dir"

  tc() {
    printf '%s\n' "$*" >>"$log_file"
    return 0
  }

  id() {
    if [[ "$1" == "-u" ]]; then
      echo "0"
      return 0
    fi
    return 1
  }

  FLARETUNER_TESTING=1 \
    FLARETUNER_STATE_DIR="$state_dir" \
    FLARETUNER_TC_CMD=tc \
    FLARETUNER_ID_CMD=id \
    source "$SCRIPT"

  apply_tc_egress_limit eth0 90

  local log metadata
  log="$(<"$log_file")"
  metadata="$(<"$state_dir/tc-limit.env")"
  assert_contains "$log" "qdisc replace dev eth0 root handle 1: htb default 10" "tc root qdisc command"
  assert_contains "$log" "class replace dev eth0 parent 1: classid 1:10 htb rate 90mbit ceil 90mbit" "tc rate class command"
  assert_contains "$log" "qdisc replace dev eth0 parent 1:10 handle 10: fq" "tc fq child command"
  assert_contains "$metadata" "IFACE=eth0" "tc metadata iface"
  assert_contains "$metadata" "RATE_MBPS=90" "tc metadata rate"
}

test_apply_tc_egress_limit_rejects_unsafe_iface() {
  local state_dir
  state_dir="$TEST_TMP_DIR/tc-unsafe-state"
  mkdir -p "$state_dir"

  tc() {
    fail "tc should not run for unsafe interface"
  }

  id() {
    if [[ "$1" == "-u" ]]; then
      echo "0"
      return 0
    fi
    return 1
  }

  FLARETUNER_TESTING=1 \
    FLARETUNER_STATE_DIR="$state_dir" \
    FLARETUNER_TC_CMD=tc \
    FLARETUNER_ID_CMD=id \
    source "$SCRIPT"

  local status
  set +e
  ( apply_tc_egress_limit 'eth0;rm' 90 ) >/dev/null 2>&1
  status=$?
  set -e

  if [[ "$status" == "0" ]]; then
    fail "unsafe interface should be rejected"
  fi
}

test_clear_tc_egress_limit_uses_metadata() {
  local root state_dir log_file
  root="$TEST_TMP_DIR/tc-clear"
  state_dir="$root/state"
  log_file="$root/tc.log"
  mkdir -p "$state_dir"
  cat >"$state_dir/tc-limit.env" <<'EOF'
IFACE=eth0
RATE_MBPS=90
EOF

  tc() {
    printf '%s\n' "$*" >>"$log_file"
    return 0
  }

  id() {
    if [[ "$1" == "-u" ]]; then
      echo "0"
      return 0
    fi
    return 1
  }

  FLARETUNER_TESTING=1 \
    FLARETUNER_STATE_DIR="$state_dir" \
    FLARETUNER_TC_CMD=tc \
    FLARETUNER_ID_CMD=id \
    source "$SCRIPT"

  clear_tc_egress_limit

  local log
  log="$(<"$log_file")"
  assert_contains "$log" "qdisc del dev eth0 root" "tc clear command"
  if [[ -e "$state_dir/tc-limit.env" ]]; then
    fail "tc metadata should be removed after clearing"
  fi
}

run_test "render low-memory conservative config" test_render_low_memory_config
run_test "render high-throughput aggressive config" test_render_high_throughput_config
run_test "render qos-sensitive proxy config caps buffers" test_render_qos_sensitive_proxy_config_caps_buffers
run_test "detect supported Debian" test_supported_debian_detection
run_test "detect unsupported Alpine" test_unsupported_alpine_detection
run_test "detect BBR availability" test_bbr_available_from_sysctl_output
run_test "choose option handles EOF" test_choose_option_handles_eof
run_test "detect memory tier from meminfo" test_detect_memory_tier_from_meminfo
run_test "detect bandwidth tier from sysfs speed" test_detect_bandwidth_tier_from_sysfs_speed
run_test "recommend low-memory defaults" test_recommended_profile_defaults_for_low_memory
run_test "map target Mbps to bandwidth tier" test_bandwidth_tier_from_target_mbps
run_test "recommend qos-sensitive target defaults" test_recommended_profile_defaults_for_qos_sensitive_target
run_test "choose option with default accepts blank" test_choose_option_with_default_accepts_blank_default
run_test "choose option with default allows manual override" test_choose_option_with_default_allows_manual_override
run_test "select profile inputs uses detected defaults" test_select_profile_inputs_uses_detected_defaults
run_test "preview does not load BBR" test_preview_does_not_load_bbr
run_test "status reports managed config backup and loaded BBR" test_status_reports_managed_config_backup_and_loaded_bbr
run_test "status reports absent managed config and no backup" test_status_reports_absent_managed_config_and_no_backup
run_test "apply writes managed config and metadata" test_apply_writes_managed_config_and_metadata
run_test "restore removes managed file when no previous file" test_restore_removes_managed_file_when_no_previous_file
run_test "restore previous file from backup dir" test_restore_previous_file_from_backup_dir
run_test "restore rejects shell code metadata without side effects" test_restore_rejects_shell_code_metadata_without_side_effects
run_test "restore rejects backup path outside backup dir" test_restore_rejects_backup_path_outside_backup_dir
run_test "restore rejects missing backup file" test_restore_rejects_missing_backup_file
run_test "restore rejects symlink backup file" test_restore_rejects_symlink_backup_file
run_test "restore rejects symlink parent directory escape" test_restore_rejects_symlink_parent_directory_escape
run_test "apply restores previous file when sysctl fails" test_apply_restores_previous_file_when_sysctl_fails
run_test "apply restores previous file when verification fails" test_apply_restores_previous_file_when_verification_fails
run_test "apply tc egress limit records metadata and commands" test_apply_tc_egress_limit_records_metadata_and_commands
run_test "apply tc egress limit rejects unsafe iface" test_apply_tc_egress_limit_rejects_unsafe_iface
run_test "clear tc egress limit uses metadata" test_clear_tc_egress_limit_uses_metadata

echo "Passed $pass_count tests"
