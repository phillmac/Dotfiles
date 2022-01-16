#! /bin/bash

function charon_wtdl_remote ()
{
    sshp 192.168.30.57 \
        "nohup bash -c 'source .bashrc.d/webtorrent.bashrc && webtorrent_download_remote'" \
     && docker run \
        --rm \
        --net host \
        -v /callisto/Data/Staging/Webtorrent:/workdir \
        -w /workdir \
        --entrypoint bash \
        phillmac/webtorrent -c 'webtorrent-hybrid ./*.torrent'
    echo "$(date) Done"
}

function io_wtdl_remote ()
{
    sshp 192.227.67.212 \
        "nohup bash -c 'source .bashrc.d/webtorrent.bashrc && webtorrent_download_remote'" \
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
alias wtdl-io=io_wtdl_remote
alias iowtdl=io_wtdl_remote

export -f charon_wtdl_remote
export -f io_wtdl_remote