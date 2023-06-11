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

ipfs.add.export.carpo () {
    local dname=${1}
    local args=( "$@" );
    local dpath=( "${args[@]:1}" )

    local dcid=$(ipfs add -Q -r -w --pin=false "${dname}")
    local empty=$(ipfs object new unixfs-dir)
    local elem

    for elem in "${dpath[@]}"
    do
        dcid=$(ipfs object patch add-link "${empty}" "${elem}" "${dcid}")
    done

    if ! grep -q "${dcid}" "/cygdrive/e/Staging/staging cids.txt"
    then
        ipfs dag export -p "${dcid}" > "/cgydrive/h/ipfs-export/${dcid}.car"

        /cygdrive/c/rclone/rclone move -v "/cgydrive/h/ipfs-export/${dcid}.car" carpo:/data/ipfs-export

        ssh -p 35681 phill@carpo "docker run --rm -v /data/ipfs-export:/data/ipfs-export peelvalley/rclone-b2 rclone move -v '/data/ipfs-export/${dcid}.car' phill-gdrive:ipfs-export"
        ssh phill@vps4 staging.gdrive.import "${dcid}"
        echo "${dcid}" >> "/cygdrive/e/Staging/staging cids.txt"
    fi


}