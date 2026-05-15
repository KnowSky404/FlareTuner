# FlareTuner Script MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Debian/Ubuntu-focused interactive Bash script that previews, applies, verifies, and rolls back FlareTuner BBR sysctl tuning.

**Architecture:** The MVP is a single executable Bash script with functions split by responsibility: platform detection, input handling, tuning rule mapping, config rendering, apply/backup/rollback, and status reporting. A shell test runner exercises the pure logic and filesystem side effects through environment overrides so the real host sysctl files are not touched during tests.

**Tech Stack:** Bash, POSIX userland commands, `sysctl`, `modprobe`, Markdown documentation.

---

## File Structure

- Create: `scripts/flaretuner.sh`
  - Interactive CLI entrypoint and all MVP behavior.
  - Supports environment overrides for tests:
    - `FLARETUNER_ETC_DIR`
    - `FLARETUNER_STATE_DIR`
    - `FLARETUNER_OS_RELEASE`
    - `FLARETUNER_SYSCTL_CMD`
    - `FLARETUNER_MODPROBE_CMD`
    - `FLARETUNER_LSMOD_CMD`
    - `FLARETUNER_UNAME_CMD`
    - `FLARETUNER_ID_CMD`
- Create: `tests/flaretuner_test.sh`
  - Minimal Bash test runner with isolated temporary directories.
  - Sources `scripts/flaretuner.sh` with `FLARETUNER_TESTING=1`.
- Create: `docs/tuning-rules.md`
  - Human-readable tuning rule documentation.
- Modify: `README.md`
  - Adds usage, support scope, and safety notes.

## Command And Test Conventions

- Syntax check command:

```bash
bash -n scripts/flaretuner.sh
```

- Test command:

```bash
bash tests/flaretuner_test.sh
```

- The implementation must guard the CLI entrypoint with:

```bash
if [[ "${FLARETUNER_TESTING:-0}" != "1" ]]; then
  main "$@"
fi
```

---

### Task 1: Core Script Skeleton And Rendering Rules

**Files:**
- Create: `scripts/flaretuner.sh`
- Create: `tests/flaretuner_test.sh`

- [ ] **Step 1: Create the initial failing test runner**

Create `tests/flaretuner_test.sh` with:

```bash
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

run_test "render low-memory conservative config" test_render_low_memory_config
run_test "render high-throughput aggressive config" test_render_high_throughput_config

echo "Passed $pass_count tests"
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
bash tests/flaretuner_test.sh
```

Expected: FAIL because `scripts/flaretuner.sh` does not exist or `render_config` is not defined.

- [ ] **Step 3: Create the script skeleton and config renderer**

Create `scripts/flaretuner.sh` with:

```bash
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
    under-100m) ;;
    100m-500m)
      (( RMEM_MAX < 16777216 )) || true
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
    balanced) ;;
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

main() {
  echo "$APP_NAME $VERSION"
}

if [[ "${FLARETUNER_TESTING:-0}" != "1" ]]; then
  main "$@"
fi
```

- [ ] **Step 4: Run syntax and tests**

Run:

```bash
bash -n scripts/flaretuner.sh
bash tests/flaretuner_test.sh
```

Expected: both commands pass, and the test runner prints `Passed 2 tests`.

- [ ] **Step 5: Commit**

```bash
git add scripts/flaretuner.sh tests/flaretuner_test.sh
git commit -m "Add FlareTuner config renderer"
```

---

### Task 2: Platform, BBR, Status, And Menu Input

**Files:**
- Modify: `scripts/flaretuner.sh`
- Modify: `tests/flaretuner_test.sh`

- [ ] **Step 1: Add failing tests for platform detection and BBR availability**

Append these tests before the final `echo "Passed $pass_count tests"` line in `tests/flaretuner_test.sh`:

