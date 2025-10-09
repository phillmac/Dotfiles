#! /bin/bash

function forward_rhea_ssh_unix ()
{

    [[ ! -d ~/.var/run ]] && mkdir -pv ~/.var/run

    rm -v \
    ~/.var/run/rhea-ipfs-wasabi.sock \
    ~/.var/run/rhea-ssh.sock

    ssh -vN \
    -L ~/.var/run/rhea-ssh.sock:127.0.0.1:22 \
    -L ~/.var/run/rhea-ipfs-wasabi.sock:/home/ubuntu/.var/run/ipfs-wasabi.socket \
    -o ServerAliveInterval=10 \
    -o ServerAliveCountMax=12 \
    ubuntu@192.99.21.37
}

function ssh_rhea ()
{
    ssh -o "ProxyCommand socat - UNIX-CLIENT:/home/phill/.var/run/rhea-ssh.sock" 'ubuntu@rhea' "${@}"
}

function ipfs_dag_import_rhea_ssh ()
{
    ssh_rhea "mbuffer -e -q | ipfs --api /unix/home/ubuntu/.var/run/ipfs-wasabi.socket dag import ${*}"
}

function ipfs_dag_export_rhea_ssh ()
{
    ssh_rhea "ipfs --api /unix/home/ubuntu/.var/run/ipfs-wasabi.socket dag export --progress=false ${*} | mbuffer -e -q"
}

function ssh_rhea_ipfs ()
{
    ssh_rhea ipfs --api /unix/home/ubuntu/.var/run/ipfs-wasabi.socket "${@}"
}

function rhea_ipfs_local_api ()
{
    ipfsv0.31.0 --api /unix/home/phill/.var/run/rhea-ipfs-wasabi.sock "${@}"
}

function ipfs_pin_ls_recursive_rhea ()
{
    sort -u < <( ssh_rhea_ipfs 'pin ls --type=recursive' | cut -d ' ' -f 1 )
}

function fetch_cids () {

    if [[ ! -e cid_fetch_queue ]]
    then
        mkfifo cid_fetch_queue
    fi

    exec {RFD}<> cid_fetch_queue

    while IFS= read -r cid <&"$RFD"
    do
        printf '%s Fetching %s\n' "$(date)" "$cid" >&2
        ipfs_dag_export_rhea_ssh "${cid}" | mbuffer | ipfs dag import --pin-roots=false
    done

}

function ipfs.ls.native ()
{
    local root_cid=$1
    shift || true  # optional extra args for the inner `ipfs ls` go in "$@"

    if [[ -z $root_cid ]]; then
        echo "usage: ipfs.ls.native <root_cid> [extra-args-for-inner-ipfs-ls]" >&2
        return 2
    fi

    # Phase 1: fully collect child CIDs (waits for the producer to finish)
    local -a cids
    mapfile -t cids < <( ipfs ls --stream --resolve-type=false --size=false "$root_cid" | cut -d' ' -f1 )

    # Phase 2: process each child CID after the first pass is complete
    local cid
    for cid in "${cids[@]}"; do
        printf '%s Listing %s\n' "$(date)" "$cid" >&2
        ipfs ls --stream "$cid" "$@" || {
            err=${?}
            printf '%s Failed to list %s\n' "$(date)" "$cid" >&2

            if [[ -e cid_fetch_queue ]]
            then
                printf '%s\n' "$cid" > cid_fetch_queue
            fi

            return ${err}
        }
    done
}

function ipfs.ls.native.export ()
{
    set -o pipefail

    while ! {
        date >&2
        ipfs.ls.native "${1}"
    } 2>ls.log.txt; do
        now="$(date '+%Y-%m-%d %H:%M:%S')"
        resume_time="$(date -d '+3 hours' '+%Y-%m-%d %H:%M:%S')"
        echo "[$now] ipfs.ls.native failed — next retry scheduled for $resume_time" >&2
        sleep 3h
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Resuming retry attempt..." >&2
    done | mbuffer -q -e | while read -r exportcid _exportcidsize exportcidname; do
        printf '%s Exporting %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${exportcid}" "${exportcidname}" >&2

        mbuffer -e -W 300 > /dev/null < <(ipfs dag export --progress=false "${exportcid}") || {
                printf '%s Failed to list %s\n' "$(date)" "$cid" >&2

                if [[ -e cid_fetch_queue ]]
                then
                    printf '%s\n' "${exportcid}" > cid_fetch_queue
                fi
            }
    done

}

function ipfs.ls.native.pin ()
{
    set -o pipefail

    while ! {
        date >&2
        ipfs.ls.native "${1}"
    } 2>ls.log.txt; do
        now="$(date '+%Y-%m-%d %H:%M:%S')"
        resume_time="$(date -d '+3 hours' '+%Y-%m-%d %H:%M:%S')"
        echo "[$now] ipfs.ls.native failed — next retry scheduled for $resume_time" >&2
        sleep 3h
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Resuming retry attempt..." >&2
    done | mbuffer -q -e | while read -r pincid _pincidsize pincidname; do
        printf '%s Pining %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${pincid}" "${pincidname}" >&2

        mbuffer -e -W 300 > /dev/null < <(ipfs pin add --progress "${pincid}") || {
                printf '%s Failed to list %s\n' "$(date)" "$cid" >&2

                if [[ -e cid_fetch_queue ]]
                then
                    printf '%s\n' "${pincid}" > cid_fetch_queue
                fi
            }
    done

}
export -f ssh_rhea
export -f ipfs_dag_import_rhea_ssh
export -f ipfs_pin_ls_recursive_rhea
export -f rhea_ipfs_local_api
