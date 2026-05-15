#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/flaretuner.sh"

pass_count=0

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
  "$@"
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
  os_release="$(mktemp)"
  cat >"$os_release" <<'EOF'
ID=debian
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
EOF

  FLARETUNER_TESTING=1 FLARETUNER_OS_RELEASE="$os_release" source "$SCRIPT"

  assert_equals "$(os_id)" "debian" "debian os id"
  if ! is_supported_os; then
    fail "debian should be supported"
  fi

  rm -f "$os_release"
}

test_unsupported_alpine_detection() {
  local os_release
  os_release="$(mktemp)"
  cat >"$os_release" <<'EOF'
ID=alpine
PRETTY_NAME="Alpine Linux"
EOF

  FLARETUNER_TESTING=1 FLARETUNER_OS_RELEASE="$os_release" source "$SCRIPT"

  assert_equals "$(os_id)" "alpine" "alpine os id"
  if is_supported_os; then
    fail "alpine should not be supported"
  fi

  rm -f "$os_release"
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

  unset -f sysctl
}

run_test "render low-memory conservative config" test_render_low_memory_config
run_test "render high-throughput aggressive config" test_render_high_throughput_config
run_test "detect supported Debian" test_supported_debian_detection
run_test "detect unsupported Alpine" test_unsupported_alpine_detection
run_test "detect BBR availability" test_bbr_available_from_sysctl_output

echo "Passed $pass_count tests"
