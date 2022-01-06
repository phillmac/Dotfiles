#! /bin/bash

function charon_wtdl ()
{
    workdir=$(mktemp)
    echo "workdir is ${workdir}"
    docker run \
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
            kore-ssh:/callisto/Data/Staging/Webtorrent/"\
        && rmdir -v "${workdir}"
}

alias wtdl-charon=charon_wtdl
alias cwtdl=charon_wtdl
