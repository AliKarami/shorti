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
