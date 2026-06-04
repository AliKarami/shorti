#!/usr/bin/env bats
load 'test_helper'

setup() {
    setup_env
    load_script "totp.sh"
    load_script "connect.sh"
    load_script "routing.sh"
    load_script "monitor.sh"
    export PIDFILE="/tmp/shorti-test-openconnect-$$.pid"
    export RECONNECT_COUNT_FILE="/tmp/shorti-reconnect-count-$$"
    echo "0" > "$RECONNECT_COUNT_FILE"
}

teardown() {
    teardown_env
    rm -f "$PIDFILE" "$RECONNECT_COUNT_FILE"
}

@test "is_connected returns failure when pidfile missing" {
    rm -f "$PIDFILE"
    run is_connected
    [ "$status" -ne 0 ]
}

@test "is_connected returns failure when pid is stale" {
    echo "99999999" > "$PIDFILE"
    run is_connected
    [ "$status" -ne 0 ]
}

@test "is_connected fails at the tun check with a live pid (regression: empty pidfile read)" {
    echo "$$" > "$PIDFILE"   # live pid so the pidfile + liveness checks pass
    run is_connected
    [ "$status" -ne 0 ]      # still fails: there's no tun interface in the test env
    # The failure must come from the TUN check — NOT a falsely-empty pidfile read.
    # `$(<file 2>/dev/null)` silently returns "" and would regress this to the
    # "pidfile empty/missing" branch, tearing down healthy tunnels every cycle.
    [[ "$output" == *"tun interface"* ]]
    [[ "$output" != *"pidfile empty"* ]]
}

@test "increment_reconnect_count increments from 0 to 1" {
    echo "0" > "$RECONNECT_COUNT_FILE"
    increment_reconnect_count
    run cat "$RECONNECT_COUNT_FILE"
    [ "$output" = "1" ]
}

@test "increment_reconnect_count increments from 4 to 5" {
    echo "4" > "$RECONNECT_COUNT_FILE"
    increment_reconnect_count
    run cat "$RECONNECT_COUNT_FILE"
    [ "$output" = "5" ]
}

@test "get_reconnect_count returns 0 when file missing" {
    rm -f "$RECONNECT_COUNT_FILE"
    run get_reconnect_count
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}