```bash
test_supported_debian_detection() {
  local tmp
  tmp="$(mktemp -d)"
  cat >"$tmp/os-release" <<'EOF'
ID=debian
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
EOF
  FLARETUNER_TESTING=1 FLARETUNER_OS_RELEASE="$tmp/os-release" source "$SCRIPT"
  assert_equals "$(os_id)" "debian" "debian id"
  assert_equals "$(is_supported_os && echo yes || echo no)" "yes" "debian supported"
  rm -rf "$tmp"
}

test_unsupported_os_detection() {
  local tmp
  tmp="$(mktemp -d)"
  cat >"$tmp/os-release" <<'EOF'
ID=alpine
PRETTY_NAME="Alpine Linux"
EOF
  FLARETUNER_TESTING=1 FLARETUNER_OS_RELEASE="$tmp/os-release" source "$SCRIPT"
  assert_equals "$(os_id)" "alpine" "alpine id"
  assert_equals "$(is_supported_os && echo yes || echo no)" "no" "alpine unsupported"
  rm -rf "$tmp"
}

test_bbr_available_from_sysctl_output() {
  local tmp
  tmp="$(mktemp -d)"
  cat >"$tmp/sysctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-n net.ipv4.tcp_available_congestion_control" ]]; then
  echo "reno cubic bbr"
  exit 0
fi
exit 1
EOF
  chmod +x "$tmp/sysctl"
  FLARETUNER_TESTING=1 FLARETUNER_SYSCTL_CMD="$tmp/sysctl" source "$SCRIPT"
  assert_equals "$(bbr_available && echo yes || echo no)" "yes" "bbr available"
  rm -rf "$tmp"
}

run_test "detect supported Debian" test_supported_debian_detection
run_test "detect unsupported OS" test_unsupported_os_detection
run_test "detect BBR availability" test_bbr_available_from_sysctl_output
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
bash tests/flaretuner_test.sh
```

Expected: FAIL because `os_id`, `is_supported_os`, or `bbr_available` is not defined.

- [ ] **Step 3: Implement detection, status, and menu input functions**

Add these functions to `scripts/flaretuner.sh` above `main()`:

