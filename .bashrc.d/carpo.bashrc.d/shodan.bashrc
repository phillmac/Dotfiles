#! /bin/bash

shodan.public.cids.missing ()
{
    local public_hash
    public_hash=$(public.root.hash)
    ipfs.ls.recursive.files "${public_hash}" | tee shodan.public.files.txt | cut -d ' ' -f 1 | sort --unique > shodan.public.files.cids.txt
    curl -d '' 'http://192.168.50.51:5111/api/v0/pin/ls?type=recursive' | jq -r '.Keys | keys[]' | sort -u  > shodan.pins.txt
    comm -23 shodan.public.files.cids.txt shodan.pins.txt > shodan.public.missing.cids.txt
}

shodan.public.pins.missing () {
    while read -r cid
    do 
        echo "$(date) pinning $cid"
        while ! curl -d '' "http://192.168.50.51:5111/api/v0/pin/add?progress=true&timeout=4h&arg=${cid}"
        do 
            date
            sleep 5m
        done
    done < shodan.public.missing.cids.txt
}