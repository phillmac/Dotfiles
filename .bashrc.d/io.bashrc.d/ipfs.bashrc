#!/bin/bash


IPFS_GET_BATCH_COUNT=10
IPFS_GET_TIMEOUT="3600s"
IPFS_PIN_TIMEOUT="4h"
IPFS_RESOLVE_TIMEOUT="15m"
IPFS_PIN_SLEEP="1h"

IPFS_PIN_ALLOWED_START="19:00"
IPFS_PIN_ALLOWED_FIN="02:00"

IPFS_HTTP_GATEWAY="192.168.20.33:8080"


function io.ipfs.preload ()
{
    docker exec -i phill-dev_ipfs_1 ipfs dag export "${@}"  | ssh -p 35681 vps1.phillm.net docker exec -i phill-dev_ipfs_1 ipfs dag import --pin-roots=false &
    docker exec -i phill-dev_ipfs_1 ipfs dag export "${@}"  | ssh -p 35681 vps2.phillm.net docker exec -i phill-dev_ipfs_1 ipfs dag import --pin-roots=false &
    docker exec -i phill-dev_ipfs_1 ipfs dag export "${@}"  | ssh -p 35681 vps3.phillm.net docker exec -i phill-dev_ipfs_1 ipfs dag import --pin-roots=false &
    docker exec -i phill-dev_ipfs_1 ipfs dag export "${@}" | mbuffer | ./ipfs-s3 dag import --pin-roots=false
}

export IPFS_GET_BATCH_COUNT
export IPFS_GET_TIMEOUT
export IPFS_PIN_TIMEOUT
export IPFS_RESOLVE_TIMEOUT
export IPFS_PIN_SLEEP
export IPFS_PIN_ALLOWED_START
export IPFS_PIN_ALLOWED_FIN
export IPFS_HTTP_GATEWAY

export -f io.ipfs.preload