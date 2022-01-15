#! /bin/bash

function charon_wtdl ()
{
    workdir=$(mktemp -d)
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
                /workdir/' \
     && echo "$(date) Downloading" \
     && docker run \
        --rm \
        --net host \
        -v "${workdir}":/workdir \
        -w /workdir \
        --entrypoint bash \
        phillmac/webtorrent -c 'webtorrent-hybrid ./*.torrent' \
     && docker run \
        --rm \
        --net host \
        -v "${workdir}":/workdir \
        -v /root:/root \
        -w /workdir \
        peelvalley/rclone-b2 \
            "rclone move --verbose \
                --exclude '*.torrent' \
                /workdir/ \
                kore-ssh:/callisto/Data/Staging/Webtorrent/" \
     && rm -frv "${workdir}"
}

export -f charon_wtdl
