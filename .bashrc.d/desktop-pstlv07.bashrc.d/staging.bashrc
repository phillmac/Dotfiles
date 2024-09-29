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



    if ! dcid=$(ipfs add -Q -r -w --pin=false "${dname}")
    then
        echo "Add ${dname} to IPFS failed"
        return 1
    fi
    empty=$(ipfs object new unixfs-dir)

    echo "Base dcid: ${dcid}" >&2

    for elem in "${dpath[@]}"
    do
        echo "Adding link ${elem} ${dcid} for mfs path ${mfspath}" >&2

        if ! dcid=$(ipfs object patch add-link -- "${empty}" "${elem}" "${dcid}")
        then
            echo "Failed to patch object ${empty} ${elem} ${dcid}"
            return 1
        fi

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

        echo "bname: ${bname}" >&2
        echo "dnamepath: ${dnamepath}" >&2


        (
            cd "${dnamepath}" \
             && pwd \
             && /cygdrive/c/rclone/rclone.exe move \
                    -vv \
                    --checksum \
                    --transfers 1 \
                    --delete-empty-src-dirs \
                    --include "${bname}/*" \
                    --min-age 2d \
                    --local-encoding None \
                    . \
                    "b2-phill-all:Archive-Store/_/Staging/${mfspath}"
        )
    fi
}

function laptop.staging.add.export ()
{
    if [[ -z "${1}" ]]
    then

        for ddname in /cygdrive/e/Staging/Laptop/Downloads/*/
        do

            echo "Found ${ddname}"
            bddname=$(basename "${ddname}")

            if ! laptop.staging.add.export "${bddname}"
            then
                return 1
            fi
        done

        return
    fi

    (
        cd "/cygdrive/e/Staging/Laptop/Downloads/${1}" && {
            for sdname in *
            do
                if [[ -d  "/cygdrive/e/Staging/Laptop/Downloads/${1}/${sdname}" ]]
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


  function ipfs.mimas.add.staging () {

    if [[ -z "${1}" ]]
    then

        for ddname in /cygdrive/g/Staging/Mimas/Downloads/*/
        do

            echo "Found ${ddname}"
            bddname=$(basename "${ddname}")

            if ! mimas.staging.add.export "${bddname}"
            then
                return 1
            fi
        done

        return
    fi

    (
        cd "/cygdrive/g/Staging/Mimas/Downloads/${1}" && {
            for sdname in *
            do
                if [[ -d  "/cygdrive/g/Staging/Mimas/Downloads/${1}/${sdname}" ]]
                then
                    echo "$(date) adding ${sdname}" >&2
                    staging.add.export "G:\Staging\Mimas\Downloads\\${1}\\${sdname}" "${1}" Downloads Mimas
                else
                    echo "Skipping nonexistent dir ${sdname}" >&2
                fi
            done
        }
    )
}