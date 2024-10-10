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
    fi

    bname=$(basename "${dname}")
    dnamepath=$(dirname "${dname}")

    echo "bname: ${bname}" >&2
    echo "dnamepath: ${dnamepath}" >&2


    (
        cd "${dnamepath}" \
            && pwd \
            && find "${bname}" -type f -printf '%P\n' | tee list.txt \
            && ( \
                cd "${bname}" &&
                /cygdrive/c/rclone/rclone.exe move \
                    -vv \
                    --checksum \
                    --delete-empty-src-dirs \
                    --files-from ../list.txt \
                    --local-encoding None \
                    --backup-dir="b2-phill-all:Archive-Store/_/Staging/${dpath[2]}/Downloads-Backup/${dname}/$(date '+%Y%m%d%H%M')" \
                    . \
                    "b2-phill-all:Archive-Store/_/Staging/${mfspath}" \
                    || /cygdrive/c/rclone/rclone.exe move \
                    -vv \
                    --checksum \
                    --delete-empty-src-dirs \
                    --files-from ../list.txt \
                    --backup-dir="b2-phill-all:Archive-Store/_/Staging/${dpath[2]}/Downloads-Backup/${dname}/$(date '+%Y%m%d%H%M')" \
                    . \
                    "b2-phill-all:Archive-Store/_/Staging/${mfspath}"
                    ) && rm -v list.txt
        )
}

function laptop.staging.add.export ()
{
    if [[ -z "${1}" ]]
    then

        while read -r odirname
        do
            bodirname=$(basename "${odirname}")

            if ! laptop.staging.add.export "${bodirname}"
            then
                return 1
            fi

        done < <(
            find /cygdrive/e/Staging/Laptop/Downloads -maxdepth 1 -mindepth 1 -type d -exec stat --format='%W %n' {} \; \
                | sort -n \
                | cut -d ' ' -f2-
            )

        return
    fi

    if [[ "${1}" == /* ]]
    then
        sname=${1}
    else
        sname=/cygdrive/e/Staging/Laptop/Downloads/${1}
    fi

    bsname=$(basename "${1}")

    (
        cd "${sname}" && {
            for sdname in */
            do
                bsdname=$(basename "${sdname}")

                if [[ -d  "/cygdrive/e/Staging/Laptop/Downloads/${bsname}/${bsdname}" ]]
                then
                    echo "$(date) adding ${bsdname}" >&2
                    staging.add.export "E:\\Staging\\Laptop\\Downloads\\${bsname}\\${bsdname}" "${bsname}" Downloads Laptop
                else
                    echo "Skipping nonexistent dir ${bsdname}" >&2
                fi

            done
        }
    )

    /cygdrive/c/rclone/rclone.exe rmdirs -vv --local-encoding=none "E:\\Staging\\Laptop\\Downloads\\${bsname}" \
    || /cygdrive/c/rclone/rclone.exe rmdirs -vv "E:\\Staging\\Laptop\\Downloads\\${bsname}"
}


function ipfs.mimas.add.staging () {

    if [[ -z "${1}" ]]
    then

        while read -r odirname
        do
            bodirname=$(basename "${odirname}")

            if ! laptop.staging.add.export "${bodirname}"
            then
                return 1
            fi

        done < <(
            find /cygdrive/g/Staging/Mimas/Downloads  -maxdepth 1 -mindepth 1 -type d -exec stat --format='%W %n' {} \; \
                | sort -n \
                | cut -d ' ' -f2-
            )

        return
    fi

    if [[ "${1}" == /* ]]
    then
        sname=${1}
    else
        sname=/cygdrive/g/Staging/Mimas/Downloads/${1}
    fi

    (
        cd "${sname}" && {
            for sdname in */
            do
                bsdname=$(basename "${sdname}")
                if [[ -d  "/cygdrive/g/Staging/Mimas/Downloads/${1}/${bsdname}" ]]
                then
                    echo "$(date) adding ${bsdname}" >&2
                    staging.add.export "G:\Staging\Mimas\Downloads\\${1}\\${bsdname}" "${1}" Downloads Mimas
                else
                    echo "Skipping nonexistent dir ${bsdname}" >&2
                fi
            done
        }
    )
}