```bash
os_id() {
  [[ -r "$OS_RELEASE_FILE" ]] || return 1
  (
    set +u
    . "$OS_RELEASE_FILE"
    printf '%s\n' "${ID:-unknown}"
  )
}

os_pretty_name() {
  [[ -r "$OS_RELEASE_FILE" ]] || {
    echo "unknown"
    return 0
  }
  (
    set +u
    . "$OS_RELEASE_FILE"
    printf '%s\n' "${PRETTY_NAME:-${ID:-unknown}}"
  )
}

is_supported_os() {
  case "$(os_id 2>/dev/null || true)" in
    debian|ubuntu) return 0 ;;
    *) return 1 ;;
  esac
}

require_supported_os() {
  if ! is_supported_os; then
    die "only Debian and Ubuntu are supported in this version. Detected: $(os_pretty_name)"
  fi
}

is_root() {
  [[ "$("$ID_CMD" -u)" == "0" ]]
}

require_root() {
  is_root || die "root privileges are required for this action"
}

sysctl_get() {
  local key="$1"
  "$SYSCTL_CMD" -n "$key" 2>/dev/null || true
}

bbr_available() {
  local available
  available="$(sysctl_get net.ipv4.tcp_available_congestion_control)"
  [[ " $available " == *" bbr "* ]]
}

try_load_bbr() {
  bbr_available && return 0
  if is_root && command -v "$MODPROBE_CMD" >/dev/null 2>&1; then
    "$MODPROBE_CMD" tcp_bbr >/dev/null 2>&1 || true
  fi
  bbr_available
}

show_status() {
  echo "$APP_NAME status"
  echo "OS: $(os_pretty_name)"
  echo "Kernel: $("$UNAME_CMD" -r 2>/dev/null || echo unknown)"
  echo "Congestion control: $(sysctl_get net.ipv4.tcp_congestion_control)"
  echo "Available congestion controls: $(sysctl_get net.ipv4.tcp_available_congestion_control)"
  echo "Default qdisc: $(sysctl_get net.core.default_qdisc)"
  if [[ -f "$MANAGED_CONF" ]]; then
    echo "Managed config: $MANAGED_CONF"
  else
    echo "Managed config: not installed"
  fi
  if [[ -f "$LATEST_BACKUP_FILE" ]]; then
    echo "Latest backup metadata: $LATEST_BACKUP_FILE"
  else
    echo "Latest backup metadata: none"
  fi
}

choose_option() {
  local prompt="$1"
  shift
  local options=("$@")
  local choice
  while true; do
    echo "$prompt"
    local i
    for i in "${!options[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "${options[$i]}"
    done
    read -r -p "Choose: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      echo "${options[$((choice - 1))]}"
      return 0
    fi
    echo "Invalid choice. Try again." >&2
  done
}

select_profile_inputs() {
  local workload_label memory_label bandwidth_label profile_label
  workload_label="$(choose_option "Workload" "Web/API" "Proxy/VPN" "Download or high-throughput transfer" "Low-memory VPS")"
  memory_label="$(choose_option "Memory tier" "under 512 MB" "512 MB to 1 GB" "1 GB to 4 GB" "4 GB or more")"
  bandwidth_label="$(choose_option "Bandwidth tier" "under 100 Mbps" "100 Mbps to 500 Mbps" "500 Mbps to 1 Gbps" "1 Gbps or more")"
  profile_label="$(choose_option "Tuning profile" "conservative" "balanced" "aggressive")"

  case "$workload_label" in
    "Web/API") SELECTED_WORKLOAD="web" ;;
    "Proxy/VPN") SELECTED_WORKLOAD="proxy" ;;
    "Download or high-throughput transfer") SELECTED_WORKLOAD="download" ;;
    "Low-memory VPS") SELECTED_WORKLOAD="low-memory" ;;
  esac
  case "$memory_label" in
    "under 512 MB") SELECTED_MEMORY="under-512m" ;;
    "512 MB to 1 GB") SELECTED_MEMORY="512m-1g" ;;
    "1 GB to 4 GB") SELECTED_MEMORY="1g-4g" ;;
    "4 GB or more") SELECTED_MEMORY="4g-plus" ;;
  esac
  case "$bandwidth_label" in
    "under 100 Mbps") SELECTED_BANDWIDTH="under-100m" ;;
    "100 Mbps to 500 Mbps") SELECTED_BANDWIDTH="100m-500m" ;;
    "500 Mbps to 1 Gbps") SELECTED_BANDWIDTH="500m-1g" ;;
    "1 Gbps or more") SELECTED_BANDWIDTH="1g-plus" ;;
  esac
  SELECTED_PROFILE="$profile_label"
}

explain_config() {
  local workload="$1"
  local memory="$2"
  local bandwidth="$3"
  local profile="$4"
  echo "Tuning summary:"
  echo "- Enables standard BBR and fq."
  echo "- Workload '$workload' adjusts backlog and buffer emphasis."
  echo "- Memory tier '$memory' bounds socket buffers."
  echo "- Bandwidth tier '$bandwidth' sets throughput ceilings."
  echo "- Profile '$profile' controls how far values move from conservative defaults."
}
```

Replace `main()` with:

```bash
main() {
  while true; do
    echo "$APP_NAME $VERSION"
    echo "1) Generate and apply tuning"
    echo "2) Preview tuning only"
    echo "3) Restore last FlareTuner backup"
    echo "4) Show current network tuning status"
    echo "5) Exit"
    read -r -p "Choose: " choice
    case "$choice" in
      1)
        run_generate_flow "apply"
        ;;
      2)
        run_generate_flow "preview"
        ;;
      3)
        restore_latest_backup
        ;;
      4)
        show_status
        ;;
      5)
        exit 0
        ;;
      *)
        echo "Invalid choice. Try again." >&2
        ;;
    esac
  done
}
```

Add temporary stubs above `main()` so syntax works until Task 3:

```bash
run_generate_flow() {
  local mode="$1"
  select_profile_inputs
  show_status
  echo
  render_config "$SELECTED_WORKLOAD" "$SELECTED_MEMORY" "$SELECTED_BANDWIDTH" "$SELECTED_PROFILE"
  echo
  explain_config "$SELECTED_WORKLOAD" "$SELECTED_MEMORY" "$SELECTED_BANDWIDTH" "$SELECTED_PROFILE"
  if [[ "$mode" == "apply" ]]; then
    echo "Apply flow will be implemented in the next task."
  fi
}

restore_latest_backup() {
  echo "Restore flow will be implemented in the next task."
}
```

- [ ] **Step 4: Run syntax and tests**

Run:

```bash
bash -n scripts/flaretuner.sh
bash tests/flaretuner_test.sh
```

