#! /bin/bash

function forward_rhea_ssh_unix ()
{
    ssh -vNL ~/.var/run/rhea-ssh.sock:127.0.0.1:22 ubuntu@192.99.21.37
}

function ssh_rhea ()
{
    ssh -o "ProxyCommand socat - UNIX-CLIENT:/home/phill/.var/run/rhea-ssh.sock" 'ubuntu@rhea' "${@}"
}

function ipfs_dag_import_rhea_ssh ()
{
    ssh_rhea "mbuffer -e -q | ipfs --api /unix/home/ubuntu/.var/run/ipfs-wasabi.socket dag import"
}



export -f ssh_rhea
export -f ipfs_dag_import_rhea_ssh
