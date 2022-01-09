#! /bin/bash

function charon_wtdl_remote ()
{
    sshp 192.168.30.57 \
        "nohup bash -c 'source .bashrc.d/charon.bashrc.d/webtorrent.bashrc && charon_wtdl ${1}'" \
     && webtorrent_download "${1}"
}


alias wtdl-charon=charon_wtdl_remote
alias cwtdl=charon_wtdl_remote
