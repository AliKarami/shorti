#!/usr/bin/env bats
load 'test_helper'

setup() {
    setup_env
    load_script "totp.sh"
    load_script "connect.sh"
    export PIDFILE="/tmp/shorti-test-openconnect-$$.pid"
}

teardown() {
    teardown_env
    rm -f "$PIDFILE"
}

@test "get_password returns SHORTI_PASSWORD when set" {
    export SHORTI_PASSWORD="mysecret"
    unset SHORTI_PASSWORD_CMD
    run get_password
    [ "$status" -eq 0 ]
    [ "$output" = "mysecret" ]
}

@test "get_password uses SHORTI_PASSWORD_CMD over SHORTI_PASSWORD" {
    export SHORTI_PASSWORD_CMD="echo fromcmd"
    export SHORTI_PASSWORD="ignored"
    run get_password
    [ "$status" -eq 0 ]
    [ "$output" = "fromcmd" ]
}

@test "get_password fails when neither is set" {
    unset SHORTI_PASSWORD SHORTI_PASSWORD_CMD
    run get_password
    [ "$status" -ne 0 ]
}

@test "verify_tunnel fails when no tun interface exists" {
    # In the test container there is no tun device
    run verify_tunnel
    [ "$status" -ne 0 ]
}

@test "verify_tunnel skips ping check when SHORTI_PING_HOST is unset" {
    unset SHORTI_PING_HOST
    # Simulate a tun interface by stubbing ip command
    ip() {
        if [[ "$*" == "tuntap show" ]]; then
            echo "tun0: tun persist"
            return 0
        fi
        command ip "$@"
    }
    export -f ip
    run verify_tunnel
    [ "$status" -eq 0 ]
}

@test "build_server_url prepends https when missing" {
    run build_server_url "vpn.example.com"
    [ "$status" -eq 0 ]
    [ "$output" = "https://vpn.example.com" ]
}

@test "build_server_url leaves https:// URLs unchanged" {
    run build_server_url "https://vpn.example.com"
    [ "$status" -eq 0 ]
    [ "$output" = "https://vpn.example.com" ]
}
