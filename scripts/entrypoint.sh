#!/bin/bash
# entrypoint.sh — Container entry point
# 1. Validate required env vars
# 2. Start health.sh in background
# 3. exec monitor.sh (keeps container alive)
set -euo pipefail

export SHORTI_LOG_FILE="${SHORTI_LOG_FILE:-/var/log/shorti/shorti.log}"

_log() {
    mkdir -p "$(dirname "$SHORTI_LOG_FILE")" 2>/dev/null || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] entrypoint: $*" \
        | tee -a "$SHORTI_LOG_FILE"
}

validate_config() {
    local missing=()

    [[ -z "${SHORTI_SERVER:-}"   ]] && missing+=("SHORTI_SERVER")
    [[ -z "${SHORTI_USERNAME:-}" ]] && missing+=("SHORTI_USERNAME")
    [[ -z "${SHORTI_PASSWORD:-}" && -z "${SHORTI_PASSWORD_CMD:-}" ]] \
        && missing+=("SHORTI_PASSWORD or SHORTI_PASSWORD_CMD (password source required)")
    [[ -z "${SHORTI_TOTP_SECRET:-}" && -z "${SHORTI_TOTP_SECRET_CMD:-}" && -z "${SHORTI_TOTP_CMD:-}" ]] \
        && missing+=("SHORTI_TOTP_SECRET / SHORTI_TOTP_SECRET_CMD / SHORTI_TOTP_CMD (TOTP source required)")

    if (( ${#missing[@]} > 0 )); then
        echo "[ERROR] entrypoint: Missing required environment variables:" >&2
        for var in "${missing[@]}"; do
            echo "  - $var" >&2
        done
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    mkdir -p "$(dirname "$SHORTI_LOG_FILE")"
    _log "shorti starting"
    validate_config || exit 1

    _log "Starting health endpoint on :${HEALTH_PORT:-8080}"
    /app/scripts/health.sh &

    _log "Handing over to monitor"
    exec /app/scripts/monitor.sh
fi
