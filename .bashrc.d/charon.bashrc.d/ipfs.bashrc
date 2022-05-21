#!/bin/bash


IPFS_GET_BATCH_COUNT=10
IPFS_GET_TIMEOUT="3600s"
IPFS_PIN_TIMEOUT="24h"
IPFS_RESOLVE_TIMEOUT="15m"
IPFS_PIN_SLEEP="1h"

IPFS_PIN_ALLOWED_START="23:59"
IPFS_PIN_ALLOWED_FIN="06:00"

IPFS_HTTP_GATEWAY="127.0.0.1:8080"
PUBLIC_DAG_EXPORT_GATEWAY=http://external7.ddns.peelvalley.com.au:8080


# function charon.ipfs.preload ()
# {
#     local tmppipe

#     tmppipe=$(mktemp -u)
#     mkfifo -m 600 "${tmppipe}"
#     echo "Created ${tmppipe}"

#     tmux split ssh -p 35681 io.phillm.net 'mbuffer -I 40471 | docker exec -i phill-dev_ipfs_1 ipfs dag import --pin-roots=false'
#     tmux select-layout even-vertical
#     tmux split mbuffer -t -i "${tmppipe}" \
#         -O 192.168.20.51:40471
#     tmux select-layout even-vertical
#     echo "Exporting ${*}"
#     ipfs dag export -p "${@}" > "${tmppipe}"
# }

function export-split-car ()
{
    (
        cd /selene/Sync/Upload/ipfs-export && ipfs dag export -p "${1}" | split -b 10M -a 3 --verbose - "${1}.car."
        while read -r -d $'\0' fname
        do
            mv "${fname}" /selene/Sync/Upload/Titan_E/split
            sleep 300
        done < <(
            find . -name "${1}" -print0
        )
    )
}

function export-split-car-files ()
{
    ipfs.ls.recursive.files "${1}" | while read -r  cid _info; do export-split-car "${cid}"; done
}

function export-split-car-dirs ()
{
    ipfs.ls.recursive.dirs "${1}" | while read -r  cid _info; do export-split-car "${cid}"; done
}

function find-split-car ()
{
    (
        set -e
        cd /selene/Sync/Upload/Titan_E/split && find . -name "*${1}*" | sort
    )
}

function read-split-car ()
{
    (
        set -e
        echo '' > "${HOME}"/split-car-read.log.txt
        cd /selene/Sync/Upload/Titan_E/split &&
        while read -r fname
        do
            if [[ -n "${fname}" ]]
            then
                echo "${fname}" >> "${HOME}"/split-car-read.log.txt
                cat "${fname}"
            fi
        done < <(
            find-split-car "${1}"
        )
    )
}

function import-split-car ()
{
    (
        set -e
        cd /selene/Sync/Upload/Titan_E/split && docker exec -i phill-dev_ipfs_1 ipfs dag import --pin-roots=false < <( mbuffer < <( read-split-car "${1}" ))
    )
}

export IPFS_GET_BATCH_COUNT
export IPFS_GET_TIMEOUT
export IPFS_PIN_TIMEOUT
export IPFS_RESOLVE_TIMEOUT
export IPFS_PIN_SLEEP
export IPFS_HTTP_GATEWAY
export PUBLIC_DAG_EXPORT_GATEWAY

# export -f charon.ipfs.preload