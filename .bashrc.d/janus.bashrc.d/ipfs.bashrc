#!/bin/bash


IPFS_HTTP_GATEWAY="http://192.168.42.32:8080"
IPFS_PIN_TIMEOUT="24h"
IPFS_RESOLVE_TIMEOUT="15m"
IPFS_PIN_SLEEP="15m"
PUBLIC_CIDS_FILE="//192.168.50.53/c/Users/phill/Documents/public cids.txt"

function export-split-car ()
{
    ( cd /cygdrive/g/ipfs-export/split && ipfs dag export -p "${1}" | split -b 10M -a 3 --verbose - "${1}.car." )
}


function janus.archive.pins.missing ()
{
    archive.entries "${1}" | sort --unique > archive.entries.cids.txt
    ipfs pin ls --type=recursive | cut -d ' ' -f 1 | sort --unique > janus.pins.txt
    comm -23  archive.entries.cids.txt janus.pins.txt > janus.archive.missing.txt
    cids_count=$(wc -l < janus.archive.missing.txt)
    ((progress=1))
    while read -r pincid
        do

            pin_cid_entry=$(grep "${pincid}" archive.entries.txt)
            echo "$(date) janus missing item " "${pin_cid_entry} [${progress}/${cids_count}]" >&2
            while ! ipfs dag import < <(
                curl \
                    --user 'user:rrVfzbvRYTwNABCxJWjeHFu4' \
                    "https://rhea.phillm.net/api/v0/dag/export?arg=${pincid}"
            )
            do
                echo "$(date) - Retrying ${pin_cid_entry} [${progress}/${cids_count}]"
                sleep 300
            done

            ((progress+=1))
    done < janus.archive.missing.txt

}


export IPFS_HTTP_GATEWAY
export IPFS_PIN_TIMEOUT
export IPFS_RESOLVE_TIMEOUT
export IPFS_PIN_SLEEP
export PUBLIC_CIDS_FILE

export -f export-split-car