#!/bin/bash

function export-split-car ()
{
    ( cd /cygdrive/g/ipfs-export/split && ipfs dag export -p "${1}" | split -b 10M -a 3 --verbose - "${1}.car." )
}

IPFS_HTTP_GATEWAY="http://192.168.42.32:8080"
IPFS_PIN_TIMEOUT="24h"
IPFS_RESOLVE_TIMEOUT="15m"
IPFS_PIN_SLEEP="15m"
PUBLIC_CIDS_FILE="//192.168.50.53/c/Users/phill/Documents/public cids.txt"

export IPFS_HTTP_GATEWAY
export IPFS_PIN_TIMEOUT
export IPFS_RESOLVE_TIMEOUT
export IPFS_PIN_SLEEP
export PUBLIC_CIDS_FILE

export -f export-split-car