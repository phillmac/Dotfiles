#! /bin/bash

function charon_wtdl_remote ()
{
    sshp 192.168.30.57 \
        "nohup bash -c 'source .bashrc.d/charon.bashrc.d/webtorrent.bashrc && charon_wtdl'" \
     && docker run \
        --rm \
        --net host \
        -v /callisto/Data/Staging/Webtorrent:/workdir \
        -w /workdir \
        --entrypoint bash \
        phillmac/webtorrent -c 'webtorrent-hybrid ./*.torrent'
    echo "$(date) Done"
}


alias wtdl-charon=charon_wtdl_remote
alias cwtdl=charon_wtdl_remote
