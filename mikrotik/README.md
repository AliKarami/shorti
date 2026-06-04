# Mikrotik Integration Guide

shorti runs on your gateway host and connects to a VPN. Mikrotik forwards
VPN-bound traffic to the gateway host, which masquerades it through the tunnel.
Your other devices reach resources behind the VPN without running their own VPN
client.

> **Networking model:** the shorti container runs with `network_mode: host`
> (see `compose.yml`). The VPN `tun0` interface, the kernel routes openconnect
> installs, IP forwarding, and the iptables MASQUERADE/MSS rules all live in the
> **host's** network namespace. That is what makes the gateway host's own LAN IP
> (`192.168.1.50` below) a valid gateway: traffic Mikrotik routes there arrives
> on the host and is forwarded straight into the tunnel. A bridge-networked
> container would trap the tunnel in its own namespace and the gateway path
> would never see that traffic.

## Architecture

```
Your device (192.168.1.x)
        |
        | traffic to 10.x.x.x
        v
   Mikrotik router
        | static route: 10.0.0.0/8 → 192.168.1.50
        v
   gateway host (192.168.1.50)
   running shorti container
        | iptables MASQUERADE
        v
   VPN tunnel (tun0)
        v
   remote network (10.x.x.x)
```

## Prerequisites

1. shorti is running on your gateway host:
   ```bash
   docker compose up -d
   docker ps                       # STATUS shows (healthy) once the tunnel is up
   curl http://192.168.1.50:9798/health
   # → {"status":"connected"}   (HTTP 200)
   # → {"status":"disconnected"} (HTTP 503 — VPN is still connecting or has dropped)
   ```
   The container has a Docker healthcheck wired to `/health`, so `docker ps`
   reflects the live tunnel state without needing to curl.

2. You know your VPN's pushed subnets (ask your network admin, or check `ip route`
   inside the running container after it connects: `docker exec shorti-vpn ip route`).

## Mikrotik Setup

### Option A: RouterOS script (Winbox terminal)

1. Copy `routing.rsc` to your Mikrotik (via Files menu or SCP).
   > **Note:** Place the file in the **root** of the Files view (not a subfolder).
   > If you upload to a subfolder, use the full path: `/import file=shorti/routing.rsc`
2. Edit the file: replace `192.168.1.50` with the gateway host's actual LAN IP,
   and `10.0.0.0/8` with your actual VPN subnets.
3. Apply it:
   ```
   /import file=routing.rsc
   ```

### Option B: Manual via Winbox

IP → Routes → Add:
- Dst. Address: `10.0.0.0/8`  (your VPN subnet)
- Gateway: `192.168.1.50`     (your gateway host IP)
- Comment: `shorti VPN`

### Verify

From any device on your LAN, try reaching a resource that's only routable over
the VPN:
```bash
curl -I http://intranet.example.com
```
Or from Mikrotik terminal:
```
/tool traceroute 10.0.0.1
```
The first hop should be `192.168.1.50`.

## Health Monitoring (optional)

Mikrotik can poll the shorti health endpoint and alert or re-route on failure:

```routeros
/tool fetch url="http://192.168.1.50:9798/health" output=user
# Returns: {"status":"connected"} or {"status":"disconnected"}
```

```routeros
# Example: check every 5 minutes, log the result
/system scheduler
add interval=5m name="shorti-health" on-event="/tool fetch url=\"http://192.168.1.50:9798/health\" output=user" start-time=startup
```

You can use `/system scheduler` to run this periodically and send a notification
via `/tool e-mail` or `/tool sms` if the status is `disconnected`.
