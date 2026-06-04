#!/bin/bash
# monitor.sh — Foreground watchdog: connect, verify, reconnect on drop
# This is the main process of the container — it never exits voluntarily.
set -euo pipefail

PIDFILE="${SHORTI_OPENCONNECT_PIDFILE:-/var/run/shorti-openconnect.pid}"
RECONNECT_COUNT_FILE="${RECONNECT_COUNT_FILE:-/var/run/shorti-reconnect-count}"
MONITOR_INTERVAL="${SHORTI_MONITOR_INTERVAL:-30}"
MAX_RETRIES="${SHORTI_MAX_RETRIES:-5}"
RETRY_DELAY="${SHORTI_RETRY_DELAY:-5}"
SHORTI_LOG_FILE="${SHORTI_LOG_FILE:-/var/log/shorti/shorti.log}"

_log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] monitor: $*" \
        | tee -a "$SHORTI_LOG_FILE" >&2
}

# Source sibling scripts (functions only, no execution — each guards with BASH_SOURCE)
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Only source siblings if not already loaded (e.g. during tests they're pre-loaded)
if ! declare -f generate_totp &>/dev/null; then
    source "$_script_dir/totp.sh"
fi
if ! declare -f vpn_connect &>/dev/null; then
    source "$_script_dir/connect.sh"
fi
if ! declare -f setup_routing &>/dev/null; then
    source "$_script_dir/routing.sh"
fi

get_reconnect_count() {
    [[ -f "$RECONNECT_COUNT_FILE" ]] && cat "$RECONNECT_COUNT_FILE" || echo 0
}

increment_reconnect_count() {
    local count
    count="$(get_reconnect_count)"
    echo $(( count + 1 )) > "$RECONNECT_COUNT_FILE"
}

is_connected() {
    local pid
    pid="$(<"$PIDFILE" 2>/dev/null)" || true
    if [[ -z "$pid" ]]; then return 1; fi
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
        if vpn_connect; then
            if setup_routing; then
                return 0
            else
                # VPN connected but routing failed — tear down before retry
                _log "WARN" "Routing setup failed — tearing down tunnel before retry"
                teardown_routing || true
                if [[ -f "$PIDFILE" ]]; then
                    local pid
                    pid="$(<"$PIDFILE" 2>/dev/null)" || true
                    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
                    rm -f "$PIDFILE"
                fi
            fi
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
        local pid
        pid="$(<"$PIDFILE" 2>/dev/null)" || true
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$PIDFILE"
    fi
    exit 0
}

trap _cleanup SIGTERM SIGINT

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # ── Main (only runs when executed directly, not when sourced) ────────────
    echo 0 > "$RECONNECT_COUNT_FILE"
    mkdir -p "$(dirname "$SHORTI_LOG_FILE")"

    _log "INFO" "shorti monitor starting (interval: ${MONITOR_INTERVAL}s, max-retries: ${MAX_RETRIES})"

    connect_with_retry || _log "WARN" "Initial connect failed — will retry in background loop"

    while true; do
        sleep "$MONITOR_INTERVAL" &
        wait $!
        if ! is_connected; then
            _log "WARN" "Tunnel down — reconnecting (reconnects so far: $(get_reconnect_count))"
            increment_reconnect_count
            teardown_routing || true
            connect_with_retry || _log "ERROR" "Reconnect failed — will retry next cycle in ${MONITOR_INTERVAL}s"
        fi
    done
fi
