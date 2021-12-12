#!/bin/bash

function webtorrent ()
{
    docker run \
    --rm -it \
    --net host \
    phillmac/webtorrent \
        --announce 'wss://tracker.vps1.phillm.net:8000' \
        --keep-seeding \
        --port 8085 \
        "${@}"
}

function webtorrent_download ()
{
    docker run \
    --rm -it \
    --net host \
    -v /callisto/Data/Staging/Webtorrent:/workdir \
    -w /workdir \
    phillmac/webtorrent \
        download \
        --port 8085 \
        --announce 'wss://tracker.vps1.phillm.net:8000' \
        "${@}"
}

function webtorrent_create () {
    docker run \
    --rm -it \
    --net none \
    -v "$(pwd)":/workdir \
    -w /workdir \
    --entrypoint create-torrent \
    phillmac/webtorrent \
        "${@}"
}

function webtorrent_seed ()
{
    docker run \
    --rm -it \
    --net host \
    -v "$(pwd)":/workdir \
    -w /workdir \
    phillmac/webtorrent \
        download \
        --announce 'wss://tracker.vps1.phillm.net:8000' \
        --keep-seeding \
        --port 8085 \
        "${@}"
}

export -f webtorrent
export -f webtorrent_create
export -f webtorrent_download
export -f webtorrent_seed


alias wtdl=webtorrent_download
