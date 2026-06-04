#!/bin/bash
# Smoke test: build and start the container, verify health endpoint responds.
# Does NOT require a real VPN — verifies container wiring only.
set -euo pipefail

CONTAINER="shorti-vpn-smoke"
PORT=18080

cleanup() {
    docker stop "$CONTAINER" 2>/dev/null || true
    docker rm   "$CONTAINER" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Building production image..."
docker build -t shorti:smoke --target base . --quiet

echo "==> Starting container with dummy credentials (VPN will fail to connect — expected)..."
docker run -d \
    --name "$CONTAINER" \
    --cap-add NET_ADMIN \
    --device /dev/net/tun:/dev/net/tun \
    -e SHORTI_SERVER=vpn.invalid \
    -e SHORTI_USERNAME=test \
    -e SHORTI_PASSWORD=test \
    -e SHORTI_TOTP_SECRET=JBSWY3DPEHPK3PXP \
    -e SHORTI_MAX_RETRIES=1 \
    -e SHORTI_RETRY_DELAY=1 \
    -p "${PORT}:8080" \
    shorti:smoke

echo "==> Waiting for health endpoint (up to 15s)..."
for i in $(seq 1 15); do
    code="$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${PORT}/health" 2>/dev/null || true)"
    if [[ "$code" == "200" || "$code" == "503" ]]; then
        echo "==> Health endpoint responded with HTTP $code (VPN disconnected as expected)"
        echo "==> Smoke test PASSED"
        exit 0
    fi
    sleep 1
done

echo "==> Smoke test FAILED — health endpoint did not respond within 15 seconds"
docker logs "$CONTAINER" || true
exit 1
