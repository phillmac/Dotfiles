#! /bin/bash

function charon_wtdl ()
{
    docker \
            run --rm -it \
                --net pvs-dev_scheduler \
                docker sh -c \
                "docker --host docker-charon:2377 \
                    run \
                    --rm \
                    --net host \
                    -v /callisto/Data/Staging/Webtorrent:/workdir \
                    -w /workdir \
                    phillmac/webtorrent \
                        download \
                        --port 8085 \
                        --announce 'wss://tracker.vps1.phillm.net:8000' \
                        ${1}"

    webtorrent_download "${1}"
}

alias wtdl-charon=charon_wtdl
alias cwtdl=charon_wtdl
