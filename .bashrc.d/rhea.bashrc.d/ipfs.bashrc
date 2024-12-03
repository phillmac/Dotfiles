#!/bin/bash


IPFS_GET_BATCH_COUNT=10
IPFS_GET_TIMEOUT="3600s"
IPFS_PIN_TIMEOUT="4h"
IPFS_RESOLVE_TIMEOUT="15m"
IPFS_PIN_SLEEP="1h"

# IPFS_PIN_ALLOWED_START="19:00"
# IPFS_PIN_ALLOWED_FIN="02:00"

IPFS_HTTP_GATEWAY="127.0.0.2:8080"
# PUBLIC_DAG_EXPORT_GATEWAY="http://192.227.67.212:8080"
# PHONE_DAG_EXPORT_GATEWAY="http://external7.ddns.peelvalley.com.au:8080"
# ARCHIVE_DAG_EXPORT_GATEWAY="http://external7.ddns.peelvalley.com.au:8080"

export IPFS_GET_BATCH_COUNT
export IPFS_GET_TIMEOUT
export IPFS_PIN_TIMEOUT
export IPFS_RESOLVE_TIMEOUT
export IPFS_PIN_SLEEP
# export IPFS_PIN_ALLOWED_START
# export IPFS_PIN_ALLOWED_FIN
export IPFS_HTTP_GATEWAY
# export PUBLIC_DAG_EXPORT_GATEWAY
# export PHONE_DAG_EXPORT_GATEWAY
# export ARCHIVE_DAG_EXPORT_GATEWAY

# function archive.publish ()
# {
#     archive.ipns.update '' /ipns/staging.ipfs-archive.online
#     archive.ipns.update staging "$(ipfs files stat --hash /ipfs-archive.online)"
# }


function export-split-car ()
{
    ( cd /home/phill/ipfs-export-split && ipfs dag export -p "${1}" | split -b 10M -a 5 --verbose - "${1}.car." )

}

function mount_ipfs_wasabi ()
{
    rclone_mount -vvv mount \
        --allow-other \
        --transfers 10 \
        --attr-timeout 24h \
        --dir-cache-time 24h \
        --vfs-cache-mode full \
        --vfs-cache-max-age 24h \
        --vfs-write-back 1h \
        --vfs-fast-fingerprint \
        --cache-dir /data/ipfs-wasabi-cache \
            wasabi-ca-central-1:ipfs-remote-mount/rhea \
            /home/ubuntu/.ipfs-wasabi
}

function serve_ipfs_wasabi ()
{
    rclone_data -vvv serve s3 \
        --addr 'unix:///home/ubuntu/.var/run/ipfs-blockstore-va-2.socket' \
        --transfers 10 \
        --attr-timeout 24h \
        --dir-cache-time 24h \
        --vfs-cache-mode full \
        --vfs-cache-max-age 24h \
        --vfs-write-back 1h \
        --vfs-fast-fingerprint \
        --cache-dir /data/ipfs-wasabi-s3-cache \
        wasabi-us-east-2:ipfs-blockstore-va-2
}

function ipfs-wasabi ()
{
    IPFS_PATH='/home/ubuntu/.ipfs-wasabi' ipfs "${@}"
}

export -f ipfs-wasabi
