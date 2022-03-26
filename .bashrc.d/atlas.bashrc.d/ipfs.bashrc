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
    ( cd /titan/E/ipfs-export && rclone move -vvv --checksum --include "${1}.car" .  "ipfs-deep-archive:ipfs-deep-archive/${1}/" )
}

function upload-split-car ()
{
    ( cd /titan/E/ipfs-export/split && rclone move -vvv --checksum  --include "${1}.car.*" . "ipfs-deep-archive:ipfs-deep-archive/${1}/" )
}

function export-split-car ()
{
    ( cd /titan/E/ipfs-export/split && ipfs dag export -p "${1}" | split -b 10M -a 3 --verbose - "${1}.car." )
}



export IPFS_GET_BATCH_COUNT
export IPFS_GET_TIMEOUT
export IPFS_PIN_TIMEOUT
export IPFS_RESOLVE_TIMEOUT
export IPFS_PIN_SLEEP
export IPFS_HTTP_GATEWAY

export -f split-car
export -f upload-car
export -f export-split-car