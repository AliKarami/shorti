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
   # → {"status":"connected"}   (HTTP 200)
   # → {"status":"disconnected"} (HTTP 503 — VPN is still connecting or has dropped)
   ```

2. You know your work VPN subnets (ask your network admin, or check `ip route` inside
   the running container after it connects: `docker exec shorti-vpn ip route`).

## Mikrotik Setup

### Option A: RouterOS script (Winbox terminal)

1. Copy `routing.rsc` to your Mikrotik (via Files menu or SCP).
   > **Note:** Place the file in the **root** of the Files view (not a subfolder).
   > If you upload to a subfolder, use the full path: `/import file=shorti/routing.rsc`
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

```routeros
# Example: check every 5 minutes, log the result
/system scheduler
add interval=5m name="shorti-health" on-event="/tool fetch url=\"http://192.168.1.50:8080/health\" output=user" start-time=startup
```

You can use `/system scheduler` to run this periodically and send a notification
via `/tool e-mail` or `/tool sms` if the status is `disconnected`.
