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

_TUN_STATE_FILE="/run/shorti/active_tun"

get_tun_iface() {
    ip tuntap show 2>/dev/null | awk -F: 'NR==1 && NF>0 {print $1}'
}

_get_lan_iface() {
    # Respect explicit override first
    if [[ -n "${SHORTI_LAN_IFACE:-}" ]]; then
        echo "$SHORTI_LAN_IFACE"
        return 0
    fi
    # Auto-detect: interface used for the default route
    local iface
    iface="$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')"
    if [[ -z "$iface" ]]; then
        echo "eth0"  # last resort fallback
    else
        echo "$iface"
    fi
}

_flush_rules() {
    local tun="$1" lan="$2"
    iptables -t nat -D POSTROUTING -o "$tun" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i "$lan"  -o "$tun" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$tun" -o "$lan" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -t mangle -D FORWARD -o "$tun" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
}

setup_routing() {
    local tun
    tun="$(get_tun_iface)"
    local lan
    lan="$(_get_lan_iface)"

    if [[ -z "$tun" ]]; then
        _log "ERROR" "No tun interface found — cannot set up routing"
        return 1
    fi

    _log "INFO" "Configuring NAT masquerade on $tun"

    # Flush first to ensure idempotency
    _flush_rules "$tun" "$lan"

    # Enable IP forwarding. Under host networking this proc entry belongs to the
    # host and is typically read-only from inside the container, so treat a write
    # failure as non-fatal and tell the operator to enable it on the host.
    if [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" != "1" ]]; then
        if ! echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null; then
            _log "WARN" "IP forwarding is off and could not be enabled from the container. Run on the host: sudo sysctl -w net.ipv4.ip_forward=1 (persist via /etc/sysctl.d/99-shorti.conf)"
        fi
    fi

    # Masquerade all traffic leaving through the VPN tunnel
    iptables -t nat -A POSTROUTING -o "$tun" -j MASQUERADE
    # Forward inbound LAN traffic into the tunnel
    iptables -A FORWARD -i "$lan"  -o "$tun" -j ACCEPT
    # Allow established return traffic from the tunnel back to LAN
    iptables -A FORWARD -i "$tun" -o "$lan" -m state --state RELATED,ESTABLISHED -j ACCEPT
    # Clamp TCP MSS to the tunnel's path MTU. Without this, forwarded TCP
    # connections blackhole on large packets (TLS handshakes stall mid-stream)
    # because the VPN MTU is smaller than the LAN's and PMTU discovery often fails.
    iptables -t mangle -A FORWARD -o "$tun" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

    _log "INFO" "Routing configured (masquerade + MSS clamp via $tun)"
    mkdir -p "$(dirname "$_TUN_STATE_FILE")"
    echo "$tun" > "$_TUN_STATE_FILE"
}

teardown_routing() {
    local tun
    # Prefer the persisted name so we can flush even after the interface is gone
    if [[ -f "$_TUN_STATE_FILE" ]]; then
        tun="$(<"$_TUN_STATE_FILE")"
        rm -f "$_TUN_STATE_FILE"
    else
        tun="$(get_tun_iface 2>/dev/null)" || true
    fi

    if [[ -z "$tun" ]]; then
        return 0
    fi

    local lan
    lan="$(_get_lan_iface)"
    _flush_rules "$tun" "$lan"
    _log "INFO" "Routing rules removed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_routing
fi
