#!/bin/bash


IPFS_GET_BATCH_COUNT=10
IPFS_GET_TIMEOUT="3600s"
IPFS_PIN_TIMEOUT="4h"
IPFS_RESOLVE_TIMEOUT="15m"
IPFS_PIN_SLEEP="1h"

IPFS_PIN_ALLOWED_START="19:00"
IPFS_PIN_ALLOWED_FIN="02:00"

IPFS_HTTP_GATEWAY="http://192.227.67.212:8080"



function ipfs-wasabi ()
{
    IPFS_PATH='/home/phill/.ipfs-wasabi' ipfs-s3 "${@}"
}

function ipfs-backblaze ()
{
    IPFS_PATH='/home/phill/.ipfs-backblaze' ipfs-s3 "${@}"
}


function ipfs-wasabi.public.pins.missing ()
{
    ipfs.ls.recursive.files "${1}" "${2}" | tee public.files.txt | cut -d ' ' -f 1 | sort --unique > public.files.cids.txt
    ipfs-wasabi pin ls --type=recursive | cut -d ' ' -f 1 | sort --unique > wasabi.pins.txt
    comm -23 public.files.cids.txt wasabi.pins.txt > wasabi.public.missing.txt
    cids_count=$(wc -l < wasabi.public.missing.txt)
    ((progress=1))
    while read -r pincid
        do
            echo "$(date) ipfs-wasabi missing item $(grep "${pincid}" public.files.txt) [${progress}/${cids_count}]" >&2

            while ! docker run \
                --rm \
                --net host \
                --log-driver none \
                curlimages/curl curl --fail \
                    "http://192.227.67.212:8080/api/v0/dag/export?arg=${pincid}" > "${pincid}"
            do
                echo $(date) >&2
                sleep 30m
            done
            ipfs-wasabi dag import < <( mbuffer < "${pincid}")
            rm -v "${pincid}"
            ((progress+=1))
    done < wasabi.public.missing.txt

}

function ipfs-wasabi.archive.pins.missing ()
{
    archive.entries "${1}" | sort --unique > archive.entries.cids.txt
    ipfs-wasabi pin ls --type=recursive | cut -d ' ' -f 1 | sort --unique > wasabi.pins.txt
    comm -23  archive.entries.cids.txt wasabi.pins.txt > wasabi.archive.missing.txt
    cids_count=$(wc -l < wasabi.archive.missing.txt)
    ((progress=1))
    while read -r pincid
        do
            echo "$(date) ipfs-wasabi missing item " "$(grep "${pincid}" archive.entries.txt) [${progress}/${cids_count}]" >&2
            while ! docker run \
                --rm \
                --net host \
                --log-driver none \
                curlimages/curl curl \
                    "https://external5.ddns.peelvalley.com.au/api/v0/dag/export?arg=${pincid}" > "${pincid}"
            do
                echo $(date) >&2
                sleep 30m
            done
            ipfs-wasabi dag import < <( mbuffer < "${pincid}")
            rm -v "${pincid}"
            ((progress+=1))
    done < wasabi.archive.missing.txt

}

function ipfs-wasabi.phone.pins.missing ()
{
    ssh -p 35681 192.227.67.212 cat cids/phone/cids.txt | sort --unique > phone.files.cids.txt
    ipfs-wasabi pin ls --type=recursive | cut -d ' ' -f 1 | sort --unique > wasabi.pins.txt
    comm -23 phone.files.cids.txt wasabi.pins.txt > wasabi.phone.missing.txt
    cids_count=$(wc -l < wasabi.phone.missing.txt)
    ((progress=1))
    while read -r pincid
        do
            echo "$(date) ipfs-wasabi missing item ${pincid} [${progress}/${cids_count}]" >&2

            while ! docker run \
                --rm \
                --net host \
                --log-driver none \
                curlimages/curl curl --fail \
                    "http://192.227.67.212:8080/api/v0/dag/export?arg=${pincid}" > "${pincid}"
            do
                echo $(date) >&2
                sleep 30m
            done
            ipfs-wasabi dag import < <( mbuffer < "${pincid}")
            rm -v "${pincid}"
            ((progress+=1))
    done < wasabi.phone.missing.txt
}

function public.root.hash () {
    docker run \
        --rm \
        --net host \
        curlimages/curl curl 'https://ipfs-admin.phillm.net/api/v0/files/stat?hash=true&arg=/Public' | jq -r .Hash
}


function ipfs-wasabi.public.pins.monitor () {
    local public_hash
    local rlast
    local sleep_delay
    sleep_delay=${1:-$IPFS_PIN_SLEEP}

    while :
    do
        public_hash=$(curl -s --fail https://oasiscraft.org/root-hash.json | jq -r '.Hash')
        echo "$(date) rlast: '${rlast}' public_hash: '${public_hash}'" >&2
        if [[ "${rlast}" == "${public_hash}" ]]
        then
            echo "$(date) Waiting" >&2
            sleep "${sleep_delay}"
            continue
        fi
        echo "Pinning ${public_hash}" >&2
        ipfs-wasabi.public.pins.missing "${public_hash}"
        rlast=${public_hash}
        echo "$(date) Done" >&2
    done
}

export IPFS_GET_BATCH_COUNT
export IPFS_GET_TIMEOUT
export IPFS_PIN_TIMEOUT
export IPFS_RESOLVE_TIMEOUT
export IPFS_PIN_SLEEP
export IPFS_PIN_ALLOWED_START
export IPFS_PIN_ALLOWED_FIN
export IPFS_HTTP_GATEWAY
