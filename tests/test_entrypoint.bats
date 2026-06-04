#!/usr/bin/env bats
load 'test_helper'

setup() {
    setup_env
    load_script "entrypoint.sh"
}

teardown() {
    teardown_env
}

@test "validate_config passes with all required vars set" {
    run validate_config
    [ "$status" -eq 0 ]
}

@test "validate_config fails when SHORTI_SERVER is missing" {
    unset SHORTI_SERVER
    run validate_config
    [ "$status" -ne 0 ]
    [[ "$output" == *"SHORTI_SERVER"* ]]
}

@test "validate_config fails when SHORTI_USERNAME is missing" {
    unset SHORTI_USERNAME
    run validate_config
    [ "$status" -ne 0 ]
    [[ "$output" == *"SHORTI_USERNAME"* ]]
}

@test "validate_config fails when no password source is set" {
    unset SHORTI_PASSWORD SHORTI_PASSWORD_CMD
    run validate_config
    [ "$status" -ne 0 ]
    [[ "$output" == *"password"* ]]
}

@test "validate_config fails when no TOTP source is set" {
    unset SHORTI_TOTP_SECRET SHORTI_TOTP_SECRET_CMD SHORTI_TOTP_CMD
    run validate_config
    [ "$status" -ne 0 ]
    [[ "$output" == *"TOTP"* ]]
}

@test "validate_config passes when SHORTI_PASSWORD_CMD is set instead of SHORTI_PASSWORD" {
    unset SHORTI_PASSWORD
    export SHORTI_PASSWORD_CMD="echo secret"
    run validate_config
    [ "$status" -eq 0 ]
}
