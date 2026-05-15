#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/flaretuner.sh"

pass_count=0
TEST_TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TEST_TMP_DIR"
  unset FLARETUNER_TESTING FLARETUNER_OS_RELEASE FLARETUNER_SYSCTL_CMD FLARETUNER_MODPROBE_CMD FLARETUNER_ID_CMD
  unset FLARETUNER_ETC_DIR FLARETUNER_STATE_DIR
  unset SELECTED_WORKLOAD SELECTED_MEMORY SELECTED_BANDWIDTH SELECTED_PROFILE
  unset -f sysctl modprobe id select_profile_inputs 2>/dev/null || true
}

reset_test_env() {
  unset FLARETUNER_TESTING FLARETUNER_OS_RELEASE FLARETUNER_SYSCTL_CMD FLARETUNER_MODPROBE_CMD FLARETUNER_ID_CMD
  unset FLARETUNER_ETC_DIR FLARETUNER_STATE_DIR
  unset SELECTED_WORKLOAD SELECTED_MEMORY SELECTED_BANDWIDTH SELECTED_PROFILE
  unset -f sysctl modprobe id select_profile_inputs 2>/dev/null || true
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

run_test "render low-memory conservative config" test_render_low_memory_config
run_test "render high-throughput aggressive config" test_render_high_throughput_config
run_test "detect supported Debian" test_supported_debian_detection
run_test "detect unsupported Alpine" test_unsupported_alpine_detection
run_test "detect BBR availability" test_bbr_available_from_sysctl_output
run_test "choose option handles EOF" test_choose_option_handles_eof
run_test "preview does not load BBR" test_preview_does_not_load_bbr
run_test "apply writes managed config and metadata" test_apply_writes_managed_config_and_metadata
run_test "restore removes managed file when no previous file" test_restore_removes_managed_file_when_no_previous_file

echo "Passed $pass_count tests"
