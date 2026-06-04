# Shared helpers loaded by all .bats test files

# Source a script without executing its main block
load_script() {
    local script="$1"
    # We use `source` directly since scripts guard with BASH_SOURCE[0] == $0
    source "/app/scripts/${script}"
}

# Create a temporary isolated environment
setup_env() {
    export SHORTI_LOG_FILE="/tmp/shorti-test-$$.log"
    export SHORTI_SERVER="vpn.example.com"
    export SHORTI_USERNAME="testuser"
    export SHORTI_PASSWORD="testpass"
    export SHORTI_TOTP_SECRET="JBSWY3DPEHPK3PXP"
    unset SHORTI_TOTP_CMD SHORTI_TOTP_SECRET_CMD SHORTI_PASSWORD_CMD SHORTI_PING_HOST
}

teardown_env() {
    rm -f "$SHORTI_LOG_FILE" 2>/dev/null || true
    unset SHORTI_LOG_FILE SHORTI_SERVER SHORTI_USERNAME SHORTI_PASSWORD \
          SHORTI_TOTP_SECRET SHORTI_TOTP_CMD SHORTI_TOTP_SECRET_CMD \
          SHORTI_PASSWORD_CMD SHORTI_PING_HOST
}
