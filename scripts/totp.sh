#!/bin/bash
# totp.sh — Generate a TOTP code
# Sourceable: functions available after `source scripts/totp.sh`
# Standalone: prints OTP to stdout when executed directly
set -euo pipefail

_shorti_log_totp() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] totp: $*" \
        | tee -a "${SHORTI_LOG_FILE:-/var/log/shorti/shorti.log}" >&2
}

generate_from_secret() {
    local secret="$1"
    if command -v oathtool &>/dev/null; then
        oathtool --totp --base32 "$secret" 2>/dev/null
    else
        python3 - "$secret" <<'PYEOF'
import hmac, hashlib, struct, time, base64, sys
secret = sys.argv[1]
key = base64.b32decode(secret, casefold=True)
msg = struct.pack('>Q', int(time.time()) // 30)
h = hmac.new(key, msg, hashlib.sha1).digest()
o = h[-1] & 0x0F
code = (struct.unpack('>I', h[o:o+4])[0] & 0x7FFFFFFF) % 1000000
print(f'{code:06d}')
PYEOF
    fi
}

generate_totp() {
    local otp=""

    # SHORTI_TOTP_CMD and SHORTI_TOTP_SECRET_CMD are intentionally evaluated as shell
    # commands — they are expected to be operator-configured strings (e.g. "op read ...")
    # sourced from the trusted .env file. Do not expose these to untrusted input.
    if [[ -n "${SHORTI_TOTP_CMD:-}" ]]; then
        otp="$(eval "$SHORTI_TOTP_CMD" 2>/dev/null)" || true
    elif [[ -n "${SHORTI_TOTP_SECRET_CMD:-}" ]]; then
        local secret
        secret="$(eval "$SHORTI_TOTP_SECRET_CMD" 2>/dev/null)" || true
        [[ -n "$secret" ]] && otp="$(generate_from_secret "$secret")" || true
    elif [[ -n "${SHORTI_TOTP_SECRET:-}" ]]; then
        otp="$(generate_from_secret "$SHORTI_TOTP_SECRET")" || true
    else
        _shorti_log_totp "ERROR" "No TOTP configuration (set SHORTI_TOTP_SECRET, SHORTI_TOTP_SECRET_CMD, or SHORTI_TOTP_CMD)"
        return 1
    fi

    if [[ ! "$otp" =~ ^[0-9]{6}$ ]]; then
        _shorti_log_totp "ERROR" "Failed to generate OTP (got: '${otp}')"
        return 1
    fi

    echo "$otp"
}

otp_remaining_seconds() {
    echo $(( 30 - ($(date +%s) % 30) ))
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    generate_totp
fi
