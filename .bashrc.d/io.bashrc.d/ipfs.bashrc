#!/bin/bash


IPFS_GET_BATCH_COUNT=10
IPFS_GET_TIMEOUT="3600s"
IPFS_PIN_TIMEOUT="4h"
IPFS_RESOLVE_TIMEOUT="15m"
IPFS_PIN_SLEEP="1h"

IPFS_PIN_ALLOWED_START="19:00"
IPFS_PIN_ALLOWED_FIN="02:00"

IPFS_HTTP_GATEWAY="http://192.168.20.33:8080"



function ipfs-wasabi ()
{
    IPFS_PATH='/home/phill/.ipfs-wasabi' ipfs-s3 "${@}"
}

function ipfs-backblaze ()
{
    IPFS_PATH='/home/phill/.ipfs-backblaze' ipfs-s3 "${@}"
}


# function ipfs-wasabi.public.pins.missing ()
# {
#     ipfs.ls.recursive.files "${1}" "${2}" | cut -d ' ' -f 1 | sort --unique > public.entries.txt
#     echo '' > ipfs-wasabi.pins.txt
#     ipfs-wasabi pin ls --type=recursive | sort --unique > ipfs-wasabi.pins.txt
#     while read -r pincid
#         do
#             echo "ipfs-wasabi missing item ${pincid}" >&2
#             ipfs-wasabi pin add \
#                 --progress \
#                 --timeout 2h \
#                 "${pincid}"
#             date
#     done < <( comm -23 public.entries.txt ipfs-wasabi.pins.txt)

# }

function ipfs-wasabi.public.pins.missing ()
{
    ipfs.ls.recursive.files "${1}" "${2}" | tee public.entries.txt | cut -d ' ' -f 1 | sort --unique > public.entries.cids.txt
    ipfs-wasabi pin ls --type=recursive | sort --unique > ipfs-wasabi.pins.txt
    comm -23 public.entries.cids.txt ipfs-wasabi.pins.txt > missing.cids.txt
    cids_count=$(wc -l < missing.cids.txt)
    ((progress=1))
    while read -r pincid
        do
            echo 'ipfs-wasabi missing item ' "$(grep "${pincid}" public.entries.txt) [${progress}/${cids_count}]" >&2
            ipfs-wasabi dag import < <(
                docker run \
                    --rm \
                    --net host \
                    curlimages/curl curl \
                        "https://external5.ddns.peelvalley.com.au/api/v0/dag/export?arg=${pincid}"
            )
            date
            ((progress+=1))
    done < <( )

}


export IPFS_GET_BATCH_COUNT
export IPFS_GET_TIMEOUT
export IPFS_PIN_TIMEOUT
export IPFS_RESOLVE_TIMEOUT
export IPFS_PIN_SLEEP
export IPFS_PIN_ALLOWED_START
export IPFS_PIN_ALLOWED_FIN
export IPFS_HTTP_GATEWAY