Expected: both pass, and the test runner prints `Passed 5 tests`.

- [ ] **Step 5: Commit**

```bash
git add scripts/flaretuner.sh tests/flaretuner_test.sh
git commit -m "Add platform and BBR detection"
```

---

### Task 3: Apply, Backup, Rollback, And Verification

**Files:**
- Modify: `scripts/flaretuner.sh`
- Modify: `tests/flaretuner_test.sh`

- [ ] **Step 1: Add failing tests for apply and rollback**

Append these tests before the final `echo "Passed $pass_count tests"` line in `tests/flaretuner_test.sh`:

```bash
test_apply_writes_managed_config_and_metadata() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/etc/sysctl.d" "$tmp/state"
  cat >"$tmp/os-release" <<'EOF'
ID=ubuntu
PRETTY_NAME="Ubuntu 24.04 LTS"
EOF
  cat >"$tmp/sysctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "--system" ]]; then
  exit 0
fi
if [[ "$*" == "-n net.ipv4.tcp_available_congestion_control" ]]; then
  echo "reno cubic bbr"
  exit 0
fi
if [[ "$*" == "-n net.ipv4.tcp_congestion_control" ]]; then
  echo "bbr"
  exit 0
fi
if [[ "$*" == "-n net.core.default_qdisc" ]]; then
  echo "fq"
  exit 0
fi
exit 0
EOF
  cat >"$tmp/id" <<'EOF'
#!/usr/bin/env bash
echo 0
EOF
  chmod +x "$tmp/sysctl" "$tmp/id"
  FLARETUNER_TESTING=1 \
    FLARETUNER_ETC_DIR="$tmp/etc" \
    FLARETUNER_STATE_DIR="$tmp/state" \
    FLARETUNER_OS_RELEASE="$tmp/os-release" \
    FLARETUNER_SYSCTL_CMD="$tmp/sysctl" \
    FLARETUNER_ID_CMD="$tmp/id" \
    source "$SCRIPT"

  apply_config "$(render_config "web" "1g-4g" "100m-500m" "balanced")"
  assert_contains "$(cat "$tmp/etc/sysctl.d/99-flaretuner.conf")" "net.ipv4.tcp_congestion_control = bbr" "managed config written"
  assert_contains "$(cat "$tmp/state/latest-backup.env")" "PREVIOUS_EXISTS=0" "metadata says no previous file"
  rm -rf "$tmp"
}

test_restore_removes_managed_file_when_no_previous_file() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/etc/sysctl.d" "$tmp/state"
  cat >"$tmp/etc/sysctl.d/99-flaretuner.conf" <<'EOF'
net.ipv4.tcp_congestion_control = bbr
EOF
  cat >"$tmp/state/latest-backup.env" <<'EOF'
PREVIOUS_EXISTS=0
BACKUP_PATH=
EOF
  cat >"$tmp/sysctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"$tmp/id" <<'EOF'
#!/usr/bin/env bash
echo 0
EOF
  chmod +x "$tmp/sysctl" "$tmp/id"
  FLARETUNER_TESTING=1 \
    FLARETUNER_ETC_DIR="$tmp/etc" \
    FLARETUNER_STATE_DIR="$tmp/state" \
    FLARETUNER_SYSCTL_CMD="$tmp/sysctl" \
    FLARETUNER_ID_CMD="$tmp/id" \
    source "$SCRIPT"

  restore_latest_backup
  if [[ -e "$tmp/etc/sysctl.d/99-flaretuner.conf" ]]; then
    fail "restore should remove managed config when no previous file existed"
  fi
  rm -rf "$tmp"
}

run_test "apply writes managed config and metadata" test_apply_writes_managed_config_and_metadata
run_test "restore removes managed file when no previous file existed" test_restore_removes_managed_file_when_no_previous_file
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
bash tests/flaretuner_test.sh
```

Expected: FAIL because `apply_config` is not implemented.

- [ ] **Step 3: Implement backup, apply, verify, and rollback**

Add these functions above `run_generate_flow()` in `scripts/flaretuner.sh`:

