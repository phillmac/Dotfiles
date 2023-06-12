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

function ipfs.add.export () {
    local dname=${1}
    local args=( "$@" );
    local dpath=( "${args[@]:1}" )

    local dcid
    local empty
    local elem
    local mfspath

    dcid=$(ipfs add -Q -r -w --pin=false "${dname}")
    empty=$(ipfs object new unixfs-dir)

    for elem in "${dpath[@]}"
    do
        dcid=$(ipfs object patch add-link "${empty}" "${elem}" "${dcid}")
        mfspath="${elem}/${mfspath}"
    done

    echo "/ipfs/${dcid} /${mfspath}" >&2

    if ! grep -q "${dcid}" "/cygdrive/e/Staging/staging cids.txt"
    then
        echo "Exporting ${dcid}" >&2

        ipfs dag export -p "${dcid}" > "/cgydrive/h/ipfs-export/${dcid}.car"

        /cygdrive/c/rclone/rclone move -v "H:\ipfs-export\${dcid}.car" carpo:/data/ipfs-export

        ssh -p 35681 phill@carpo "docker run --rm -v /data/ipfs-export:/ipfs-export peelvalley/rclone-b2 rclone move -v '/ipfs-export/${dcid}.car' phill-gdrive:ipfs-export"

        ssh phill@vps4 "docker run --rm peelvalley/rclone-b2 'rclone cat phill-gdrive:ipfs-export/${dcid}.car' | mbuffer | docker exec -i phill-dev_ipfs_1 ipfs dag import --pin-roots=false"

        ssh phill@vps4 ipfs.files.cp.deep "/ipfs/${dcid}" "'/${mfspath}'"

        echo "${dcid}" >> "/cygdrive/e/Staging/staging cids.txt"
    else
        echo "Found ${dcid} already exported" >&2
    fi

}