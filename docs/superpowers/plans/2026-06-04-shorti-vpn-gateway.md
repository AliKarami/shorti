# shorti VPN Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Post-implementation amendments (2026-06-04 review):** the shipped code differs
> from the original code blocks below in three deliberate ways. Treat the live
> files as the source of truth:
> - **`compose.yml` uses `network_mode: host`** (not a bridge network). The VPN
>   tunnel and iptables rules must live in the host namespace for the labstation
>   to act as a transparent gateway for Mikrotik-routed LAN traffic. A bridge
>   network would trap the tunnel inside the container.
> - **`routing.sh` adds a TCP MSS clamp** (`TCPMSS --clamp-mss-to-pmtu`) on the
>   FORWARD chain, plus auto-detects the LAN interface (`SHORTI_LAN_IFACE` override)
>   and persists the active tun name for reliable teardown. Without MSS clamping,
>   forwarded TCP through the smaller-MTU tunnel blackholes on large packets.
> - **`compose.yml` declares a Docker `healthcheck`** against `/health`, and the
>   unused `./config:/etc/shorti` mount was dropped.
> - **The health/metrics port defaults to `9798`, not `8080`.** Host networking
>   binds it directly on the labstation, so it was moved off the busy dev-app
>   `8080`. Override with `HEALTH_PORT`. Code blocks below still show `8080`.

**Goal:** Build a Docker Compose VPN gateway that connects to a Fortinet VPN via OpenConnect, maintains the tunnel with auto-reconnect, and masquerades traffic so any device routed through the labstation reaches the work network transparently.

**Architecture:** A single privileged container runs OpenConnect in the background, managed by a bash watchdog (`monitor.sh`) that detects tunnel drops and reconnects. On each successful connect, `routing.sh` installs iptables MASQUERADE rules so the host (and any device whose traffic Mikrotik routes to the labstation) egresses through the VPN tunnel. A tiny Python HTTP server on port 8080 exposes `/health` and `/metrics` for polling.

**Tech Stack:** Ubuntu 24.04, OpenConnect (Fortinet protocol), oathtool (TOTP, python3 fallback), iptables, bats-core (bash unit tests), Docker Compose v2, Python 3 (health endpoint)

---

## File Map

| File | Responsibility |
|------|---------------|
| `Dockerfile` | Production image: deps + scripts. Test target adds bats. |
| `compose.yml` | Runtime: NET_ADMIN cap, tun device, env_file, health port |
| `compose.test.yml` | Override: runs bats test suite, no restart policy |
| `.env.example` | Documented config template |
| `scripts/totp.sh` | Generate TOTP code from secret/cmd; sourceable + standalone |
| `scripts/connect.sh` | One-shot VPN connect + tunnel verification; sourceable + standalone |
| `scripts/routing.sh` | iptables MASQUERADE setup/teardown; sourceable + standalone |
| `scripts/monitor.sh` | Foreground watchdog loop — keeps container alive, calls connect + routing |
| `scripts/health.sh` | Python3 HTTP server: `/health` (JSON) + `/metrics` (plain text) |
| `scripts/entrypoint.sh` | Validate config, start health.sh in background, exec monitor.sh |
| `tests/test_totp.bats` | Unit tests for totp.sh |
| `tests/test_connect.bats` | Unit tests for connect.sh helper functions |
| `tests/test_routing.bats` | Unit tests for routing.sh helper functions |
| `tests/test_health.bats` | Unit tests for health.sh HTTP responses |
| `tests/test_entrypoint.bats` | Unit tests for config validation |
| `mikrotik/routing.rsc` | RouterOS script: add static routes for work CIDRs |
| `mikrotik/README.md` | Step-by-step Mikrotik setup guide |

---

## Task 1: Project Foundation — Dockerfile, compose files, bats setup

**Files:**
- Modify: `Dockerfile`
- Create: `compose.test.yml`
- Create: `tests/test_helper.bash`

- [ ] **Step 1: Update Dockerfile with multi-stage build (prod + test)**

Replace contents of `Dockerfile`:

```dockerfile
FROM ubuntu:24.04 AS base

RUN apt-get update && apt-get install -y \
    openconnect \
    oathtool \
    iproute2 \
    iptables \
    iputils-ping \
    curl \
    python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY scripts/ ./scripts/
RUN chmod +x ./scripts/*.sh

EXPOSE 8080
ENTRYPOINT ["./scripts/entrypoint.sh"]

# ── Test target ───────────────────────────────────────────────────────────────
FROM base AS test

RUN apt-get update && apt-get install -y bats && rm -rf /var/lib/apt/lists/*

COPY tests/ ./tests/
ENTRYPOINT ["bats", "--tap", "tests/"]
```

- [ ] **Step 2: Create compose.test.yml**

```yaml
services:
  test:
    build:
      context: .
      target: test
    environment:
      - SHORTI_SERVER=vpn.example.com
      - SHORTI_USERNAME=testuser
      - SHORTI_PASSWORD=testpass
      - SHORTI_TOTP_SECRET=JBSWY3DPEHPK3PXP
      - SHORTI_MAX_RETRIES=2
      - SHORTI_RETRY_DELAY=1
      - SHORTI_MONITOR_INTERVAL=5
```

- [ ] **Step 3: Create tests/test_helper.bash**

