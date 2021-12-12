#!/bin/bash

function public.pins.missing () {
    local public_hash
    local cid
    local _fpath

    public_hash=$(curl -s --fail 'https://ipfs-admin.phillm.net/api/v0/files/stat?hash=true&arg=/Public' | jq -r .Hash)

    ipfs.ls.recursive.files "${public_hash}" |  tee public.files.txt | cut -f 1 -d ' ' | sort -u > public.files.cids.txt

    ipfs pin ls --type=recursive | cut -f1 -d ' ' | sort -u > pins.txt

    while read -r cid _fpath
    do
        grep "${cid}" public.files.txt
        ipfs pin add --progress "${cid}"
    done < <(comm -23  public.files.cids.txt pins.txt )

}
