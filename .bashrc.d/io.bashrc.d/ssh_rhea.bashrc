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

function rhea.fetch_cids () {

    if [[ ! -e cid_fetch_queue ]]
    then
        mkfifo cid_fetch_queue
    fi

    exec {RFD}<> cid_fetch_queue

    while IFS= read -r cid <&"$RFD"
    do
        printf '%s Fetching %s\n' "$(date)" "$cid" >&2
        ipfs-wasabi dag export --progress=false --timeout=24h "${cid}" | mbuffer | rhea_ipfs_local_api dag import --pin-roots=false
    done

}

function rhea.ipfs.ls.native ()
{
    local root_cid=$1
    shift || true  # optional extra args for the inner `ipfs ls` go in "$@"

    if [[ -z $root_cid ]]; then
        echo "usage: rhea.ipfs.ls.native <root_cid> [extra-args-for-inner-ipfs-ls]" >&2
        return 2
    fi

    # Phase 1: fully collect child CIDs (waits for the producer to finish)
    local -a cids
    mapfile -t cids < <( rhea_ipfs_local_api refs "$root_cid" )

    # Phase 2: process each child CID after the first pass is complete
    local cid
    for cid in "${cids[@]}"; do
        printf '%s Listing %s\n' "$(date)" "$cid" >&2
        rhea_ipfs_local_api ls --stream "$cid" "$@" || {
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



export -f ssh_rhea
export -f ipfs_dag_import_rhea_ssh
export -f ipfs_pin_ls_recursive_rhea
export -f rhea_ipfs_local_api
