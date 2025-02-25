#!/bin/bash


IPFS_GET_BATCH_COUNT=10
IPFS_GET_TIMEOUT="3600s"
IPFS_PIN_TIMEOUT="4h"
IPFS_RESOLVE_TIMEOUT="15m"
IPFS_PIN_SLEEP="1h"

IPFS_PIN_ALLOWED_START="19:00"
IPFS_PIN_ALLOWED_FIN="02:00"

IPFS_HTTP_GATEWAY="http://192.168.20.33:8080"


#IPFS Backblaze
function ipfs-backblaze ()
{
    IPFS_PATH='/home/phill/.ipfs-backblaze' ipfs-s3 "${@}"
}

function ipfs-backblaze-test ()
{
    IPFS_PATH='/home/phill/.ipfs-backblaze-test' ipfs-s3 "${@}"
}

function ipfs-backblaze.pins.ls ()
{
    ipfs-backblaze pin ls --type=recursive | cut -d ' ' -f 1 | sort --unique
}

function ipfs-backblaze.pins.ls.export ()
{
    ipfs-backblaze.pins.ls > ".ipfs-backblaze/$(date '+%Y_%m_%d_%H_%M_%S').pins.txt"
}

function ipfs-backblaze.files.ls.export ()
{
    files_root=$(ipfs-backblaze files stat --hash /)
    gzip -9 < <(ipfs-backblaze ls --size=false "${files_root}") > ".ipfs-backblaze/$(date '+%Y_%m_%d_%H_%M_%S').files.txt.gz"
}

function ipfs-backblaze.archive.pins.missing ()
{
    local cids_count
    local progress
    local pin_cid_entry
    local progress_msg

    archive.entries "${1}" | sort --unique  > archive.entries.cids.txt
    ipfs-backblaze.pins.ls                  > backblaze.pins.txt

    comm -23  archive.entries.cids.txt backblaze.pins.txt > backblaze.archive.missing.txt
    cids_count=$(wc -l < backblaze.archive.missing.txt)

    ((progress=1))

    while read -r pincid
        do

            pin_cid_entry=$(grep "${pincid}" archive.entries.txt)
            progress_msg="$(date) ~ ipfs-backblaze missing item ${cid_entry} [${progress}/${cids_count}]"

            echo "${progress_msg}" >&2

            while ! ipfs-backblaze dag import < <(
                docker run \
                    --rm \
                    --net host \
                    --log-driver=none \
                    curlimages/curl curl \
                        --user 'user:rrVfzbvRYTwNABCxJWjeHFu4' \
                        "https://rhea.phillm.net/api/v0/dag/export?arg=${pincid}"
            )
            do
                echo "$(date) - Failed ${pin_cid_entry} [${progress}/${cids_count}]"
                sleep 300
                echo "$(date) - Retrying ${pin_cid_entry} [${progress}/${cids_count}]"
            done

            ((progress+=1))
    done < backblaze.archive.missing.txt

}

function ipfs.export.backblaze.batch ()
{
    while read -r cid fpath
    do
        echo "$(date) Exporting ${cid} - ${fpath}"

        while ! ipfs-backblaze dag import < <(mbuffer < <(ipfs dag export --timeout=3h --progress=false "${cid}"))
        do
            echo "$(date) Retrying"
            sleep 30
        done
    done
}

#IPFS Wasabi
function ipfs-wasabi ()
{
    IPFS_PATH='/home/phill/.ipfs-wasabi' ipfs-s3 "${@}"
}

function ipfs-wasabi.pins.ls ()
{
    ipfs-wasabi pin ls --type=recursive | cut -d ' ' -f 1 | sort --unique
}

function ipfs-wasabi.pins.ls.export ()
{
    ipfs-wasabi.pins.ls > ".ipfs-wasabi/$(date '+%Y_%m_%d_%H_%M_%S').pins.txt"
}

