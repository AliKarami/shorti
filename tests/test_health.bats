#!/usr/bin/env bats
load 'test_helper'

setup() {
    setup_env
    export SHORTI_OPENCONNECT_PIDFILE="/tmp/shorti-test-openconnect-$$.pid"
    export RECONNECT_COUNT_FILE="/tmp/shorti-reconnect-count-$$"
    export HEALTH_PORT="18080"
    export HEALTH_PID_FILE="/tmp/shorti-health-pid-$$.pid"
}

teardown() {
    teardown_env
    if [[ -f "$HEALTH_PID_FILE" ]]; then
        kill "$(<"$HEALTH_PID_FILE")" 2>/dev/null || true
        rm -f "$HEALTH_PID_FILE"
    fi
    rm -f "$SHORTI_OPENCONNECT_PIDFILE" "$RECONNECT_COUNT_FILE"
}

@test "health endpoint returns 503 when VPN is disconnected" {
    rm -f "$SHORTI_OPENCONNECT_PIDFILE"
    SHORTI_OPENCONNECT_PIDFILE="$SHORTI_OPENCONNECT_PIDFILE" RECONNECT_COUNT_FILE="$RECONNECT_COUNT_FILE" \
        HEALTH_PORT="$HEALTH_PORT" /app/scripts/health.sh &
    echo $! > "$HEALTH_PID_FILE"
    sleep 1
    run curl -s -o /dev/null -w "%{http_code}" "http://localhost:${HEALTH_PORT}/health"
    [ "$output" = "503" ]
}

@test "health endpoint returns JSON body" {
    rm -f "$SHORTI_OPENCONNECT_PIDFILE"
    SHORTI_OPENCONNECT_PIDFILE="$SHORTI_OPENCONNECT_PIDFILE" RECONNECT_COUNT_FILE="$RECONNECT_COUNT_FILE" \
        HEALTH_PORT="$HEALTH_PORT" /app/scripts/health.sh &
    echo $! > "$HEALTH_PID_FILE"
    sleep 1
    run curl -s "http://localhost:${HEALTH_PORT}/health"
    [[ "$output" == *'"status"'* ]]
}

@test "metrics endpoint returns 200 with vpn_connected field" {
    rm -f "$SHORTI_OPENCONNECT_PIDFILE"
    SHORTI_OPENCONNECT_PIDFILE="$SHORTI_OPENCONNECT_PIDFILE" RECONNECT_COUNT_FILE="$RECONNECT_COUNT_FILE" \
        HEALTH_PORT="$HEALTH_PORT" /app/scripts/health.sh &
    echo $! > "$HEALTH_PID_FILE"
    sleep 1
    run curl -s "http://localhost:${HEALTH_PORT}/metrics"
    [[ "$output" == *"vpn_connected="* ]]
}

@test "unknown path returns 404" {
    rm -f "$SHORTI_OPENCONNECT_PIDFILE"
    SHORTI_OPENCONNECT_PIDFILE="$SHORTI_OPENCONNECT_PIDFILE" RECONNECT_COUNT_FILE="$RECONNECT_COUNT_FILE" \
        HEALTH_PORT="$HEALTH_PORT" /app/scripts/health.sh &
    echo $! > "$HEALTH_PID_FILE"
    sleep 1
    run curl -s -o /dev/null -w "%{http_code}" "http://localhost:${HEALTH_PORT}/unknown"
    [ "$output" = "404" ]
}
