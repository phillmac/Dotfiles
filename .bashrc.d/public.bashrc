#!/bin/bash

function public.root.hash () {
    curl -s --fail 'https://ipfs-admin.phillm.net/api/v0/files/stat?hash=true&arg=/Public' | jq -r .Hash
}

function public.pins.missing.local () {
    local public_hash
    local entry
    local pincid


    public_hash=$(public.root.hash)

    ipfs.ls.recursive.files "${public_hash}"  | tee public.files.txt | cut -d ' ' -f 1 | sort --unique > public.files.cids.txt

    ipfs pin ls --type=recursive | cut -f1 -d ' ' | sort -u > pins.txt

    comm -23 public.files.cids.txt pins.txt > public.missing.cids.txt
    cids_count=$(wc -l < public.missing.cids.txt)
    ((progress=1))

    while read -r pincid
    do
        entry=$(grep "${pincid}" public.files.txt)
        echo "$(date)  Missing item ${entry} [${progress}/${cids_count}]" >&2
        ipfs pin add --progress --timeout "${IPFS_PIN_TIMEOUT}" "${pincid}"
        ((progress+=1))
    done < public.missing.cids.txt
}


function public.pins.monitor () {
    local public_hash
    local rlast
    local sleep_delay
    sleep_delay=${1:-$IPFS_PIN_SLEEP}


    while :
    do
        public_hash=$(public.root.hash)
        echo "$(date) rlast: '${rlast}' public_hash: '${public_hash}'" >&2
        if ! check_lockout_time || [[ "${rlast}" == "${public_hash}" ]]
        then
            echo "$(date) Waiting" >&2
            sleep "${sleep_delay}"
            continue
        fi
        echo "Pinning ${public_hash}" >&2
        public.pins.missing.local
        rlast=${public_hash}
        echo "$(date) Done" >&2
    done
}

function public.pins.monitor () {
    local public_hash
    local rlast
    local sleep_delay
    sleep_delay=${1:-$IPFS_PIN_SLEEP}

    while :
    do
        public_hash=$(public.root.hash)
        echo "$(date) rlast: '${rlast}' public_hash: '${public_hash}'" >&2
        if [[ "${rlast}" == "${public_hash}" ]]
        then
            echo "$(date) Waiting" >&2
            sleep "${sleep_delay}"
            continue
        fi
        echo "Pinning ${public_hash}" >&2
        public.pins.missing.local "${public_hash}"
        rlast=${public_hash}
        echo "$(date) Done" >&2
    done
}

function public.list.preload ()
{
    local cid
    cid=$( public.root.hash )
    echo  "Janus $(wc -l < <(IPFS_HTTP_GATEWAY=192.168.42.208:8080       ipfs.ls.recursive "${cid}" 2> /dev/null))"
    echo "Carpo  $(wc -l < <(IPFS_HTTP_GATEWAY=192.168.50.51:8080        ipfs.ls.recursive "${cid}" 2> /dev/null))"
    echo "Charon $(wc -l < <(IPFS_HTTP_GATEWAY=192.168.30.57:8080        ipfs.ls.recursive "${cid}" 2> /dev/null))"
    echo "Io     $(wc -l < <(IPFS_HTTP_GATEWAY=http://192.168.20.33:8080 ipfs.ls.recursive "${cid}" 2> /dev/null))"
    echo "Titan  $(wc -l < <(IPFS_HTTP_GATEWAY=192.168.35.51:8080        ipfs.ls.recursive "${cid}" 2> /dev/null))"
    echo "VPS1   $(wc -l < <(IPFS_HTTP_GATEWAY=https://vps1.phillm.net   ipfs.ls.recursive "${cid}" 2> /dev/null))"
    echo "VPS2   $(wc -l < <(IPFS_HTTP_GATEWAY=https://vps2.phillm.net   ipfs.ls.recursive "${cid}" 2> /dev/null))"
    echo "VPS3   $(wc -l < <(IPFS_HTTP_GATEWAY=https://vps3.phillm.net   ipfs.ls.recursive "${cid}" 2> /dev/null))"
    echo "$(date) Done"
}

export -f public.root.hash
export -f public.pins.missing.local
export -f public.pins.monitor
export -f public.list.preload
