#!/bin/bash


IPFS_GET_BATCH_COUNT=10
IPFS_GET_TIMEOUT="3600s"
IPFS_PIN_TIMEOUT="4h"
IPFS_RESOLVE_TIMEOUT="15m"
IPFS_PIN_SLEEP="1h"

IPFS_PIN_ALLOWED_START="19:00"
IPFS_PIN_ALLOWED_FIN="02:00"

IPFS_HTTP_GATEWAY="127.0.0.2:8080"
# PUBLIC_DAG_EXPORT_GATEWAY="http://192.227.67.212:8080"
# PHONE_DAG_EXPORT_GATEWAY="http://external7.ddns.peelvalley.com.au:8080"
# ARCHIVE_DAG_EXPORT_GATEWAY="http://external7.ddns.peelvalley.com.au:8080"

export IPFS_GET_BATCH_COUNT
export IPFS_GET_TIMEOUT
export IPFS_PIN_TIMEOUT
export IPFS_RESOLVE_TIMEOUT
export IPFS_PIN_SLEEP
export IPFS_PIN_ALLOWED_START
export IPFS_PIN_ALLOWED_FIN
export IPFS_HTTP_GATEWAY
export PUBLIC_DAG_EXPORT_GATEWAY
export PHONE_DAG_EXPORT_GATEWAY
export ARCHIVE_DAG_EXPORT_GATEWAY



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
                date >&2
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

function phone.pin.add.local () {
    if [[ -n "${PHONE_DAG_EXPORT_GATEWAY}" ]]
    then
       while ! docker run \
                --rm \
                --net host \
                curlimages/curl curl --fail \
                    "${PHONE_DAG_EXPORT_GATEWAY}/${IPFS_API}/dag/export?arg=${1}" > "${1}"
        do
            date >&2
            sleep 30m
        done

        ipfs.dag.import < <( mbuffer < "${1}")
        rm -v "${1}"

    else
        _ipfs pin add --progress --timeout "${IPFS_PIN_TIMEOUT}" "${1}"
    fi
}

function ipfs.phone.pins.missing ()
{
    ssh -p 35681 192.227.67.212 cat cids/phone/cids.txt | sort --unique > phone.files.cids.txt
    ipfs pin ls --type=recursive | cut -d ' ' -f 1 | sort --unique > pins.txt
    comm -23 phone.files.cids.txt pins.txt > phone.missing.txt
    cids_count=$(wc -l < phone.missing.txt)
    ((progress=1))
    while read -r pincid
        do
            echo "$(date) ipfs missing item ${pincid} [${progress}/${cids_count}]" >&2

            phone.pin.add.local "${pincid}"
            rm -v "${pincid}"
            ((progress+=1))
    done < <(grep . phone.missing.txt)
}

function public.root.hash () {
    (
        set -eo pipefail
        docker run \
        --rm \
        --net host \
        curlimages/curl curl --fail -s https://oasiscraft.org/root-hash.json | jq -r .Hash
    )
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

function vps4.public.pins.monitor () {
    local public_hash
    local rlast
    local sleep_delay
    local pincid
    local _junk
    local entry
    local entrypath
    local fname

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
        public.cids.missing && \
        while read -r pincid
        do
            entry=$(grep "${pincid}" public.files.txt)
            echo "$(date) pinning $entry"
            while ! _ipfs pin add --progress --timeout=4h "${pincid}"
            do
                echo "$(date) Failed to pin ${entry}" >&2
                sleep 5m
            done

            IFS='/' read -r _junk entrypath <<< "${entry}"

            fname=$(basename "${entrypath}")
            dname=$(dirname "${entrypath}")

            echo "entrypath is ${entrypath}" >&2
            echo "fname is ${fname}" >&2
            echo "dname is ${dname}" >&2

            if _ipfs files ls "/Public/${entrypath}" > /dev/null 2>&1
            then
                echo "${fname} already exists in mfs" >&2
                continue
            fi

            if ! _ipfs files ls "/Public/${dname}" > /dev/null 2>&1
            then
                echo "Creating missing mfs dir '/Public/${dname}'" >&2
                _ipfs files mkdir -p "/Public/${dname}"
            fi

            echo "Copying /ipfs/{pincid} to /Public/${entrypath}" >&2
            _ipfs files cp "/ipfs/${pincid}" "/Public/${entrypath}"

        done < public.missing.cids.txt
        rlast=${public_hash}
        echo "$(date) Done" >&2
    done
}

