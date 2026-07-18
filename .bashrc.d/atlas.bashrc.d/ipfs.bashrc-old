#!/bin/bash


IPFS_HTTP_GATEWAY="192.168.35.51:8080"
IPFS_GET_BATCH_COUNT=10
IPFS_GET_TIMEOUT="3600s"
IPFS_PIN_TIMEOUT="24h"
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
    ( cd /titan/E/ipfs-export/split && ipfs dag export -p "${1}" | split -b 10M -a 4 --verbose - "${1}.car." )
}

function find-split-car ()
{
    (
        set -e
        cd /titan/E/ipfs-export/split && find . -name "${1}.car.????" | sort
    )
}

function read-split-car ()
{
    (
        set -e
        echo '' > "${HOME}"/split-car-read.log.txt
        cd /titan/E/ipfs-export/split &&
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
        cd /titan/E/ipfs-export/split && docker exec -i phill-dev_ipfs_1 ipfs dag import --pin-roots=false < <( mbuffer < <( read-split-car "${1}" ))
    )
}

function archive.split.dir ()
{

    local archive_cid;
    archive_cid=${1};
    ( set -e;
    shopt -s nullglob;
    while read -r cid _info; do
        echo "Archiving ${cid}" >&2;
        mvfiles=("/titan/E/Sync/Upload/Selene/split/${cid}.car."*);
        if (( ${#mvfiles[@]} )); then
            mv -vf "/titan/E/Sync/Upload/Selene/split/${cid}.car."* /titan/E/ipfs-export/split/;
        else
            echo "Unable to move any archives for ${cid}" >&2;
        fi;
        archivefiles=("/titan/E/ipfs-export/split/${cid}.car."*);
        if (( ${#archivefiles[@]} )); then
            if import-split-car "${cid}"; then
                upload-split-car "${cid}";
                if ipfs pin rm "${cid}"; then
                    true
                fi
            else
                echo "Archive integrity check failed for ${cid}" >&2;
            fi;
        else
            echo "Unable to find any archives for ${cid}" >&2;
        fi;
    done < <( ipfs.ls.recursive "${archive_cid}" && echo "${archive_cid}" ) )
}
function find.archive.split.dir () {
    local fname
    local cid

    while read -r fname
    do
        cid=$(basename "${fname}" .car.pieces.txt)
        archive.split.dir "${cid}"
    done < <(find /titan/E/Sync/Upload/Selene/split/ -type f -name '*.car.pieces.txt' -printf "%T@ %Tc %p\n" | sort -n | cut -d ' ' -f 9 )
}



export -f split-car
export -f upload-car
export -f export-split-car