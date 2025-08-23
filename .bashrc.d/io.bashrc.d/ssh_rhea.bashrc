#! /bin/bash

function forward_rhea_ssh_unix ()
{
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




export -f ssh_rhea
export -f ipfs_dag_import_rhea_ssh
export -f ipfs_pin_ls_recursive_rhea