function ipfs-wasabi.files.ls.export ()
{
    files_root=$(ipfs-wasabi files stat --hash /)
    gzip -9 < <(ipfs-wasabi ls --size=false "${files_root}" ) > ".ipfs-wasabi/$(date '+%Y_%m_%d_%H_%M_%S').files.txt.gz"
}

function ipfs-wasabi.public.pins.missing ()
{
    local cids_count
    local progress
    local cid_entry
    local progress_msg

    ipfs.ls.recursive.files "${1}" "${2}" | tee public.files.txt | cut -d ' ' -f 1 | sort --unique > public.files.cids.txt
    ipfs-wasabi.pins.ls > wasabi.pins.txt

    comm -23 public.files.cids.txt wasabi.pins.txt > wasabi.public.missing.txt
    cids_count=$(wc -l < wasabi.public.missing.txt)

    ((progress=1))

    while read -r pincid
        do
            cid_entry=$(grep "${pincid}" public.files.txt)
            progress_msg="$(date) ~ ipfs-wasabi missing item ${cid_entry} [${progress}/${cids_count}]"

            echo "${progress_msg}" >&2

            ipfs-wasabi dag import < <(
                docker run \
                    --rm \
                    --net host \
                    --log-driver=none \
                    curlimages/curl curl \
                        "https://external5.ddns.peelvalley.com.au/api/v0/dag/export?arg=${pincid}"
            )
            ((progress+=1))
    done < wasabi.public.missing.txt

}

function ipfs-wasabi.archive.pins.missing ()
{
    local cids_count
    local progress
    local cid_entry
    local progress_msg

    archive.entries "${1}" | sort --unique > archive.entries.cids.txt
    ipfs-wasabi.pins.ls > wasabi.pins.txt

    comm -23  archive.entries.cids.txt wasabi.pins.txt > wasabi.archive.missing.txt
    cids_count=$(wc -l < wasabi.archive.missing.txt)

    ((progress=1))

    while read -r pincid
        do

            cid_entry=$(grep "${pincid}" archive.entries.txt)
            progress_msg="$(date) ~ ipfs-wasabi missing item ${cid_entry} [${progress}/${cids_count}]"

            echo "${progress_msg}" >&2

            ipfs-wasabi dag import < <(
                docker run \
                    --rm \
                    --net host \
                    --log-driver=none \
                    curlimages/curl curl \
                        "https://external5.ddns.peelvalley.com.au/api/v0/dag/export?arg=${pincid}"
            )
            ((progress+=1))
    done < wasabi.archive.missing.txt

}

function ipfs-wasabi.public.pins.monitor () {
    local public_hash
    local rlast
    local sleep_delay
    sleep_delay=${1:-$IPFS_PIN_SLEEP}

    while :
    do
        public_hash=$(public.root.hash)
        echo "$(date) rlast: '${rlast}' public_hash: '${public_hash}'" >&2
        if [[ "${rlast}" == "${public_hash}" ]]
        then
            echo "$(date) Waiting" >&2
            sleep "${sleep_delay}"
            continue
        fi
        echo "Pinning ${public_hash}" >&2
        ipfs-wasabi.public.pins.missing "${public_hash}"
        rlast=${public_hash}
        echo "$(date) Done" >&2
    done
}

