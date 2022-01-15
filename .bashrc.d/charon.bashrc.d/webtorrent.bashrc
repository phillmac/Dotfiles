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
            "rclone copy --verbose --include '${1}' \
            kore-ssh:/callisto/Data/Staging/Webtorrent/ \
            /workdir/" \
     && docker run \
        --rm \
        --net host \
        -v "${workdir}":/workdir \
        -w /workdir \
        phillmac/webtorrent "${1}" \
     && docker run \
        --rm \
        --net host \
        -v "${workdir}":/workdir \
        -v /root:/root \
        -w /workdir \
        peelvalley/rclone-b2 \
            "rclone move --verbose \
            /workdir/ \
            kore-ssh:/callisto/Data/Staging/Webtorrent/" \
     && rm -v "${workdir}"/*.torrent \
     && rmdir -v "${workdir}"
}

export -f charon_wtdl
