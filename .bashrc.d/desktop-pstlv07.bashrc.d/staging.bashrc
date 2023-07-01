#! /bin/bash

function staging.add.export () {
    local dname=${1}
    local args=( "$@" );
    local dpath=( "${args[@]:1}" )

    local bname
    local dcid
    local empty
    local elem
    local mfspath

    dcid=$(ipfs add -Q -r -w --pin=false "${dname}")
    empty=$(ipfs object new unixfs-dir)

    echo "Base dcid: ${dcid}" >&2

    for elem in "${dpath[@]}"
    do
        echo "Adding link ${elem} ${dcid} for mfs path ${mfspath}" >&2
        dcid=$(ipfs object patch add-link "${empty}" "${elem}" "${dcid}")
        mfspath="${elem}/${mfspath}"
    done

    echo "/ipfs/${dcid} /${mfspath}" >&2

    if ! grep -q "${dcid}" "/cygdrive/e/Staging/staging cids.txt"
    then
        echo "Exporting ${dcid}" >&2

        ipfs dag export -p "${dcid}" > "/cygdrive/h/ipfs-export/${dcid}.car"

        /cygdrive/c/rclone/rclone move -v "H:\ipfs-export\\${dcid}.car" carpo:/data/ipfs-staging
        /cygdrive/c/rclone/rclone move -v "carpo:/data/ipfs-staging/${dcid}.car" carpo:/data/ipfs-export

        echo "${dcid}" >> "/cygdrive/e/Staging/staging cids.txt"
    else
        echo "Found ${dcid} already exported" >&2
        bname=$(basename "${dname}")
        dnamepath=$(dirname "${dname}")

        (
            cd "${dnamepath}" \
             &&  /cygdrive/c/rclone/rclone.exe move \
                    -vvv \
                    --checksum \
                    --transfers 1 \
                    --delete-empty-src-dirs \
                    --include "${bname}/*" \
                    --min-age 30d \
                    . \
                    "b2-phill-all:Archive-Store/_/Staging/${mfspath}"
        )
    fi

}

function laptop.staging.add.export ()
{
    (
        cd "/cygdrive/e/Staging/Laptop/Downloads/${1}" && {
            for sdname in *
            do
                if [[ -d  "/cygdrive/c/Staging/Laptop/Downloads/${1}/${sdname}" ]]
                then
                    echo "$(date) adding ${sdname}" >&2
                    staging.add.export "E:\Staging\Laptop\Downloads\\${1}\\${sdname}" "${1}" Downloads Laptop
                else
                    echo "Skipping nonexistent dir ${sdname}" >&2
                fi
            done
        }
    )
}
