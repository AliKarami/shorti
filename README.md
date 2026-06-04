# shorti

A Dockerized **Fortinet VPN gateway** for a home labstation. shorti connects to a
work VPN via [OpenConnect](https://www.infradead.org/openconnect/), handles
password + TOTP authentication, keeps the tunnel alive with an auto-reconnect
watchdog, and masquerades traffic so any device on your LAN can reach work
resources — without running its own VPN client.

It's the Linux/server counterpart to [`morti`](https://github.com/AliKarami/morti),
which does the same job interactively on macOS.

## How it works

```
Your device (192.168.1.x)
        │  traffic to 10.x.x.x (work subnet)
        ▼
   Mikrotik router
        │  static route: 10.0.0.0/8 → 192.168.1.50
        ▼
   labstation (192.168.1.50)
   running shorti  ── host network mode ──┐
        │  iptables MASQUERADE + MSS clamp │
        ▼                                  │
   work VPN tunnel (tun0) ─────────────────┘
        ▼
   work network (10.x.x.x)
```

A single privileged container runs OpenConnect in the background, supervised by a
bash watchdog (`monitor.sh`) that detects tunnel drops and reconnects. On each
successful connect, `routing.sh` installs `iptables` MASQUERADE rules (plus a TCP
MSS clamp for the tunnel's smaller MTU) so the labstation forwards LAN traffic
through the tunnel. A tiny Python HTTP server exposes `/health` and `/metrics` for
polling.

The container runs with **`network_mode: host`** so the tunnel, routes, IP
forwarding, and NAT rules live in the host's network namespace — which is what
makes the labstation's own IP a valid gateway for Mikrotik-routed traffic.

## Quick start

1. **Configure.** Copy the template and fill in your VPN details:

   ```bash
   cp .env.example .env
   $EDITOR .env
   ```

   At minimum you need `SHORTI_SERVER`, `SHORTI_USERNAME`, a password source, and
   a TOTP source (see [Configuration](#configuration)).

2. **Run.**

   ```bash
   docker compose up -d
   docker ps                          # STATUS shows (healthy) once the tunnel is up
   curl http://localhost:9798/health  # → {"status":"connected"}
   ```

3. **Route traffic.** Point your Mikrotik (or any router) at the labstation for
   your work subnets — see [`mikrotik/README.md`](mikrotik/README.md).

## Configuration

All configuration is via environment variables in `.env`.

### Required

| Variable | Description |
|----------|-------------|
| `SHORTI_SERVER` | VPN server hostname (e.g. `vpn.yourcompany.com`) |
| `SHORTI_USERNAME` | Your VPN username |
| **Password** — set one of: | |
| `SHORTI_PASSWORD` | Password as a literal value |
| `SHORTI_PASSWORD_CMD` | Command that prints the password (e.g. a secret manager) |
| **TOTP** — set one of (priority: CMD → SECRET_CMD → SECRET): | |
| `SHORTI_TOTP_CMD` | Command that prints a ready 6-digit code |
| `SHORTI_TOTP_SECRET_CMD` | Command that prints the base32 TOTP secret |
| `SHORTI_TOTP_SECRET` | Base32 TOTP secret as a literal value |

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `SHORTI_SERVERCERT` | — | Pin the server certificate (`pin-sha256:…`) |
| `SHORTI_REALM` | — | OpenConnect authgroup / realm |
| `SHORTI_EXTRA_ARGS` | — | Extra flags passed to `openconnect` (e.g. `--no-dtls`) |
| `SHORTI_PING_HOST` | — | Host to ping through the tunnel as a connectivity check (recommended) |
| `SHORTI_LAN_IFACE` | auto | LAN interface for forwarding (auto-detected from the default route) |
| `HEALTH_PORT` | `9798` | Port for the `/health` and `/metrics` endpoints |
| `SHORTI_MAX_RETRIES` | `5` | Connection attempts before giving up a cycle |
| `SHORTI_RETRY_DELAY` | `5` | Seconds between retries |
| `SHORTI_MONITOR_INTERVAL` | `30` | Seconds between tunnel health checks |

> Secrets stay local — `.env` is gitignored and never leaves the machine.

## Endpoints

| Path | Response |
|------|----------|
| `GET /health` | `200 {"status":"connected"}` or `503 {"status":"disconnected"}` |
| `GET /metrics` | `200` plain text: `vpn_connected=0\|1`, `vpn_reconnect_total=<n>` |

## Development

The full test suite runs in a container — no real VPN required:

```bash
docker compose -f compose.test.yml run --rm test   # 35 bats unit tests
bash tests/smoke.sh                                 # build + boot + health check
```

Tests are written with [bats-core](https://github.com/bats-core/bats-core). Each
script under `scripts/` is sourceable (functions only) and standalone, so its
helpers can be unit-tested in isolation.

| File | Responsibility |
|------|----------------|
| `scripts/entrypoint.sh` | Validate config, start health server, exec the monitor |
| `scripts/monitor.sh` | Watchdog loop: connect, verify, reconnect on drop |
| `scripts/connect.sh` | One-shot OpenConnect connect + tunnel verification |
| `scripts/totp.sh` | TOTP generation (oathtool, python3 fallback) |
| `scripts/routing.sh` | iptables MASQUERADE + MSS clamp setup/teardown |
| `scripts/health.sh` | Python HTTP server for `/health` and `/metrics` |

## Requirements

- A Linux host with Docker + Docker Compose v2
- `/dev/net/tun` available and the `NET_ADMIN` capability (granted in `compose.yml`)
- A router (e.g. Mikrotik) to route work subnets at the labstation — optional if
  you only want the gateway on the host itself

## License

MIT
