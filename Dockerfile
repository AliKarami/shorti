FROM alpine:3.21 AS base

# bash            — scripts use bash arrays, BASH_SOURCE, declare -f, etc.
# openconnect     — Fortinet VPN tunnel (ships /etc/vpnc/vpnc-script for routing)
# oath-toolkit-oathtool — TOTP generation (totp.sh)
# iproute2        — `ip tuntap show` / route setup
# iptables        — MASQUERADE + FORWARD gateway rules (routing.sh)
# iputils-ping    — tunnel health probe (`ping -W`)
# ca-certificates — system CA bundle so openconnect can verify the server cert
#                   via system trust (otherwise --servercert pinning is required)
# curl            — healthcheck client
# python3         — health.sh HTTP server + totp.sh fallback
RUN apk add --no-cache \
    bash \
    openconnect \
    oath-toolkit-oathtool \
    iproute2 \
    iptables \
    iputils-ping \
    ca-certificates \
    curl \
    python3

WORKDIR /app
COPY scripts/ ./scripts/
RUN chmod +x ./scripts/*.sh

EXPOSE 9798
ENTRYPOINT ["./scripts/entrypoint.sh"]

# ── Test target ───────────────────────────────────────────────────────────────
FROM base AS test

RUN apk add --no-cache bats

COPY tests/ ./tests/
ENTRYPOINT ["bats", "--tap", "tests/"]
