# shorti

A Dockerized **Fortinet VPN gateway** for a home server. shorti connects to a
VPN via [OpenConnect](https://www.infradead.org/openconnect/), handles password +
TOTP authentication, keeps the tunnel alive with an auto-reconnect watchdog, and
masquerades traffic so any device on your LAN can reach resources behind the VPN —
without running its own VPN client.

It's the Linux/server counterpart to [`morti`](https://github.com/arastu/morti),
which does the same job interactively on macOS.

## How it works

```
Your device (192.168.1.x)
        │  traffic to 10.x.x.x (VPN subnet)
        ▼
   Mikrotik router
        │  static route: 10.0.0.0/8 → 192.168.1.50
        ▼
   gateway host (192.168.1.50)
   running shorti  ── host network mode ──┐
        │  iptables MASQUERADE + MSS clamp │
        ▼                                  │
   VPN tunnel (tun0) ───────────────────────┘
        ▼
   remote network (10.x.x.x)
```

A single privileged container runs OpenConnect in the background, supervised by a
bash watchdog (`monitor.sh`) that detects tunnel drops and reconnects. On each
successful connect, `routing.sh` installs `iptables` MASQUERADE rules (plus a TCP
MSS clamp for the tunnel's smaller MTU) so the gateway host forwards LAN traffic
through the tunnel. A tiny Python HTTP server exposes `/health` and `/metrics` for
polling.

The container runs with **`network_mode: host`** so the tunnel, routes, IP
forwarding, and NAT rules live in the host's network namespace — which is what
makes the gateway host's own IP a valid gateway for Mikrotik-routed traffic.

## Quick start

0. **Enable IP forwarding on the host** (one-time). Because the container runs in
   host network mode, the kernel's forwarding setting belongs to the host and
   can't be set from Compose:

   ```bash
   echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-shorti.conf
   sudo sysctl --system
   ```

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

3. **Route traffic.** Point your Mikrotik (or any router) at the gateway host for
   the VPN's subnets — see [`mikrotik/README.md`](mikrotik/README.md).

## Configuration

All configuration is via environment variables in `.env`.

### Required

| Variable | Description |
|----------|-------------|
| `SHORTI_SERVER` | VPN server hostname (e.g. `vpn.example.com`) |
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

## Troubleshooting

**Connects, then reconnects every ~30s (new PID each time).** First check *why*
the watchdog thinks the tunnel is down — it logs the failing health check:

```bash
docker compose exec vpn tail -n 60 /var/log/shorti/shorti.log
```

- `health: pidfile empty/missing` while openconnect *is* running means the
  watchdog can't read its own pidfile. The classic cause is the bash gotcha
  `pid="$(<"$f" 2>/dev/null)"` — the extra redirection disables the `$(<file)`
  fast path and yields an **empty string every time**, so the check always fails.
  shorti reads it as `[[ -f "$f" ]] && pid="$(<"$f")"` instead.
- `health: openconnect (pid N) not running` while openconnect is actually alive
  means the liveness check itself is broken (e.g. using `ps -p`, which busybox on
  Alpine doesn't support — shorti uses the `kill -0` builtin instead).
- A genuine manual `openconnect` run that stays up while the daemon drops on the
  dot every `SHORTI_MONITOR_INTERVAL` is the tell-tale sign the watchdog is the
  culprit, not the tunnel — check the health-check messages above first.
- `health: ping <host> failed` means routing to `SHORTI_PING_HOST` is broken even
  though the tunnel is up — check the host route / `SHORTI_PING_HOST` is reachable
  through the VPN.

If instead the log shows openconnect *itself* dropping the data channel, the usual
cause with FortiGate is the **DTLS heartbeat**. If the log shows the data channel
on DTLS and an unrecognized heartbeat packet, like:

```
Configured as 10.x.x.x, with SSL disconnected and DTLS established
...
Unexpected pre-PPP packet header for encap 5.
< 0000:  00 13 47 46 74 79 70 65  00 68 65 61 72 74 62 65  |..GFtype.heartbe|
```

then openconnect (even the current v9.12) doesn't answer FortiGate's heartbeat on
the DTLS channel, so the server drops the session at its ~30s heartbeat timeout.
Keep the data channel on TLS instead:

```bash
# in .env, then: docker compose up -d --force-recreate
SHORTI_EXTRA_ARGS=--no-dtls
```

Other knobs in `SHORTI_EXTRA_ARGS` if the log points elsewhere:
`--no-http-keepalive`, or an explicit MTU like `-m 1300`.

> The `Cannot open "/proc/sys/net/ipv4/route/flush": Read-only file system` lines
> from the vpnc-script are harmless (Docker mounts `/proc/sys` read-only) and are
> not the cause of disconnects.

**`docker logs` shows nothing about the disconnect.** Fixed — openconnect now runs
in the foreground (backgrounded by the supervisor) so its full output, including
disconnect reasons, is written to `/var/log/shorti/shorti.log` instead of syslog.

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
- IP forwarding enabled on the host: `net.ipv4.ip_forward=1` (see Quick start
  step 0 — under host networking this must be set on the host, not in Compose)
- `/dev/net/tun` available and the `NET_ADMIN` capability (granted in `compose.yml`)
- A router (e.g. Mikrotik) to route the VPN's subnets at the gateway host — optional
  if you only want the gateway on the host itself

## License

MIT
