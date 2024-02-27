#!/bin/bash


IPFS_HTTP_GATEWAY="http://192.168.20.7:8080"
IPFS_GET_BATCH_COUNT=10
IPFS_GET_TIMEOUT="3600s"
IPFS_PIN_TIMEOUT="3h"
IPFS_RESOLVE_TIMEOUT="15m"
IPFS_PIN_SLEEP="1h"

export IPFS_HTTP_GATEWAY
export IPFS_GET_BATCH_COUNT
export IPFS_GET_TIMEOUT
export IPFS_PIN_TIMEOUT
export IPFS_RESOLVE_TIMEOUT
export IPFS_PIN_SLEEP

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


export -f split-car
export -f upload-car
export -f export-split-car