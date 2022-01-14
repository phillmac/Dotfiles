#!/bin/bash

function public.root.hash () {
    curl -s --fail 'https://ipfs-admin.phillm.net/api/v0/files/stat?hash=true&arg=/Public' | jq -r .Hash
}

function public.pins.missing () {
    local public_hash
    local cid
    local _fpath
    local pin_timeout


    pin_timeout=${IPFS_PIN_TIMEOUT}

    public_hash=$(public.root.hash)

    ipfs.ls.recursive.files "${public_hash}" |  tee public.files.txt | cut -f 1 -d ' ' | sort -u > public.files.cids.txt

    ipfs pin ls --type=recursive | cut -f1 -d ' ' | sort -u > pins.txt

    while read -r cid _fpath
    do
        grep "${cid}" public.files.txt
        ipfs pin add --progress --timeout "${pin_timeout}" "${cid}"
    done < <(comm -23  public.files.cids.txt pins.txt )

}


function public.pins.monitor () {
    local public_hash
    local rlast
    local sleep_delay
    sleep_delay=${1:-$IPFS_PIN_SLEEP}


    while :
    do
        public_hash=$(public.root.hash)
        if ! check_lockout_time || [[ "${rlast}" == "${public_hash}" ]]
        then
            sleep "${sleep_delay}"
            continue
        fi
        echo "Pinning ${public_hash}" >&2
        public.pins.missing
        rlast=${public_hash}
        date
    done
}

export -f public.root.hash
export -f public.pins.missing
export -f public.pins.monitor