function ipfs-wasabi.pin.update ()
{

    local before
    local after
    local last

    ipfs-wasabi files mkdir -p --flush=false "/scratchpad/${1}"

    while read -r cid dirpath
    do

        bdirpath=$(dirname "${dirpath}")
        echo "bdirpath: ${bdirpath}"

        ipfs-wasabi files mkdir -p --flush=false "/scratchpad/${bdirpath}"

        before=$(ipfs-wasabi files stat --flush=false --hash "/scratchpad/${1}")
        echo "Before: ${before}"

        if [[ -z "${last}" ]]
        then
            echo "Pinning initial dir"
            last=${before}
            ipfs-wasabi pin add --progress "${before}"

        else
            if [[ -z "${IPFS_MFS_SKIP_PIN_BEFORE}" ]]
            then
                if  ! ipfs-wasabi pin ls --type=recursive "${before}"
                then
                    ipfs-wasabi pin add --progress "${before}"
                else
                    echo "Skip already pinned ${before}"
                fi
            else
                echo "Skip pin before set"
            fi
        fi


        ipfs-wasabi files --flush=false rm -r "/scratchpad/${dirpath}"

	    echo "Copy /ipfs/${cid} /scratchpad/${dirpath}"

        ipfs-wasabi files cp --flush=false "/ipfs/${cid}" "/scratchpad/${dirpath}"

        after=$(ipfs-wasabi files stat --flush=false --hash "/scratchpad/${1}")

        echo "After: ${after}"

        if  ! ipfs-wasabi pin ls --type=recursive "${after}"
        then
            if [[ -n "${IPFS_MFS_SKIP_PIN_BEFORE}" ]]
            then
                ipfs-wasabi pin update --unpin=false "${last}" "${after}"
            else
                ipfs-wasabi pin update --unpin=false "${before}" "${after}"
            fi
        else
            echo "Skip already pinned ${after}"
        fi

    last=${after}


    done < <(ipfs.ls.recursive.dirs "${1}" | tac)

    ipfs-wasabi files rm -r --flush=false "/scratchpad/${1}"

    ipfs-wasabi files flush
}


function public.root.hash () {
    docker run \
        --rm \
        --net host \
        curlimages/curl curl 'https://ipfs-admin.phillm.net/api/v0/files/stat?hash=true&arg=/Public' | jq -r .Hash
}

function find-split-car ()
{
    (
        set -e
        find . -name "${1}.car.?????" | sort
    )
}

function read-split-car ()
{
    (
        set -e
        echo '' > "${HOME}"/split-car-read.log.txt

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

function import-split-car-backblaze ()
{
    (
        set -e
        ipfs-backblaze dag import < <( mbuffer < <( read-split-car "${1}" ))
    )
}

function gdrive.export.staging.move ()
{
    mv -v "$(find ~/gdrive/ipfs-export2 -type f | head -n 1)" ~/gdrive/ipfs-export
}

function process_gdrive_ipfs_export () {
    gdrive.export.staging.move \
    && while \
    ./transfer-ipfs-export.sh \
    && mv -v ~/gdrive/ipfs-export/*.car ~/gdrive/ipfs-export-processed \
    && ! [[ -e ~/.var/run/stop-ipfs-car-processing ]]
    do
        gdrive.export.staging.move
        sleep 2
    done
}

function ipfs_backblaze_sync_pins_rhea () {
    local cids_count
    local progress
    local missing_cid
    local progress_msg

   ipfs_pin_ls_recursive_rhea   > reha.pins.txt
   ipfs-backblaze.pins.ls       > backblaze.pins.txt

    comm -32 backblaze.pins.txt reha.pins.txt > reha.pins.missing.txt
    cids_count=$(wc -l < reha.pins.missing.txt)

    ((progress=1))

    while read -r missing_cid && ! [[ -e ~/.var/run/stop-ipfs-pin-sync ]]
    do
        progress_msg="$(date) ~ ipfs-rhea missing item ${missing_cid} [${progress}/${cids_count}]"

        echo "${progress_msg}" >&2

        ipfs_dag_import_rhea_ssh < <( ipfs-backblaze dag export --progress=false --timeout=24h "${missing_cid}" | mbuffer ) || break
        ((progress+=1))
    done < reha.pins.missing.txt
}


export IPFS_GET_BATCH_COUNT
export IPFS_GET_TIMEOUT
export IPFS_PIN_TIMEOUT
export IPFS_RESOLVE_TIMEOUT
export IPFS_PIN_SLEEP
export IPFS_PIN_ALLOWED_START
export IPFS_PIN_ALLOWED_FIN
export IPFS_HTTP_GATEWAY

export -f ipfs-wasabi
export -f ipfs-backblaze
export -f ipfs-backblaze-test
