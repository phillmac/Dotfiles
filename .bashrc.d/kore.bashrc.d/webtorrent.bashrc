#! /bin/bash

function charon_wtdl ()
{
    sshp 192.168.30.57 \
        docker run \
            --rm \
            --net host \
            -v /home/phill/webtorrent_dl:/workdir \
            -w /workdir \
            phillmac/webtorrent "${1}" \
         && docker run \
            --rm \
            --net host \
            -v /home/phill/webtorrent_dl:/workdir \
            -v /root:/root \
            -w /workdir \
            peelvalley/rclone-b2 \
                '"rclone move --verbose \
                /workdir/ \
                kore-ssh:/callisto/Data/Staging/Webtorrent/"'

    webtorrent_download "${1}"
}

alias wtdl-charon=charon_wtdl
alias cwtdl=charon_wtdl
