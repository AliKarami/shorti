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

    # --background forks immediately; rc is a fork-failure indicator only,
    # NOT an auth-success signal. Real success is verified by _wait_for_tunnel
    # + verify_tunnel below. Set SHORTI_PING_HOST for the strongest health check.
    if [[ $rc -ne 0 ]]; then
        _log "ERROR" "openconnect fork failed (exit code: $rc)"
        return 1
    fi

    if ! _wait_for_tunnel; then
        _log "ERROR" "Tun interface did not appear within 15 seconds — auth may have failed"
        return 1
    fi

    # Brief settle: give openconnect time to complete auth before we probe the tunnel.
    # A failed auth may briefly raise the tun interface before tearing it down.
    sleep 2

    if ! verify_tunnel; then
        return 1
    fi

    _log "INFO" "VPN connected (pid: $(<"$PIDFILE"))${SHORTI_PING_HOST:+ — ping host: $SHORTI_PING_HOST}"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    vpn_connect
fi
