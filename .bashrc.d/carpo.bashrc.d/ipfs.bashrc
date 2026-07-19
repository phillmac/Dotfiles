#!/bin/bash


IPFS_HTTP_GATEWAY="192.168.50.51:8080"
IPFS_GET_BATCH_COUNT=10
IPFS_GET_TIMEOUT="3600s"
IPFS_PIN_TIMEOUT="3h"
IPFS_RESOLVE_TIMEOUT="15m"
IPFS_PIN_SLEEP="1h"
PUBLIC_CIDS_FILE="/mimas/C/Users/phill/Documents/public cids.txt"

export IPFS_HTTP_GATEWAY
export IPFS_GET_BATCH_COUNT
export IPFS_GET_TIMEOUT
export IPFS_PIN_TIMEOUT
export IPFS_RESOLVE_TIMEOUT
export IPFS_PIN_SLEEP
export PUBLIC_CIDS_FILE

function split-car ()
{
    ( cd /data/ipfs-export/split && split -b 10M -a 4 --verbose "/data/ipfs-export/${1}.car" "${1}.car." && rm -vf "/data/ipfs-export/${1}.car" )
}

function upload-car ()
{
    ( cd /data/ipfs-export/split && rclone move --verbose . --include "${1}.car.*" "ipfs-deep-archive:ipfs-deep-archive/${1}/" )
}

function export-split-car ()
{
    ( cd /data/ipfs-export/split && ipfs dag export -p "${1}" | split -b 10M -a 4 --verbose - "${1}.car." )
}

function ipfs.repo.gc () {
    local before
    local after

    before=$(df -h | grep '/data/ipfs_data')

    docker run --rm -v /data/ipfs_data:/data/ipfs ipfs/go-ipfs:v0.11.0 repo gc --stream-errors

    after=$( df -h | grep '/data/ipfs_data')

    echo "Before: ${before}"
    echo "After ${after}"

}

function carpo.public.pins.monitor () {
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
        if [[ -n "${public_hash}" ]]
        then
            ipfs name publish --key=public --lifetime=72h --allow-offline "${public_hash}"
        fi
        echo "$(date) Done" >&2
    done
}

function carpo.export.laptop.dag ()
{
    if [[ ! -p carpo.export.laptop.dag.queue  ]]
    then
        mkfifo carpo.export.laptop.dag.queue
    fi

    while read -r cid;
    do
        echo "$(date) - Exporting ${cid}"
        docker exec -i \
            phill-dev_ipfs_1 \
                ipfs dag import \
                    --pin-roots=false < <( docker run --rm \
            -v /fileservers/desktop-pstlv07/F/Data/ipfs:/data/ipfs \
            --entrypoint /usr/local/bin/ipfs \
            ipfs/go-ipfs:v0.8.0 \
                dag export -p "${cid}" )
        echo "$(date) - Done"
    done < <(tail -f carpo.export.laptop.dag.queue)
}

function rhea.export.laptop.dag ()
{
    if [[ ! -p rhea.export.laptop.dag.queue  ]]
    then
        mkfifo rhea.export.laptop.dag.queue
    fi

    while read -r cid;
    do
        echo "$(date) - Exporting ${cid}"
        while ! ssh ubuntu@192.99.21.37 'docker exec -i \
            phill-dev-ipfs-1 \
                ipfs dag import \
                    --pin-roots=false < <(mbuffer)' < <( docker run --rm \
            -v /fileservers/desktop-pstlv07/F/Data/ipfs:/data/ipfs \
            --entrypoint /usr/local/bin/ipfs \
            ipfs/go-ipfs:v0.8.0 \
                dag export --progress=false "${cid}" )
        do
            echo "$(date) - Failed ${cid}"
            sleep 300
            echo "$(date) - Retrying ${cid}"
        done
        echo "$(date) - Done"
    done < <(tail -f rhea.export.laptop.dag.queue)
}

function rhea.wasabi.pebble.export.laptop.dag ()
{
    local queue="rhea.wasabi.pebble.export.laptop.dag.queue"
    local script_dir
    script_dir="$(
        cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" &&
        pwd
    )" || return 1
    local exporter="${RHEA_WASABI_PEBBLE_EXPORT_LAPTOP_DAG_SYNC:-${script_dir}/rhea-wasabi-pebble-export-laptop-dag-sync}"
    local shutting_down=0
    trap 'shutting_down=1; return 130' INT
    trap 'shutting_down=1; return 143' TERM

    if [[ -e "$queue" && ! -p "$queue" ]]
    then
        echo "${queue} exists but is not a FIFO" >&2
        return 1
    fi

    if [[ ! -p "$queue" ]]
    then
        mkfifo -- "$queue" || return 1
    fi

    if [[ ! -x "$exporter" ]]
    then
        echo "Resolved synchronous exporter is not executable: ${exporter}" >&2
        return 1
    fi

    echo "$(date) - Waiting for CIDs on ${queue}"

    # Reopen the FIFO whenever the current writer closes it. The FIFO path stays
    # intact and usable while the shared synchronous exporter serializes actual
    # export/import pipelines with its flock lock.
    while true
    do
        while IFS= read -r cid
        do
            [[ -n "$cid" ]] || continue
            while (( shutting_down == 0 ))
            do
                "$exporter" "$cid"
                status=$?
                if (( status == 0 ))
                then
                    break
                fi
                if (( shutting_down != 0 ))
                then
                    return "$status"
                fi
                retry_delay="${IPFS_DAG_RETRY_DELAY:-300}"
                echo "$(date) - Exporter failed for ${cid} with status ${status}" >&2
                echo "$(date) - Retrying ${cid} in ${retry_delay} seconds" >&2
                sleep "$retry_delay" || return "$status"
            done
        done < "$queue"
    done
}


export -f split-car
export -f upload-car
export -f export-split-car