```bash
# Shared helpers loaded by all .bats test files

# Source a script without executing its main block
load_script() {
    local script="$1"
    # Trick BASH_SOURCE check: source under a different name via a wrapper
    # We use `source` directly since scripts guard with BASH_SOURCE[0] == $0
    source "/app/scripts/${script}"
}

# Create a temporary isolated environment
setup_env() {
    export SHORTI_LOG_FILE="/tmp/shorti-test-$$.log"
    export SHORTI_SERVER="vpn.example.com"
    export SHORTI_USERNAME="testuser"
    export SHORTI_PASSWORD="testpass"
    export SHORTI_TOTP_SECRET="JBSWY3DPEHPK3PXP"
    unset SHORTI_TOTP_CMD SHORTI_TOTP_SECRET_CMD SHORTI_PASSWORD_CMD SHORTI_PING_HOST
}

teardown_env() {
    rm -f "$SHORTI_LOG_FILE" 2>/dev/null || true
}
```

- [ ] **Step 4: Verify the test image builds**

```bash
cd ~/Projects/shorti
docker compose -f compose.test.yml build
```

Expected output ends with: `=> exporting to image` and no errors.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/shorti
git add Dockerfile compose.test.yml tests/test_helper.bash
git commit -m "feat: add test target to Dockerfile and bats test scaffold"
```

---

## Task 2: totp.sh — TOTP Code Generation

**Files:**
- Modify: `scripts/totp.sh`
- Create: `tests/test_totp.bats`

- [ ] **Step 1: Write the failing tests**

```bash
# tests/test_totp.bats
load 'test_helper'

setup() {
    setup_env
    load_script "totp.sh"
}

teardown() {
    teardown_env
}

@test "generate_totp uses SHORTI_TOTP_SECRET with oathtool" {
    export SHORTI_TOTP_SECRET="JBSWY3DPEHPK3PXP"
    unset SHORTI_TOTP_CMD SHORTI_TOTP_SECRET_CMD
    run generate_totp
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{6}$ ]]
}

@test "generate_totp uses SHORTI_TOTP_CMD output directly" {
    export SHORTI_TOTP_CMD="echo 123456"
    unset SHORTI_TOTP_SECRET SHORTI_TOTP_SECRET_CMD
    run generate_totp
    [ "$status" -eq 0 ]
    [ "$output" = "123456" ]
}

@test "generate_totp uses SHORTI_TOTP_SECRET_CMD to resolve secret" {
    export SHORTI_TOTP_SECRET_CMD="echo JBSWY3DPEHPK3PXP"
    unset SHORTI_TOTP_SECRET SHORTI_TOTP_CMD
    run generate_totp
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{6}$ ]]
}

@test "generate_totp SHORTI_TOTP_CMD takes priority over SHORTI_TOTP_SECRET" {
    export SHORTI_TOTP_CMD="echo 999999"
    export SHORTI_TOTP_SECRET="JBSWY3DPEHPK3PXP"
    run generate_totp
    [ "$status" -eq 0 ]
    [ "$output" = "999999" ]
}

@test "generate_totp fails with no config" {
    unset SHORTI_TOTP_SECRET SHORTI_TOTP_CMD SHORTI_TOTP_SECRET_CMD
    run generate_totp
    [ "$status" -ne 0 ]
}

@test "generate_totp fails when SHORTI_TOTP_CMD returns empty string" {
    export SHORTI_TOTP_CMD="echo ''"
    unset SHORTI_TOTP_SECRET SHORTI_TOTP_SECRET_CMD
    run generate_totp
    [ "$status" -ne 0 ]
}

@test "generate_from_secret produces 6-digit code" {
    run generate_from_secret "JBSWY3DPEHPK3PXP"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{6}$ ]]
}

@test "otp_remaining_seconds returns value between 1 and 30" {
    run otp_remaining_seconds
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
    [ "$output" -le 30 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd ~/Projects/shorti
docker compose -f compose.test.yml run --rm test bats --tap tests/test_totp.bats
```

Expected: all tests fail with `not found` or similar errors.

- [ ] **Step 3: Implement scripts/totp.sh**

```bash
#!/bin/bash
# totp.sh — Generate a TOTP code
# Sourceable: functions available after `source scripts/totp.sh`
# Standalone: prints OTP to stdout when executed directly
set -euo pipefail

_shorti_log_totp() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] totp: $*" \
        | tee -a "${SHORTI_LOG_FILE:-/var/log/shorti/shorti.log}" >&2
}

