#!/usr/bin/env bats
load 'test_helper'

setup() {
    setup_env
    load_script "totp.sh"
}

teardown() {
    teardown_env
}

@test "generate_totp uses SHORTI_TOTP_SECRET with oathtool" {
    export SHORTI_TOTP_SECRET="JBSWY3DPEHPK3PXP"
    unset SHORTI_TOTP_CMD SHORTI_TOTP_SECRET_CMD
    run generate_totp
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{6}$ ]]
}

@test "generate_totp uses SHORTI_TOTP_CMD output directly" {
    export SHORTI_TOTP_CMD="echo 123456"
    unset SHORTI_TOTP_SECRET SHORTI_TOTP_SECRET_CMD
    run generate_totp
    [ "$status" -eq 0 ]
    [ "$output" = "123456" ]
}

@test "generate_totp uses SHORTI_TOTP_SECRET_CMD to resolve secret" {
    export SHORTI_TOTP_SECRET_CMD="echo JBSWY3DPEHPK3PXP"
    unset SHORTI_TOTP_SECRET SHORTI_TOTP_CMD
    run generate_totp
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{6}$ ]]
}

@test "generate_totp SHORTI_TOTP_CMD takes priority over SHORTI_TOTP_SECRET" {
    export SHORTI_TOTP_CMD="echo 999999"
    export SHORTI_TOTP_SECRET="JBSWY3DPEHPK3PXP"
    run generate_totp
    [ "$status" -eq 0 ]
    [ "$output" = "999999" ]
}

@test "generate_totp fails with no config" {
    unset SHORTI_TOTP_SECRET SHORTI_TOTP_CMD SHORTI_TOTP_SECRET_CMD
    run generate_totp
    [ "$status" -ne 0 ]
}

@test "generate_totp fails when SHORTI_TOTP_CMD returns empty string" {
    export SHORTI_TOTP_CMD="echo ''"
    unset SHORTI_TOTP_SECRET SHORTI_TOTP_SECRET_CMD
    run generate_totp
    [ "$status" -ne 0 ]
}

@test "generate_from_secret produces 6-digit code" {
    run generate_from_secret "JBSWY3DPEHPK3PXP"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{6}$ ]]
}

@test "otp_remaining_seconds returns value between 1 and 30" {
    run otp_remaining_seconds
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
    [ "$output" -le 30 ]
}
