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

PIDFILE        = os.environ.get("SHORTI_OPENCONNECT_PIDFILE", "/var/run/shorti-openconnect.pid")
RECONNECT_FILE = os.environ.get("RECONNECT_COUNT_FILE", "/var/run/shorti-reconnect-count")
PORT           = int(os.environ.get("HEALTH_PORT", "8080"))


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
        try:
            connected = is_vpn_connected()

            if self.path == "/health":
                status = "connected" if connected else "disconnected"
                code   = 200 if connected else 503
                body   = json.dumps({"status": status}).encode()
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
                body = ("\n".join(lines) + "\n").encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", len(body))
                self.end_headers()
                self.wfile.write(body)

            else:
                self.send_response(404)
                self.send_header("Content-Length", 0)
                self.end_headers()

        except Exception:
            try:
                self.send_error(503, "Internal error")
            except Exception:
                pass


if __name__ == "__main__":
    print(f"[shorti] health endpoint on :{PORT}", flush=True)
    server = http.server.ThreadingHTTPServer(("", PORT), HealthHandler)
    server.serve_forever()
