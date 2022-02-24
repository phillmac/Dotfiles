#!/bin/bash

function webtorrent ()
{
    docker run \
    --rm \
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
    --rm \
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

function webtorrent_add_wasabi ()
{
    source "${HOME}/.bashrc.d/010env.bashrc"
    if [[ "${SHORT_HOST}" == "io" ]]
    then
        source "${BASH_RC_HOST_DIR}/ipfs.bashrc"
        ipfs-wasabi add -p -r -w --pin=false "${1}"/*
        echo
    fi
}

function webtorrent_download_remote ()
{
    set -e

    workdir=$(mktemp -d --tmpdir=/dev/shm)

    trap 'rm -frv -- "${workdir}"' ERR
    trap 'rm -frv -- "${workdir}"' EXIT

    echo "workdir is ${workdir}"

    docker run \
        --rm \
        --net host \
        -v "${workdir}":/workdir \
        -v /root:/root \
        -w /workdir \
        peelvalley/rclone-b2 \
            'rclone copy --verbose \
                --include *.torrent \
                kore-ssh:/callisto/Data/Staging/Webtorrent/ \
                /workdir/'

    echo "$(date) Downloading"

    docker run \
        --rm \
        --net host \
        -v "${workdir}":/workdir \
        -w /workdir \
        --entrypoint bash \
        phillmac/webtorrent -c 'webtorrent ./*.torrent'

    ls -la "${workdir}"
    rm -vf "${workdir}"/*.torrent

    webtorrent_add_wasabi "${workdir}"

    docker run \
        --rm \
        --net host \
        -v "${workdir}":/workdir \
        -v /root:/root \
        -w /workdir \
        peelvalley/rclone-b2 \
            "rclone move \
                -vvv \
                --retries 120 \
                --retries-sleep 30s \
                --exclude '*.torrent' \
                /workdir/ \
                kore-ssh:/callisto/Data/Staging/Webtorrent/"
}

function webtorrent_download_remote_staging ()
{
    set -e

    workdir=$(mktemp -d)

    trap 'rm -frv -- "${workdir}"' ERR
    trap 'rm -frv -- "${workdir}"' EXIT

    echo "workdir is ${workdir}"

    echo "$(date) Downloading"

    docker run \
        --rm \
        --net host \
        -v "${workdir}":/workdir \
        -w /workdir \
        --entrypoint bash \
        phillmac/webtorrent -c "webtorrent ${1}"

    ls -la "${workdir}"
    rm -vf "${workdir}"/*.torrent

    webtorrent_add_wasabi "${workdir}"

    docker run \
        --rm \
        --net host \
        -v "${workdir}":/workdir \
        -v /root:/root \
        -w /workdir \
        peelvalley/rclone-b2 \
            "rclone move \
                -vvv \
                --retries 120 \
                --retries-sleep 30s \
                --exclude '*.torrent' \
                /workdir/ \
                kore-ssh:/callisto/Data/Staging/"
}

export -f webtorrent_download_remote
export -f webtorrent_download_remote_staging
export -f webtorrent
export -f webtorrent_create
export -f webtorrent_download
export -f webtorrent_seed


alias wtdl=webtorrent_download
