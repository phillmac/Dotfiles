#! /bin/bash

function ipfs.get.recursive.files () {
    local cid
    local info

    ipfs.ls.recursive.files "${1}" | tee "${1}".files.list.txt
    while read -r cid info
    do
        echo "$(date) ${cid} ${info}"
        ipfs dag export -p --timeout 1h "${cid}" > /dev/null
    done < "${1}".files.list.txt
}

function ipfs.export.dirs () {
    while read -r cid dirname
        do
            mkdir -pv "/cygdrive/h/ipfs-export/${1}/${dirname}"
	        echo "$(date) Exporting ${cid} ${dirname}" >&2
            ipfs dag export -p "${cid}" > "/cygdrive/h/ipfs-export/${1}/${dirname}${cid}.car"
            /cygdrive/c/rclone/rclone move -v --include "${cid}.car" "H:\ipfs-export" "carpo:/data/ipfs-staging/Mimas/Downloads"
        done < <(ipfs ls --stream=true --size=false "${1}")
}
