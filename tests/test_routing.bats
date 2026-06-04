#!/usr/bin/env bats
load 'test_helper'

setup() {
    setup_env
    load_script "routing.sh"
}

teardown() {
    teardown_env
}

@test "get_tun_iface returns empty string when no tun exists" {
    # ip tuntap show returns nothing in the test container
    run get_tun_iface
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "get_tun_iface returns interface name when tun exists" {
    ip() {
        if [[ "$*" == "tuntap show" ]]; then
            printf 'tun0: tun persist\n'
            return 0
        fi
        command ip "$@"
    }
    export -f ip
    run get_tun_iface
    [ "$status" -eq 0 ]
    [ "$output" = "tun0" ]
}

@test "setup_routing fails when no tun interface is available" {
    run setup_routing
    [ "$status" -ne 0 ]
}

@test "teardown_routing succeeds even when no tun interface exists" {
    run teardown_routing
    [ "$status" -eq 0 ]
}
