#! /bin/bash

function charon_wtdl_remote ()
{
    if sshp 192.168.30.57 \
        "nohup bash -c 'source .bashrc.d/150webtorrent.bashrc && webtorrent_download_remote'"
    then 
        if verify_torrent --no-delete ./*.torrent --prefix /callisto/Data/Staging/Webtorrent
        then
            echo "$(date) Done" >&2
        else
            echo "$(date) Local verify failed"
            return 1
        fi
    else
        echo "$(date) Remote download failed" >&2
        return 1
    fi
}

function io_wtdl_remote ()
{
    if sshp 192.227.67.212 \
        "nohup bash -c 'source .bashrc.d/150webtorrent.bashrc && webtorrent_download_remote'"
    then 
        if verify_torrent --no-delete ./*.torrent --prefix /callisto/Data/Staging/Webtorrent
        then
            echo "$(date) Done" >&2
        else
            echo "$(date) Local verify failed"
            return 1
        fi
    else
        echo "$(date) Remote download failed" >&2
        return 1
    fi
}

function io_wtdl_remote_staging ()
{
    sshp 192.227.67.212 \
        "nohup bash -c 'source .bashrc.d/150webtorrent.bashrc && webtorrent_download_remote_staging ${1}'" \
     && docker run \
        --rm \
        --net host \
        -v /callisto/Data/Staging:/workdir \
        -w /workdir \
        --entrypoint bash \
        phillmac/webtorrent -c "webtorrent ${1}"
    echo "$(date) Done"
}


alias wtdl-charon=charon_wtdl_remote
alias cwtdl=charon_wtdl_remote
alias wtdl-io=io_wtdl_remote
alias iowtdl=io_wtdl_remote

export -f charon_wtdl_remote
export -f io_wtdl_remote