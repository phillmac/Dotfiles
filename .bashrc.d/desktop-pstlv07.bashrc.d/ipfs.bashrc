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