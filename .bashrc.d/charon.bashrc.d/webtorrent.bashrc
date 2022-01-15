#! /bin/bash

function charon_wtdl ()
{
    echo "TORRENT_NAME is \"${TORRENT_NAME}\""
    workdir=$(mktemp -d)
    echo "workdir is ${workdir}"
    docker run \
        --rm \
        --net host \
        -v "${workdir}":/workdir \
        -v /root:/root \
        -w /workdir \
        peelvalley/rclone-b2 \
            "rclone copy --verbose --include \"${TORRENT_NAME}\" \
            kore-ssh:/callisto/Data/Staging/Webtorrent/ \
            /workdir/" \
     && docker run \
        --rm \
        --net host \
        -v "${workdir}":/workdir \
        -w /workdir \
        phillmac/webtorrent "\"${TORRENT_NAME}\"" \
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
     && rm -v "${workdir}/${TORRENT_NAME}" \
     && rmdir -v "${workdir}"
}

export -f charon_wtdl