```bash
timestamp() {
  date +%Y%m%d%H%M%S
}

write_latest_backup_metadata() {
  local previous_exists="$1"
  local backup_path="$2"
  mkdir -p "$STATE_DIR"
  cat >"$LATEST_BACKUP_FILE" <<EOF
PREVIOUS_EXISTS=$previous_exists
BACKUP_PATH=$backup_path
EOF
}

backup_managed_config() {
  mkdir -p "$BACKUP_DIR"
  if [[ -f "$MANAGED_CONF" ]]; then
    local backup_path="$BACKUP_DIR/99-flaretuner.conf.$(timestamp).bak"
    cp "$MANAGED_CONF" "$backup_path"
    write_latest_backup_metadata "1" "$backup_path"
    echo "Backup created: $backup_path"
  else
    write_latest_backup_metadata "0" ""
    echo "No existing FlareTuner config found; restore will remove the new managed file."
  fi
}

verify_active_settings() {
  local cc qdisc
  cc="$(sysctl_get net.ipv4.tcp_congestion_control)"
  qdisc="$(sysctl_get net.core.default_qdisc)"
  [[ "$cc" == "bbr" && "$qdisc" == "fq" ]]
}

apply_config() {
  local config="$1"
  require_root
  require_supported_os
  if ! try_load_bbr; then
    die "BBR is not available. The current kernel likely does not support standard BBR."
  fi

  backup_managed_config
  mkdir -p "$(dirname "$MANAGED_CONF")"
  printf '%s\n' "$config" >"$MANAGED_CONF"
  "$SYSCTL_CMD" --system

  if verify_active_settings; then
    echo "FlareTuner tuning applied successfully."
  else
    echo "FlareTuner wrote the config, but active verification failed." >&2
    echo "Use the restore menu if network behavior is not as expected." >&2
    return 1
  fi
}

restore_latest_backup() {
  require_root
  if [[ ! -f "$LATEST_BACKUP_FILE" ]]; then
    die "no FlareTuner backup metadata found"
  fi

  local PREVIOUS_EXISTS BACKUP_PATH
  PREVIOUS_EXISTS=0
  BACKUP_PATH=
  # shellcheck disable=SC1090
  . "$LATEST_BACKUP_FILE"

  if [[ "$PREVIOUS_EXISTS" == "1" ]]; then
    [[ -f "$BACKUP_PATH" ]] || die "backup file not found: $BACKUP_PATH"
    mkdir -p "$(dirname "$MANAGED_CONF")"
    cp "$BACKUP_PATH" "$MANAGED_CONF"
    echo "Restored previous FlareTuner config from $BACKUP_PATH"
  else
    rm -f "$MANAGED_CONF"
    echo "Removed FlareTuner managed config."
  fi

  "$SYSCTL_CMD" --system
  show_status
}
```

Remove the old temporary `restore_latest_backup()` stub.

Replace `run_generate_flow()` with:

```bash
run_generate_flow() {
  local mode="$1"
  if [[ "$mode" == "apply" ]]; then
    require_root
    require_supported_os
  fi

  select_profile_inputs
  local config
  config="$(render_config "$SELECTED_WORKLOAD" "$SELECTED_MEMORY" "$SELECTED_BANDWIDTH" "$SELECTED_PROFILE")"

  show_status
  echo
  echo "$config"
  echo
  explain_config "$SELECTED_WORKLOAD" "$SELECTED_MEMORY" "$SELECTED_BANDWIDTH" "$SELECTED_PROFILE"

  if [[ "$mode" == "apply" ]]; then
    echo
    read -r -p "Apply this configuration now? Type 'yes' to continue: " confirm
    if [[ "$confirm" == "yes" ]]; then
      apply_config "$config"
    else
      echo "Apply cancelled."
    fi
  fi
}
```

- [ ] **Step 4: Run syntax and tests**

Run:

```bash
bash -n scripts/flaretuner.sh
bash tests/flaretuner_test.sh
```

Expected: both pass, and the test runner prints `Passed 7 tests`.

- [ ] **Step 5: Commit**

```bash
git add scripts/flaretuner.sh tests/flaretuner_test.sh
git commit -m "Add apply and rollback flow"
```

---

### Task 4: Documentation And Final Verification

**Files:**
- Create: `docs/tuning-rules.md`
- Modify: `README.md`

- [ ] **Step 1: Create tuning rules documentation**

