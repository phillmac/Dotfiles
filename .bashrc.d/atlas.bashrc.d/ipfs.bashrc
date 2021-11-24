#!/bin/bash


IPFS_GET_BATCH_COUNT=10
IPFS_GET_TIMEOUT="3600s"
IPFS_PIN_TIMEOUT="24h"
IPFS_RESOLVE_TIMEOUT="15m"
IPFS_PIN_SLEEP="1h"

IPFS_HTTP_GATEWAY="192.168.35.51:8080"

function split-car ()
{
    ( cd /titan/E/ipfs-export/split && split -b 10M -a 3 --verbose "/titan/E/ipfs-export/${1}.car" "${1}.car." && rm -vf "/titan/E/ipfs-export/${1}.car" )
}

function upload-car ()
{
    ( cd /titan/E/ipfs-export/split && rclone move --verbose . --include "${1}.car.*" "ipfs-deep-archive:ipfs-deep-archive/${1}/" )
}


export IPFS_GET_BATCH_COUNT
export IPFS_GET_TIMEOUT
export IPFS_PIN_TIMEOUT
export IPFS_RESOLVE_TIMEOUT
export IPFS_PIN_SLEEP
export IPFS_HTTP_GATEWAY

export -f split-car
export -f upload-car