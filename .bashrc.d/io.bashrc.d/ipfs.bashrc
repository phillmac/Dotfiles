#!/bin/bash


IPFS_GET_BATCH_COUNT=10
IPFS_GET_TIMEOUT="3600s"
IPFS_PIN_TIMEOUT="4h"
IPFS_RESOLVE_TIMEOUT="15m"
IPFS_PIN_SLEEP="1h"

IPFS_PIN_ALLOWED_START="19:00"
IPFS_PIN_ALLOWED_FIN="02:00"

IPFS_HTTP_GATEWAY="http://192.168.20.33:8080"



function ipfs-wasabi ()
{
    IPFS_PATH='/home/phill/.ipfs-wasabi' ipfs-s3 "${@}"
}

function ipfs-backblaze ()
{
    IPFS_PATH='/home/phill/.ipfs-backblaze' ipfs-s3 "${@}"
}

function ipfs-wasabi.pins.ls.export ()
{
    ipfs-wasabi pin ls --type=recursive > ".ipfs-wasabi/$(date '+%Y_%m_%d_%H_%M_%S').pins.txt"
}

function ipfs-wasabi.files.ls.export ()
{
    files_root=$(ipfs-wasabi files stat --hash /)
    ipfs-wasabi ls --size=false "${files_root}" > ".ipfs-wasabi/$(date '+%Y_%m_%d_%H_%M_%S').files.txt"
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
            echo "$(date) ipfs-wasabi missing item $(grep ${pincid} public.files.txt) [${progress}/${cids_count}]" >&2
            ipfs-wasabi dag import < <(
                docker run \
                    --rm \
                    --net host \
                    --log-driver=none \
                    curlimages/curl curl \
                        "https://external5.ddns.peelvalley.com.au/api/v0/dag/export?arg=${pincid}"
            )
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
            echo '(date) ipfs-wasabi missing item ' "$(grep "${pincid}" archive.entries.txt) [${progress}/${cids_count}]" >&2
            ipfs-wasabi dag import < <(
                docker run \
                    --rm \
                    --net host \
                    --log-driver=none \
                    curlimages/curl curl \
                        "https://external5.ddns.peelvalley.com.au/api/v0/dag/export?arg=${pincid}"
            )
            ((progress+=1))
    done < wasabi.archive.missing.txt

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
        public_hash=$(public.root.hash)
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

function ipfs-backblaze.archive.pins.missing ()
{
    archive.entries "${1}" | sort --unique > archive.entries.cids.txt
    ipfs-backblaze pin ls --type=recursive | cut -d ' ' -f 1 | sort --unique > backblaze.pins.txt
    comm -23  archive.entries.cids.txt backblaze.pins.txt > backblaze.archive.missing.txt
    cids_count=$(wc -l < backblaze.archive.missing.txt)
    ((progress=1))
    while read -r pincid
        do

            pin_cid_entry=$(grep "${pincid}" archive.entries.txt)
            echo "$(date) - ipfs-backblaze missing item " "${pin_cid_entry} [${progress}/${cids_count}]" >&2
            while ! ipfs-backblaze dag import < <(
                docker run \
                    --rm \
                    --net host \
                    --log-driver=none \
                    curlimages/curl curl \
                        --user 'user:rrVfzbvRYTwNABCxJWjeHFu4' \
                        "https://rhea.phillm.net/api/v0/dag/export?arg=${pincid}"
            )
            do
                echo "$(date) - Retrying ${pin_cid_entry} [${progress}/${cids_count}]"
                sleep 300
            done

            ((progress+=1))
    done < backblaze.archive.missing.txt

}

function ipfs.export.backblaze.batch ()
{
    while read -r cid fpath
    do
        echo "$(date) Exporting ${cid} - ${fpath}"

        while ! ipfs-backblaze dag import < <(mbuffer < <(ipfs dag export --timeout=3h --progress=false "${cid}"))
        do
            echo "$(date) Retrying"
            sleep 30
        done
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