Create `docs/tuning-rules.md` with:

```markdown
# FlareTuner Tuning Rules

FlareTuner's first version targets Debian and Ubuntu VPS servers using standard Linux BBR and `fq`.

## Inputs

- Workload controls which resource gets priority.
- Memory tier limits socket buffer growth on small VPS instances.
- Bandwidth tier sets upper bounds for receive and send buffers.
- Tuning profile controls how aggressive backlog values become.

## Baseline

Every generated profile enables:

```text
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

`fq` is the queue discipline normally paired with standard BBR. `bbr` is the congestion control target for this MVP.

## Memory Safety

Low-memory VPS profiles cap `rmem_max`, `wmem_max`, `tcp_rmem`, and `tcp_wmem` at modest values. This avoids turning network buffers into a source of memory pressure on very small servers.

## Workload Behavior

- Web/API raises connection backlog values while keeping buffers moderate.
- Proxy/VPN raises network device backlog to tolerate many packet flows.
- Download and high-throughput transfer raises socket buffer ceilings.
- Low-memory VPS overrides other choices with smaller bounded values.

## Rollback

FlareTuner writes only `/etc/sysctl.d/99-flaretuner.conf`. Before applying a new config, it stores backup metadata in `/var/lib/flaretuner/latest-backup.env` and backups in `/var/lib/flaretuner/backup/`.

Rollback only restores or removes the FlareTuner-managed file. It does not edit unrelated sysctl snippets.
```

- [ ] **Step 2: Update README**

Replace `README.md` with:

```markdown
# FlareTuner

Effortless BBR and network tuning for modern Linux VPS servers.

## MVP Scope

The first version provides an interactive Bash script for Debian and Ubuntu. It can:

- preview BBR-oriented sysctl tuning
- enable standard `bbr` with `fq`
- apply tuning to `/etc/sysctl.d/99-flaretuner.conf`
- back up the previous FlareTuner-managed config
- restore the latest FlareTuner backup
- show current network tuning status

It does not install or replace kernels, tune BBRv2, run benchmarks, or support non-Debian/Ubuntu distributions yet.

## Usage

Preview and inspect locally:

```bash
bash scripts/flaretuner.sh
```

Apply mode requires root because it writes to `/etc/sysctl.d/` and runs `sysctl --system`:

```bash
sudo bash scripts/flaretuner.sh
```

## Safety

FlareTuner writes only:

```text
/etc/sysctl.d/99-flaretuner.conf
```

It does not edit `/etc/sysctl.conf`. Before applying a new config, it records backup metadata under:

```text
/var/lib/flaretuner/
```

Use the script's restore menu to restore the latest FlareTuner-managed backup.

## Development

Run syntax and behavior checks:

```bash
bash -n scripts/flaretuner.sh
bash tests/flaretuner_test.sh
```

See [docs/tuning-rules.md](docs/tuning-rules.md) for the current tuning model.
```

- [ ] **Step 3: Run final verification**

Run:

```bash
bash -n scripts/flaretuner.sh
bash tests/flaretuner_test.sh
```

Expected: both pass, and the test runner prints `Passed 7 tests`.

- [ ] **Step 4: Review git diff**

Run:

```bash
git diff -- scripts/flaretuner.sh tests/flaretuner_test.sh docs/tuning-rules.md README.md
```

Expected: diff shows only the script MVP, tests, README, and tuning rules docs.

- [ ] **Step 5: Commit**

```bash
git add scripts/flaretuner.sh tests/flaretuner_test.sh docs/tuning-rules.md README.md
git commit -m "Document FlareTuner script MVP"
```

---

## Self-Review Notes

- Spec coverage:
  - Debian/Ubuntu detection: Task 2.
  - BBR/fq baseline generation: Task 1.
  - Workload, memory, bandwidth, and profile inputs: Tasks 1 and 2.
  - Preview and apply menu: Tasks 2 and 3.
  - Backup metadata and rollback: Task 3.
  - Status command: Task 2.
  - README and tuning rules documentation: Task 4.
- The plan intentionally keeps the MVP in Bash to avoid runtime dependencies on small VPS instances.
- Full live application still needs manual validation on a disposable Debian or Ubuntu VPS after local tests pass.
