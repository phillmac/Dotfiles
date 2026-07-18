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
    # Socket on carpo that forwards to the laptop's 127.0.0.1:5001.
    local laptop_socket="${HOME}/.var/run/ipfs-laptop-api.sock"

    # Existing socket on carpo that forwards to the IPFS daemon on rhea.
    local rhea_socket="${HOME}/.var/run/rhea-ipfs-wasabi.sock"

    local queue="rhea.wasabi.pebble.export.laptop.dag.queue"

    local source_image="${LAPTOP_IPFS_CLI_IMAGE:-ipfs/go-ipfs:v0.8.0}"
    local destination_image="${RHEA_IPFS_CLI_IMAGE:-ipfs/go-ipfs:v0.31.0}"

    local retry_delay="${IPFS_DAG_RETRY_DELAY:-300}"

    command -v docker >/dev/null 2>&1 || {
        echo "docker is not installed or not in PATH" >&2
        return 1
    }

    command -v mbuffer >/dev/null 2>&1 || {
        echo "mbuffer is not installed or not in PATH" >&2
        return 1
    }

    if [[ -e "$queue" && ! -p "$queue" ]]
    then
        echo "${queue} exists but is not a FIFO" >&2
        return 1
    fi

    if [[ ! -p "$queue" ]]
    then
        mkfifo -- "$queue" || return 1
    fi

    echo "$(date) - Waiting for CIDs on ${queue}"
    echo "$(date) - Export source: ${laptop_socket}"
    echo "$(date) - Import destination: ${rhea_socket}"

    # Reopen the FIFO whenever the current writer closes it. This keeps the
    # worker alive without needing tail -f.
    while true
    do
        while IFS= read -r cid
        do
            # Ignore blank queue entries.
            [[ -n "$cid" ]] || continue

            echo "$(date) - Exporting ${cid} from laptop and importing to rhea"

            while true
            do
                if [[ ! -S "$laptop_socket" ]]
                then
                    echo "$(date) - Laptop IPFS socket is unavailable: ${laptop_socket}" >&2
                    echo "$(date) - Retrying ${cid} in ${retry_delay} seconds" >&2
                    sleep "$retry_delay"
                    continue
                fi

                if [[ ! -S "$rhea_socket" ]]
                then
                    echo "$(date) - Rhea IPFS socket is unavailable: ${rhea_socket}" >&2
                    echo "$(date) - Retrying ${cid} in ${retry_delay} seconds" >&2
                    sleep "$retry_delay"
                    continue
                fi

                if (
                    set -o pipefail

                    docker run --rm \
                        --log-driver none \
                        --mount \
                            "type=bind,src=${laptop_socket},dst=/run/ipfs-laptop-api.sock" \
                        --entrypoint /usr/local/bin/ipfs \
                        "$source_image" \
                        --api=/unix/run/ipfs-laptop-api.sock \
                        dag export \
                            --progress=false \
                            "$cid" \
                    |
                    mbuffer -e \
                    |
                    docker run --rm -i \
                        --log-driver none \
                        --mount \
                            "type=bind,src=${rhea_socket},dst=/run/rhea-ipfs-wasabi.sock" \
                        --entrypoint /usr/local/bin/ipfs \
                        "$destination_image" \
                        --api=/unix/run/rhea-ipfs-wasabi.sock \
                        dag import \
                            --pin-roots=false \
                            --allow-big-block
                )
                then
                    echo "$(date) - Done ${cid}"
                    break
                fi

                echo "$(date) - Failed ${cid}" >&2
                echo "$(date) - Retrying in ${retry_delay} seconds" >&2
                sleep "$retry_delay"
            done
        done < "$queue"
    done
}


export -f split-car
export -f upload-car
export -f export-split-car