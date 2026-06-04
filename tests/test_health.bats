#!/usr/bin/env bats
load 'test_helper'

setup() {
    setup_env
    export PIDFILE="/tmp/shorti-test-openconnect-$$.pid"
    export RECONNECT_COUNT_FILE="/tmp/shorti-reconnect-count-$$"
    export HEALTH_PORT="18080"
}

teardown() {
    teardown_env
    rm -f "$PIDFILE" "$RECONNECT_COUNT_FILE"
    pkill -f "health.sh" 2>/dev/null || true
}

@test "health endpoint returns 503 when VPN is disconnected" {
    rm -f "$PIDFILE"
    PIDFILE="$PIDFILE" RECONNECT_COUNT_FILE="$RECONNECT_COUNT_FILE" \
        HEALTH_PORT="$HEALTH_PORT" /app/scripts/health.sh &
    sleep 1
    run curl -s -o /dev/null -w "%{http_code}" "http://localhost:${HEALTH_PORT}/health"
    [ "$output" = "503" ]
}

@test "health endpoint returns JSON body" {
    rm -f "$PIDFILE"
    PIDFILE="$PIDFILE" RECONNECT_COUNT_FILE="$RECONNECT_COUNT_FILE" \
        HEALTH_PORT="$HEALTH_PORT" /app/scripts/health.sh &
    sleep 1
    run curl -s "http://localhost:${HEALTH_PORT}/health"
    [[ "$output" == *'"status"'* ]]
}

@test "metrics endpoint returns 200 with vpn_connected field" {
    rm -f "$PIDFILE"
    PIDFILE="$PIDFILE" RECONNECT_COUNT_FILE="$RECONNECT_COUNT_FILE" \
        HEALTH_PORT="$HEALTH_PORT" /app/scripts/health.sh &
    sleep 1
    run curl -s "http://localhost:${HEALTH_PORT}/metrics"
    [[ "$output" == *"vpn_connected="* ]]
}

@test "unknown path returns 404" {
    rm -f "$PIDFILE"
    PIDFILE="$PIDFILE" RECONNECT_COUNT_FILE="$RECONNECT_COUNT_FILE" \
        HEALTH_PORT="$HEALTH_PORT" /app/scripts/health.sh &
    sleep 1
    run curl -s -o /dev/null -w "%{http_code}" "http://localhost:${HEALTH_PORT}/unknown"
    [ "$output" = "404" ]
}
