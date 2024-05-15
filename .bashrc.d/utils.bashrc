#! /bin/bash
function sleep_until ()
{
    local current_epoch
    local target_epoch
    local sleep_seconds

    current_epoch=$(date +%s)
    target_epoch=$(date -d "${1}" +%s)
    sleep_seconds=$(( target_epoch - current_epoch ))

    sleep "${sleep_seconds}"
}