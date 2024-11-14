#! /bin/bash
function sleep_until ()
{
    local current_epoch
    local target_epoch
    local sleep_seconds

    current_epoch=$(date +%s)
    target_epoch=$(date -d "${1}" +%s)
    sleep_seconds=$(( target_epoch - current_epoch ))

    if (( sleep_seconds < 1));
    then
        echo "Invalid sleep duration ${sleep_seconds} seconds" >&2
        return 1
    fi

    echo "Sleeping for ${sleep_seconds} seconds" >&2

    sleep "${sleep_seconds}"
}

export -f sleep_until