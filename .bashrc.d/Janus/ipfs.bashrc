#!/bin/bash

function export-split-car ()
{
    ( cd /cygdrive/g/ipfs-export/split && ipfs dag export -p "${1}" | split -b 10M -a 3 --verbose - "${1}.car." )
}

IPFS_HTTP_GATEWAY="http://192.168.42.32:8080"

export IPFS_HTTP_GATEWAY

export -f export-split-car