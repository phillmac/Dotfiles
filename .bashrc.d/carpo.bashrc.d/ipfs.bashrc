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


export -f split-car
export -f upload-car
export -f export-split-car