generate_from_secret() {
    local secret="$1"
    if command -v oathtool &>/dev/null; then
        oathtool --totp --base32 "$secret" 2>/dev/null
    else
        python3 - "$secret" <<'PYEOF'
import hmac, hashlib, struct, time, base64, sys
secret = sys.argv[1]
key = base64.b32decode(secret, casefold=True)
msg = struct.pack('>Q', int(time.time()) // 30)
h = hmac.new(key, msg, hashlib.sha1).digest()
o = h[-1] & 0x0F
code = (struct.unpack('>I', h[o:o+4])[0] & 0x7FFFFFFF) % 1000000
print(f'{code:06d}')
PYEOF
    fi
}

generate_totp() {
    local otp=""

    if [[ -n "${SHORTI_TOTP_CMD:-}" ]]; then
        otp="$(eval "$SHORTI_TOTP_CMD" 2>/dev/null)" || true
    elif [[ -n "${SHORTI_TOTP_SECRET_CMD:-}" ]]; then
        local secret
        secret="$(eval "$SHORTI_TOTP_SECRET_CMD" 2>/dev/null)" || true
        [[ -n "$secret" ]] && otp="$(generate_from_secret "$secret")" || true
    elif [[ -n "${SHORTI_TOTP_SECRET:-}" ]]; then
        otp="$(generate_from_secret "$SHORTI_TOTP_SECRET")" || true
    else
        _shorti_log_totp "ERROR" "No TOTP configuration (set SHORTI_TOTP_SECRET, SHORTI_TOTP_SECRET_CMD, or SHORTI_TOTP_CMD)"
        return 1
    fi

    if [[ -z "$otp" || ${#otp} -lt 6 ]]; then
        _shorti_log_totp "ERROR" "Failed to generate OTP (got: '${otp}')"
        return 1
    fi

    echo "$otp"
}

otp_remaining_seconds() {
    echo $(( 30 - ($(date +%s) % 30) ))
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    generate_totp
fi
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
docker compose -f compose.test.yml run --rm test bats --tap tests/test_totp.bats
```

Expected: `ok 1 - generate_totp uses SHORTI_TOTP_SECRET with oathtool` ... all 8 tests pass.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/shorti
git add scripts/totp.sh tests/test_totp.bats
git commit -m "feat: implement totp.sh with oathtool/python3 fallback"
```

---

## Task 3: connect.sh — VPN Connection

**Files:**
- Modify: `scripts/connect.sh`
- Create: `tests/test_connect.bats`

- [ ] **Step 1: Write the failing tests**

```bash
# tests/test_connect.bats
load 'test_helper'

setup() {
    setup_env
    load_script "totp.sh"
    load_script "connect.sh"
    export PIDFILE="/tmp/shorti-test-openconnect-$$.pid"
}

teardown() {
    teardown_env
    rm -f "$PIDFILE"
}

@test "get_password returns SHORTI_PASSWORD when set" {
    export SHORTI_PASSWORD="mysecret"
    unset SHORTI_PASSWORD_CMD
    run get_password
    [ "$status" -eq 0 ]
    [ "$output" = "mysecret" ]
}

@test "get_password uses SHORTI_PASSWORD_CMD over SHORTI_PASSWORD" {
    export SHORTI_PASSWORD_CMD="echo fromcmd"
    export SHORTI_PASSWORD="ignored"
    run get_password
    [ "$status" -eq 0 ]
    [ "$output" = "fromcmd" ]
}

@test "get_password fails when neither is set" {
    unset SHORTI_PASSWORD SHORTI_PASSWORD_CMD
    run get_password
    [ "$status" -ne 0 ]
}

@test "verify_tunnel fails when no tun interface exists" {
    # In the test container there is no tun device
    run verify_tunnel
    [ "$status" -ne 0 ]
}

@test "verify_tunnel skips ping check when SHORTI_PING_HOST is unset" {
    unset SHORTI_PING_HOST
    # Simulate a tun interface by stubbing ip command
    ip() {
        if [[ "$*" == "tuntap show" ]]; then
            echo "tun0: tun persist"
            return 0
        fi
        command ip "$@"
    }
    export -f ip
    run verify_tunnel
    [ "$status" -eq 0 ]
}

@test "build_server_url prepends https when missing" {
    run build_server_url "vpn.example.com"
    [ "$status" -eq 0 ]
    [ "$output" = "https://vpn.example.com" ]
}

@test "build_server_url leaves https:// URLs unchanged" {
    run build_server_url "https://vpn.example.com"
    [ "$status" -eq 0 ]
    [ "$output" = "https://vpn.example.com" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
docker compose -f compose.test.yml run --rm test bats --tap tests/test_connect.bats
```

Expected: all tests fail with function not found errors.

- [ ] **Step 3: Implement scripts/connect.sh**

```bash
#!/bin/bash
# connect.sh — Establish OpenConnect VPN tunnel (Fortinet)
# Sourceable: vpn_connect, get_password, verify_tunnel, build_server_url
# Standalone: calls vpn_connect and exits with its status
set -euo pipefail

PIDFILE="${SHORTI_OPENCONNECT_PIDFILE:-/var/run/shorti-openconnect.pid}"

_log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] connect: $*" \
        | tee -a "${SHORTI_LOG_FILE:-/var/log/shorti/shorti.log}" >&2
}

get_password() {
    if [[ -n "${SHORTI_PASSWORD_CMD:-}" ]]; then
        local pw
        pw="$(eval "$SHORTI_PASSWORD_CMD" 2>/dev/null)" || true
        if [[ -z "$pw" ]]; then
            _log "ERROR" "SHORTI_PASSWORD_CMD returned empty"
            return 1
        fi
        echo "$pw"
    elif [[ -n "${SHORTI_PASSWORD:-}" ]]; then
        echo "$SHORTI_PASSWORD"
    else
        _log "ERROR" "No password configured (set SHORTI_PASSWORD or SHORTI_PASSWORD_CMD)"
        return 1
    fi
}

build_server_url() {
    local server="$1"
    if [[ "$server" != https://* ]]; then
        echo "https://$server"
    else
        echo "$server"
    fi
}

verify_tunnel() {
    if ! ip tuntap show 2>/dev/null | grep -q tun; then
        _log "ERROR" "No tun interface found"
        return 1
    fi
    if [[ -n "${SHORTI_PING_HOST:-}" ]]; then
        if ! ping -c 1 -W 3 "$SHORTI_PING_HOST" &>/dev/null; then
            _log "ERROR" "Ping to $SHORTI_PING_HOST failed — tunnel may be up but routing broken"
            return 1
        fi
    fi
    return 0
}

_wait_for_tunnel() {
    local tries=0
    while (( tries < 15 )); do
        ip tuntap show 2>/dev/null | grep -q tun && return 0
        sleep 1
        (( tries++ ))
    done
    return 1
}

vpn_connect() {
    # Source totp.sh if generate_totp isn't already defined
    if ! declare -f generate_totp &>/dev/null; then
        source "$(dirname "${BASH_SOURCE[0]}")/totp.sh"
    fi

    local password otp server_url
    password="$(get_password)"   || return 1
    otp="$(generate_totp)"       || return 1
    server_url="$(build_server_url "${SHORTI_SERVER}")"

    local remaining
    remaining="$(otp_remaining_seconds)"
    _log "INFO" "OTP generated (${remaining}s remaining), connecting to $server_url as ${SHORTI_USERNAME}"

    local extra_flags=()
    [[ -n "${SHORTI_SERVERCERT:-}" ]] && extra_flags+=(--servercert "$SHORTI_SERVERCERT")
    [[ -n "${SHORTI_REALM:-}"      ]] && extra_flags+=(--authgroup  "$SHORTI_REALM")
    if [[ -n "${SHORTI_EXTRA_ARGS:-}" ]]; then
        read -ra _extra <<< "$SHORTI_EXTRA_ARGS"
        extra_flags+=("${_extra[@]}")
    fi

    openconnect \
        --protocol=fortinet \
        -u "$SHORTI_USERNAME" \
        --passwd-on-stdin \
        --pid-file "$PIDFILE" \
        --background \
        "${extra_flags[@]}" \
        "$server_url" \
        >> "${SHORTI_LOG_FILE:-/var/log/shorti/shorti.log}" 2>&1 <<EOF
$password
$otp
EOF
    local rc=$?

    if [[ $rc -ne 0 ]]; then
        _log "ERROR" "openconnect exited with code $rc"
        return 1
    fi

    if ! _wait_for_tunnel; then
        _log "ERROR" "Tun interface did not appear within 15 seconds"
        return 1
    fi

    if ! verify_tunnel; then
        return 1
    fi

    _log "INFO" "VPN connected (pid: $(<"$PIDFILE"))"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    vpn_connect
fi
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
docker compose -f compose.test.yml run --rm test bats --tap tests/test_connect.bats
```

Expected: all 7 tests pass. (`verify_tunnel fails when no tun interface exists` passes because tun does not exist in the test container.)

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/shorti
git add scripts/connect.sh tests/test_connect.bats
git commit -m "feat: implement connect.sh with password resolution and tunnel verification"
```

---

## Task 4: routing.sh — iptables NAT/Masquerade

**Files:**
- Modify: `scripts/routing.sh`
- Create: `tests/test_routing.bats`

- [ ] **Step 1: Write the failing tests**

```bash
# tests/test_routing.bats
load 'test_helper'

setup() {
    setup_env
    load_script "routing.sh"
}

teardown() {
    teardown_env
}

@test "get_tun_iface returns empty string when no tun exists" {
    # ip tuntap show returns nothing in the test container
    run get_tun_iface
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "get_tun_iface returns interface name when tun exists" {
    ip() {
        if [[ "$*" == "tuntap show" ]]; then
            printf 'tun0: tun persist\n'
            return 0
        fi
        command ip "$@"
    }
    export -f ip
    run get_tun_iface
    [ "$status" -eq 0 ]
    [ "$output" = "tun0" ]
}

@test "setup_routing fails when no tun interface is available" {
    run setup_routing
    [ "$status" -ne 0 ]
}

@test "teardown_routing succeeds even when no tun interface exists" {
    run teardown_routing
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
docker compose -f compose.test.yml run --rm test bats --tap tests/test_routing.bats
```

Expected: all fail with function not found.

- [ ] **Step 3: Implement scripts/routing.sh**

```bash
#!/bin/bash
# routing.sh — iptables MASQUERADE setup for VPN gateway mode
# Sourceable: setup_routing, teardown_routing, get_tun_iface
# Standalone: calls setup_routing
set -euo pipefail

_log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] routing: $*" \
        | tee -a "${SHORTI_LOG_FILE:-/var/log/shorti/shorti.log}" >&2
}

get_tun_iface() {
    ip tuntap show 2>/dev/null | awk -F: 'NR==1 && NF>0 {print $1}'
}

_flush_rules() {
    local tun="$1"
    iptables -t nat -D POSTROUTING -o "$tun" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i eth0  -o "$tun" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$tun" -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
}

setup_routing() {
    local tun
    tun="$(get_tun_iface)"

    if [[ -z "$tun" ]]; then
        _log "ERROR" "No tun interface found — cannot set up routing"
        return 1
    fi

    _log "INFO" "Configuring NAT masquerade on $tun"

    # Flush first to ensure idempotency
    _flush_rules "$tun"

    # Enable IP forwarding
    echo 1 > /proc/sys/net/ipv4/ip_forward

    # Masquerade all traffic leaving through the VPN tunnel
    iptables -t nat -A POSTROUTING -o "$tun" -j MASQUERADE
    # Forward inbound LAN traffic into the tunnel
    iptables -A FORWARD -i eth0  -o "$tun" -j ACCEPT
    # Allow established return traffic from the tunnel back to LAN
    iptables -A FORWARD -i "$tun" -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT

    _log "INFO" "Routing configured (masquerade via $tun)"
}

teardown_routing() {
    local tun
    tun="$(get_tun_iface 2>/dev/null)" || true

    if [[ -z "$tun" ]]; then
        return 0
    fi

    _flush_rules "$tun"
    _log "INFO" "Routing rules removed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_routing
fi
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
docker compose -f compose.test.yml run --rm test bats --tap tests/test_routing.bats
```

Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/shorti
git add scripts/routing.sh tests/test_routing.bats
git commit -m "feat: implement routing.sh with idempotent iptables MASQUERADE setup"
```

---

## Task 5: monitor.sh — Connection Watchdog

**Files:**
- Modify: `scripts/monitor.sh`
- Create: `tests/test_monitor.bats`

- [ ] **Step 1: Write the failing tests**

```bash
# tests/test_monitor.bats
load 'test_helper'

setup() {
    setup_env
    load_script "totp.sh"
    load_script "connect.sh"
    load_script "routing.sh"
    load_script "monitor.sh"
    export PIDFILE="/tmp/shorti-test-openconnect-$$.pid"
    export RECONNECT_COUNT_FILE="/tmp/shorti-reconnect-count-$$"
    echo "0" > "$RECONNECT_COUNT_FILE"
}

teardown() {
    teardown_env
    rm -f "$PIDFILE" "$RECONNECT_COUNT_FILE"
}

@test "is_connected returns failure when pidfile missing" {
    rm -f "$PIDFILE"
    run is_connected
    [ "$status" -ne 0 ]
}

@test "is_connected returns failure when pid is stale" {
    echo "99999999" > "$PIDFILE"
    run is_connected
    [ "$status" -ne 0 ]
}

@test "is_connected returns failure when tun interface is missing" {
    echo "$$" > "$PIDFILE"   # use current test PID so ps check passes
    run is_connected
    [ "$status" -ne 0 ]
}

@test "increment_reconnect_count increments from 0 to 1" {
    echo "0" > "$RECONNECT_COUNT_FILE"
    increment_reconnect_count
    run cat "$RECONNECT_COUNT_FILE"
    [ "$output" = "1" ]
}

@test "increment_reconnect_count increments from 4 to 5" {
    echo "4" > "$RECONNECT_COUNT_FILE"
    increment_reconnect_count
    run cat "$RECONNECT_COUNT_FILE"
    [ "$output" = "5" ]
}

@test "get_reconnect_count returns 0 when file missing" {
    rm -f "$RECONNECT_COUNT_FILE"
    run get_reconnect_count
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
docker compose -f compose.test.yml run --rm test bats --tap tests/test_monitor.bats
```

Expected: all fail with function not found.

- [ ] **Step 3: Implement scripts/monitor.sh**

```bash
#!/bin/bash
# monitor.sh — Foreground watchdog: connect, verify, reconnect on drop
# This is the main process of the container — it never exits voluntarily.
set -euo pipefail

PIDFILE="${SHORTI_OPENCONNECT_PIDFILE:-/var/run/shorti-openconnect.pid}"
RECONNECT_COUNT_FILE="/var/run/shorti-reconnect-count"
MONITOR_INTERVAL="${SHORTI_MONITOR_INTERVAL:-30}"
MAX_RETRIES="${SHORTI_MAX_RETRIES:-5}"
RETRY_DELAY="${SHORTI_RETRY_DELAY:-5}"
SHORTI_LOG_FILE="${SHORTI_LOG_FILE:-/var/log/shorti/shorti.log}"

_log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] monitor: $*" \
        | tee -a "$SHORTI_LOG_FILE" >&2
}

# Source sibling scripts (functions only, no execution)
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_script_dir/totp.sh"
source "$_script_dir/connect.sh"
source "$_script_dir/routing.sh"

get_reconnect_count() {
    [[ -f "$RECONNECT_COUNT_FILE" ]] && cat "$RECONNECT_COUNT_FILE" || echo 0
}

increment_reconnect_count() {
    local count
    count="$(get_reconnect_count)"
    echo $(( count + 1 )) > "$RECONNECT_COUNT_FILE"
}

is_connected() {
    if [[ ! -f "$PIDFILE" ]]; then return 1; fi

    local pid
    pid="$(<"$PIDFILE")"
    if ! ps -p "$pid" &>/dev/null; then return 1; fi

    if ! ip tuntap show 2>/dev/null | grep -q tun; then return 1; fi

    if [[ -n "${SHORTI_PING_HOST:-}" ]]; then
        ping -c 1 -W 3 "$SHORTI_PING_HOST" &>/dev/null || return 1
    fi

    return 0
}

connect_with_retry() {
    local attempt=1
    while (( attempt <= MAX_RETRIES )); do
        _log "INFO" "Connection attempt $attempt of $MAX_RETRIES"
        if vpn_connect && setup_routing; then
            return 0
        fi
        if (( attempt < MAX_RETRIES )); then
            _log "WARN" "Attempt $attempt failed — retrying in ${RETRY_DELAY}s"
            sleep "$RETRY_DELAY"
        fi
        (( attempt++ ))
    done
    _log "ERROR" "All $MAX_RETRIES attempts failed"
    return 1
}

_cleanup() {
    _log "INFO" "Shutting down"
    teardown_routing || true
    if [[ -f "$PIDFILE" ]]; then
        local pid="$(<"$PIDFILE")"
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -9 "$pid" 2>/dev/null || true
    fi
    exit 0
}

trap _cleanup SIGTERM SIGINT

# ── Main ─────────────────────────────────────────────────────────────────────

echo 0 > "$RECONNECT_COUNT_FILE"
mkdir -p "$(dirname "$SHORTI_LOG_FILE")"

_log "INFO" "shorti monitor starting (interval: ${MONITOR_INTERVAL}s, max-retries: ${MAX_RETRIES})"

connect_with_retry || _log "WARN" "Initial connect failed — will retry in background loop"

while true; do
    sleep "$MONITOR_INTERVAL"
    if ! is_connected; then
        _log "WARN" "Tunnel down — reconnecting (reconnects so far: $(get_reconnect_count))"
        increment_reconnect_count
        teardown_routing || true
        connect_with_retry || _log "ERROR" "Reconnect failed — will retry next cycle in ${MONITOR_INTERVAL}s"
    fi
done
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
docker compose -f compose.test.yml run --rm test bats --tap tests/test_monitor.bats
```

Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/shorti
git add scripts/monitor.sh tests/test_monitor.bats
git commit -m "feat: implement monitor.sh with retry loop and graceful shutdown"
```

---

## Task 6: health.sh — HTTP Health Endpoint

**Files:**
- Modify: `scripts/health.sh`
- Create: `tests/test_health.bats`

- [ ] **Step 1: Write the failing tests**

```bash
# tests/test_health.bats
load 'test_helper'

setup() {
    setup_env
    export PIDFILE="/tmp/shorti-test-openconnect-$$.pid"
    export RECONNECT_COUNT_FILE="/tmp/shorti-reconnect-count-$$"
    export HEALTH_PORT="18080"   # avoid port conflict with a running container
}

teardown() {
    teardown_env
    rm -f "$PIDFILE" "$RECONNECT_COUNT_FILE"
    # Kill any test health server
    pkill -f "health.sh" 2>/dev/null || true
}

@test "health endpoint returns 503 when VPN is disconnected" {
    rm -f "$PIDFILE"
    PIDFILE="$PIDFILE" RECONNECT_COUNT_FILE="$RECONNECT_COUNT_FILE" \
        HEALTH_PORT="$HEALTH_PORT" /app/scripts/health.sh &
    sleep 1
    run curl -s -o /dev/null -w "%{http_code}" "http://localhost:${HEALTH_PORT}/health"
    [ "$output" = "503" ]
}

@test "health endpoint returns JSON body" {
    rm -f "$PIDFILE"
    PIDFILE="$PIDFILE" RECONNECT_COUNT_FILE="$RECONNECT_COUNT_FILE" \
        HEALTH_PORT="$HEALTH_PORT" /app/scripts/health.sh &
    sleep 1
    run curl -s "http://localhost:${HEALTH_PORT}/health"
    [[ "$output" == *'"status"'* ]]
}

@test "metrics endpoint returns 200 with vpn_connected field" {
    rm -f "$PIDFILE"
    PIDFILE="$PIDFILE" RECONNECT_COUNT_FILE="$RECONNECT_COUNT_FILE" \
        HEALTH_PORT="$HEALTH_PORT" /app/scripts/health.sh &
    sleep 1
    run curl -s "http://localhost:${HEALTH_PORT}/metrics"
    [[ "$output" == *"vpn_connected="* ]]
}

@test "unknown path returns 404" {
    rm -f "$PIDFILE"
    PIDFILE="$PIDFILE" RECONNECT_COUNT_FILE="$RECONNECT_COUNT_FILE" \
        HEALTH_PORT="$HEALTH_PORT" /app/scripts/health.sh &
    sleep 1
    run curl -s -o /dev/null -w "%{http_code}" "http://localhost:${HEALTH_PORT}/unknown"
    [ "$output" = "404" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
docker compose -f compose.test.yml run --rm test bats --tap tests/test_health.bats
```

Expected: all fail (health.sh not implemented).

- [ ] **Step 3: Implement scripts/health.sh**

```bash
#!/usr/bin/env python3
"""
health.sh — Tiny HTTP server for shorti status
GET /health  -> 200 {"status":"connected"} or 503 {"status":"disconnected"}
GET /metrics -> 200 plain text metrics
"""
import http.server
import json
import os
import subprocess
import sys

PIDFILE          = os.environ.get("SHORTI_OPENCONNECT_PIDFILE", "/var/run/shorti-openconnect.pid")
RECONNECT_FILE   = os.environ.get("RECONNECT_COUNT_FILE",       "/var/run/shorti-reconnect-count")
PORT             = int(os.environ.get("HEALTH_PORT", "8080"))


def is_vpn_connected() -> bool:
    try:
        with open(PIDFILE) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)          # raises OSError if process doesn't exist
    except (FileNotFoundError, ValueError, OSError):
        return False
    result = subprocess.run(["ip", "tuntap", "show"], capture_output=True, text=True)
    return "tun" in result.stdout


def get_reconnect_count() -> int:
    try:
        with open(RECONNECT_FILE) as f:
            return int(f.read().strip())
    except (FileNotFoundError, ValueError):
        return 0


class HealthHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress default request logging

    def do_GET(self):
        connected = is_vpn_connected()

        if self.path == "/health":
            status   = "connected" if connected else "disconnected"
            code     = 200 if connected else 503
            body     = json.dumps({"status": status}).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", len(body))
            self.end_headers()
            self.wfile.write(body)

        elif self.path == "/metrics":
            lines = [
                f"vpn_connected={1 if connected else 0}",
                f"vpn_reconnect_total={get_reconnect_count()}",
            ]
            body = "\n".join(lines).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", len(body))
            self.end_headers()
            self.wfile.write(body)

        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()


if __name__ == "__main__":
    print(f"[shorti] health endpoint on :{PORT}", flush=True)
    server = http.server.HTTPServer(("", PORT), HealthHandler)
    server.serve_forever()
```

- [ ] **Step 4: Make health.sh executable**

```bash
chmod +x ~/Projects/shorti/scripts/health.sh
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
docker compose -f compose.test.yml run --rm test bats --tap tests/test_health.bats
```

Expected: all 4 tests pass.

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/shorti
git add scripts/health.sh tests/test_health.bats
git commit -m "feat: implement health.sh Python HTTP server with /health and /metrics"
```

---

## Task 7: entrypoint.sh — Container Orchestration

**Files:**
- Modify: `scripts/entrypoint.sh`
- Create: `tests/test_entrypoint.bats`

- [ ] **Step 1: Write the failing tests**

```bash
# tests/test_entrypoint.bats
load 'test_helper'

setup() {
    setup_env
    load_script "entrypoint.sh"
}

teardown() {
    teardown_env
}

@test "validate_config passes with all required vars set" {
    run validate_config
    [ "$status" -eq 0 ]
}

@test "validate_config fails when SHORTI_SERVER is missing" {
    unset SHORTI_SERVER
    run validate_config
    [ "$status" -ne 0 ]
    [[ "$output" == *"SHORTI_SERVER"* ]]
}

@test "validate_config fails when SHORTI_USERNAME is missing" {
    unset SHORTI_USERNAME
    run validate_config
    [ "$status" -ne 0 ]
    [[ "$output" == *"SHORTI_USERNAME"* ]]
}

@test "validate_config fails when no password source is set" {
    unset SHORTI_PASSWORD SHORTI_PASSWORD_CMD
    run validate_config
    [ "$status" -ne 0 ]
    [[ "$output" == *"password"* ]]
}

@test "validate_config fails when no TOTP source is set" {
    unset SHORTI_TOTP_SECRET SHORTI_TOTP_SECRET_CMD SHORTI_TOTP_CMD
    run validate_config
    [ "$status" -ne 0 ]
    [[ "$output" == *"TOTP"* ]]
}

@test "validate_config passes when SHORTI_PASSWORD_CMD is set instead of SHORTI_PASSWORD" {
    unset SHORTI_PASSWORD
    export SHORTI_PASSWORD_CMD="echo secret"
    run validate_config
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
docker compose -f compose.test.yml run --rm test bats --tap tests/test_entrypoint.bats
```

Expected: all fail with function not found.

- [ ] **Step 3: Implement scripts/entrypoint.sh**

```bash
#!/bin/bash
# entrypoint.sh — Container entry point
# 1. Validate required env vars
# 2. Start health.sh in background
# 3. exec monitor.sh (becomes PID 1's child that keeps container alive)
set -euo pipefail

export SHORTI_LOG_FILE="${SHORTI_LOG_FILE:-/var/log/shorti/shorti.log}"
mkdir -p "$(dirname "$SHORTI_LOG_FILE")"

_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] entrypoint: $*" \
        | tee -a "$SHORTI_LOG_FILE"
}

validate_config() {
    local missing=()

    [[ -z "${SHORTI_SERVER:-}"   ]] && missing+=("SHORTI_SERVER")
    [[ -z "${SHORTI_USERNAME:-}" ]] && missing+=("SHORTI_USERNAME")
    [[ -z "${SHORTI_PASSWORD:-}" && -z "${SHORTI_PASSWORD_CMD:-}" ]] \
        && missing+=("SHORTI_PASSWORD or SHORTI_PASSWORD_CMD (password source required)")
    [[ -z "${SHORTI_TOTP_SECRET:-}" && -z "${SHORTI_TOTP_SECRET_CMD:-}" && -z "${SHORTI_TOTP_CMD:-}" ]] \
        && missing+=("SHORTI_TOTP_SECRET / SHORTI_TOTP_SECRET_CMD / SHORTI_TOTP_CMD (TOTP source required)")

    if (( ${#missing[@]} > 0 )); then
        echo "[ERROR] entrypoint: Missing required environment variables:" >&2
        for var in "${missing[@]}"; do
            echo "  - $var" >&2
        done
        return 1
    fi
}

# Allow tests to source this file without running main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _log "shorti starting"
    validate_config || exit 1

    _log "Starting health endpoint on :${HEALTH_PORT:-8080}"
    /app/scripts/health.sh &

    _log "Handing over to monitor"
    exec /app/scripts/monitor.sh
fi
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
docker compose -f compose.test.yml run --rm test bats --tap tests/test_entrypoint.bats
```

Expected: all 6 tests pass.

- [ ] **Step 5: Run the full test suite**

```bash
docker compose -f compose.test.yml run --rm test
```

Expected: all tests across all test files pass with TAP output. Count should be 35.

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/shorti
git add scripts/entrypoint.sh tests/test_entrypoint.bats
git commit -m "feat: implement entrypoint.sh with config validation and service orchestration"
```

---

## Task 8: Integration Smoke Test

**Goal:** Verify the container builds, starts, and the health endpoint responds. This does **not** require a real VPN — it verifies the wiring is correct and the container doesn't crash on startup.

**Files:**
- Create: `tests/smoke.sh`

- [ ] **Step 1: Create tests/smoke.sh**

```bash
#!/bin/bash
# Smoke test: build and start the container, verify health endpoint responds.
# Requires Docker. Does NOT connect to any real VPN.
set -euo pipefail

COMPOSE="docker compose"
CONTAINER="shorti-vpn-smoke"

cleanup() {
    $COMPOSE -p shorti-smoke down --volumes 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Building image..."
docker build -t shorti:smoke . --quiet

echo "==> Starting container with dummy credentials (VPN will fail to connect — that is expected)..."
docker run -d \
    --name "$CONTAINER" \
    --cap-add NET_ADMIN \
    --device /dev/net/tun:/dev/net/tun \
    -e SHORTI_SERVER=vpn.invalid \
    -e SHORTI_USERNAME=test \
    -e SHORTI_PASSWORD=test \
    -e SHORTI_TOTP_SECRET=JBSWY3DPEHPK3PXP \
    -e SHORTI_MAX_RETRIES=1 \
    -e SHORTI_RETRY_DELAY=1 \
    -p 18080:8080 \
    shorti:smoke

echo "==> Waiting for health endpoint to come up..."
for i in $(seq 1 10); do
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:18080/health" | grep -qE "200|503"; then
        echo "==> Health endpoint responded (VPN disconnected as expected)"
        docker stop "$CONTAINER" && docker rm "$CONTAINER"
        echo "==> Smoke test PASSED"
        exit 0
    fi
    sleep 1
done

echo "==> Smoke test FAILED — health endpoint did not respond"
docker logs "$CONTAINER" || true
docker stop "$CONTAINER" && docker rm "$CONTAINER"
exit 1
```

- [ ] **Step 2: Make it executable and run it**

```bash
chmod +x ~/Projects/shorti/tests/smoke.sh
cd ~/Projects/shorti && bash tests/smoke.sh
```

Expected output:
```
==> Building image...
==> Starting container with dummy credentials (VPN will fail to connect — that is expected)...
==> Waiting for health endpoint to come up...
==> Health endpoint responded (VPN disconnected as expected)
==> Smoke test PASSED
```

- [ ] **Step 3: Commit**

```bash
cd ~/Projects/shorti
git add tests/smoke.sh
git commit -m "test: add integration smoke test for container startup and health endpoint"
```

---

## Task 9: Mikrotik Integration Docs

**Files:**
- Create: `mikrotik/routing.rsc`
- Modify: `mikrotik/README.md`

- [ ] **Step 1: Create mikrotik/routing.rsc**

```routeros
# mikrotik/routing.rsc
# RouterOS script: route work traffic through the shorti labstation gateway
#
# Assumptions:
#   - shorti labstation LAN IP: 192.168.1.50  (change to match yours)
#   - Work VPN subnets: 10.0.0.0/8            (change to match your VPN's pushed routes)
#   - Your LAN interface: bridge (or ether1 — adjust as needed)
#
# Apply with: /import file=routing.rsc

# Static route: send work subnet traffic to the labstation instead of the default gateway
/ip route
add dst-address=10.0.0.0/8 gateway=192.168.1.50 comment="shorti: work VPN via labstation"

# Optional: if your VPN uses a different subnet (e.g. 172.16.0.0/12) add another route:
# add dst-address=172.16.0.0/12 gateway=192.168.1.50 comment="shorti: work VPN via labstation"
```

- [ ] **Step 2: Overwrite mikrotik/README.md with the full guide**

```markdown
# Mikrotik Integration Guide

shorti runs on your labstation and connects to your work VPN. Mikrotik forwards
work-bound traffic to the labstation, which masquerades it through the tunnel.
Your other devices reach work resources without running their own VPN client.

## Architecture

```
Your device (192.168.1.x)
        |
        | traffic to 10.x.x.x
        v
   Mikrotik router
        | static route: 10.0.0.0/8 → 192.168.1.50
        v
   labstation (192.168.1.50)
   running shorti container
        | iptables MASQUERADE
        v
   work VPN tunnel (tun0)
        v
   work network (10.x.x.x)
```

## Prerequisites

1. shorti is running on your labstation:
   ```bash
   docker compose up -d
   curl http://192.168.1.50:8080/health
   # → {"status":"connected"}
   ```

2. You know your work VPN subnets (ask your network admin, or check `ip route` inside
   the running container: `docker exec shorti-vpn ip route`).

## Mikrotik Setup

### Option A: RouterOS script (Winbox terminal)

1. Copy `routing.rsc` to your Mikrotik (via Files menu or SCP).
2. Edit the file: replace `192.168.1.50` with your labstation's actual LAN IP,
   and `10.0.0.0/8` with your actual work VPN subnets.
3. Apply it:
   ```
   /import file=routing.rsc
   ```

### Option B: Manual via Winbox

IP → Routes → Add:
- Dst. Address: `10.0.0.0/8`  (your work subnet)
- Gateway: `192.168.1.50`     (your labstation IP)
- Comment: `shorti work VPN`

### Verify

From any device on your LAN, try reaching a work-only resource:
```bash
curl -I http://intranet.yourcompany.com
```
Or from Mikrotik terminal:
```
/tool traceroute 10.0.0.1
```
The first hop should be `192.168.1.50`.

## Health Monitoring (optional)

Mikrotik can poll the shorti health endpoint and alert or re-route on failure:

```routeros
/tool fetch url="http://192.168.1.50:8080/health" output=user
# Returns: {"status":"connected"} or {"status":"disconnected"}
```

You can use `/system scheduler` to run this periodically and send a notification
via `/tool e-mail` or `/tool sms` if the status is `disconnected`.
```

- [ ] **Step 3: Commit**

```bash
cd ~/Projects/shorti
git add mikrotik/routing.rsc mikrotik/README.md
git commit -m "docs: add Mikrotik routing script and integration guide"
```

---

## Self-Review

### Spec Coverage

| Requirement | Covered by |
|---|---|
| Ubuntu 24 / Linux | Task 1: `FROM ubuntu:24.04`, no macOS deps |
| OpenConnect Fortinet | Task 3: `connect.sh` `--protocol=fortinet` |
| TOTP generation | Task 2: `totp.sh` all 3 config methods |
| Auto-reconnect | Task 5: `monitor.sh` retry loop |
| Connection monitoring | Task 5: `monitor.sh` health check + reconnect |
| Transparent proxy / NAT | Task 4: `routing.sh` iptables MASQUERADE |
| Docker Compose | Task 1: `Dockerfile` + `compose.yml` |
| Mikrotik integration | Task 9: `mikrotik/routing.rsc` + `README.md` |
| Health endpoint | Task 6: `health.sh` `/health` + `/metrics` |
| Config validation | Task 7: `entrypoint.sh` `validate_config` |
| Smoke test | Task 8: `tests/smoke.sh` |

### Placeholder Scan

No TBD/TODO/placeholder text in implementation steps. All code blocks are complete.

### Type/Name Consistency

- `PIDFILE` — defined in `connect.sh`, used in `monitor.sh` (both use env var `SHORTI_OPENCONNECT_PIDFILE` defaulting to `/var/run/shorti-openconnect.pid`)
- `RECONNECT_COUNT_FILE` — defined and used consistently in `monitor.sh` and `health.sh`
- `generate_totp` / `generate_from_secret` / `otp_remaining_seconds` — defined in `totp.sh`, sourced in `connect.sh` and `monitor.sh`
- `vpn_connect` — defined in `connect.sh`, called in `monitor.sh`
- `setup_routing` / `teardown_routing` — defined in `routing.sh`, called in `monitor.sh`
- `validate_config` — defined and tested in `entrypoint.sh`
