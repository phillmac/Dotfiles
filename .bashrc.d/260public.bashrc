#!/bin/bash

function public.root.hash () {
    curl -s --fail 'https://ipfs-admin.phillm.net/api/v0/files/stat?hash=true&arg=/Public' | jq -r .Hash
}

function public.anime.names ()
{
    ipfs.ls "$(public.root.hash)/Anime" | jq -r .Name
}

function public.anime.episodes ()
{
    local resolved

    resolved=$(ipfs.resolve "$(public.root.hash)/Anime/${1}")
    # echo "Resolved is ${resolved}" >&2

    ipfs.ls "${resolved}" | jq -r .Name
}

function public.anime.hasep ()
{
    local anime_has_ep

    anime_has_ep=1

    while read -r file_name
    do
        if [[ "${2}" == *"${file_name}"* ]]
        then
            anime_has_ep=0
        fi
    done < <(public.anime.episodes "${1}")

    return ${anime_has_ep}
}

function public.pin.add.local () {
    if [[ -n "${PUBLIC_DAG_EXPORT_GATEWAY}" ]]
    then
       while ! docker run \
                --rm \
                --net host \
                curlimages/curl curl --fail \
                    "${PUBLIC_DAG_EXPORT_GATEWAY}/${IPFS_API}/dag/export?arg=${1}" > "${1}"
        do
            sleep 30m
        done

        docker exec -i phill-dev_ipfs_1 ipfs dag import < <( mbuffer < "${1}")
        rm -v "${1}"

    else
        ipfs pin add --progress --timeout "${IPFS_PIN_TIMEOUT}" "${1}"
    fi
}

function public.anime.hasdir ()
{
    local anime_has_dir

    anime_has_dir=1

    while read -r dir_name
    do
        if [[ "${dir_name}" == "${1}" ]]
        then
            anime_has_dir=0
        fi
    done < <(public.anime.names)

    return ${anime_has_dir}
}

function public.pins.missing.local () {
    local public_hash
    local entry
    local pincid


    public_hash=$(public.root.hash)

    ipfs.ls.recursive.files "${public_hash}"  | tee public.files.txt | cut -d ' ' -f 1 | sort --unique > public.files.cids.txt

    ipfs pin ls --type=recursive | cut -f1 -d ' ' | sort -u > pins.txt

    comm -23 public.files.cids.txt pins.txt > public.missing.cids.txt
    cids_count=$(wc -l < public.missing.cids.txt)
    ((progress=1))

    while read -r pincid
    do
        entry=$(grep "${pincid}" public.files.txt)
        echo "$(date)  Missing item ${entry} [${progress}/${cids_count}]" >&2
        public.pin.add.local "${pincid}"
        ((progress+=1))
    done < public.missing.cids.txt
}

function public.pins.missing.local.lockout () {
    local public_hash
    local entry
    local pincid


    public_hash=$(public.root.hash)

    ipfs.ls.recursive.files "${public_hash}"  | tee public.files.txt | cut -d ' ' -f 1 | sort --unique > public.files.cids.txt

    ipfs pin ls --type=recursive | cut -f1 -d ' ' | sort -u > pins.txt

    comm -23 public.files.cids.txt pins.txt > public.missing.cids.txt
    cids_count=$(wc -l < public.missing.cids.txt)
    ((progress=1))

    while read -r pincid
    do
        while ! check_lockout_time
        do
            echo "$(date) Waiting for lockout time to expire" >&2
            sleep 15m
        done
        entry=$(grep "${pincid}" public.files.txt)
        echo "$(date)  Missing item ${entry} [${progress}/${cids_count}]" >&2
        public.pin.add.local "${pincid}"
        ((progress+=1))
    done < public.missing.cids.txt
}


function public.pins.monitor.lockout () {
    local public_hash
    local rlast
    local sleep_delay
    sleep_delay=${1:-$IPFS_PIN_SLEEP}


    while :
    do
        public_hash=$(public.root.hash)
        echo "$(date) rlast: '${rlast}' public_hash: '${public_hash}'" >&2
        if [[ "${rlast}" == "${public_hash}" ]]
        then
            echo "$(date) Waiting" >&2
            sleep "${sleep_delay}"
            continue
        fi
        echo "Pinning ${public_hash}" >&2
        public.pins.missing.local.lockout
        rlast=${public_hash}
        echo "$(date) Done" >&2
    done
}

function public.pins.monitor () {
    local public_hash
    local rlast
    local sleep_delay
    sleep_delay=${1:-$IPFS_PIN_SLEEP}

    while :
    do
        public_hash=$(public.root.hash)
        echo "$(date) rlast: '${rlast}' public_hash: '${public_hash}'" >&2
        if [[ "${rlast}" == "${public_hash}" ]]
        then
            echo "$(date) Waiting" >&2
            sleep "${sleep_delay}"
            continue
        fi
        echo "Pinning ${public_hash}" >&2
        public.pins.missing.local "${public_hash}"
        rlast=${public_hash}
        echo "$(date) Done" >&2
    done
}

function public.list.preload ()
{
    local cid
    cid=$( public.root.hash )
    echo  "Janus        $(wc -l < <(IPFS_HTTP_GATEWAY=192.168.42.208:8080       ipfs.ls.recursive "${cid}" 2> /dev/null))"
    echo "Carpo         $(wc -l < <(IPFS_HTTP_GATEWAY=192.168.50.51:8080        ipfs.ls.recursive "${cid}" 2> /dev/null))"
    echo "Charon        $(wc -l < <(IPFS_HTTP_GATEWAY=192.168.30.57:8080        ipfs.ls.recursive "${cid}" 2> /dev/null))"
    echo "Io            $(wc -l < <(IPFS_HTTP_GATEWAY=http://192.168.20.33:8080 ipfs.ls.recursive "${cid}" 2> /dev/null))"
    echo "Io Wasabi     $(wc -l < <(IPFS_HTTP_GATEWAY=http://192.168.20.33:8080 ipfs.ls.recursive "${cid}" 2> /dev/null))"
    echo "Titan         $(wc -l < <(IPFS_HTTP_GATEWAY=192.168.35.51:8080        ipfs.ls.recursive "${cid}" 2> /dev/null))"
    echo "VPS1          $(wc -l < <(IPFS_HTTP_GATEWAY=https://vps1.phillm.net   ipfs.ls.recursive "${cid}" 2> /dev/null))"
    echo "VPS2          $(wc -l < <(IPFS_HTTP_GATEWAY=https://vps2.phillm.net   ipfs.ls.recursive "${cid}" 2> /dev/null))"
    echo "VPS3          $(wc -l < <(IPFS_HTTP_GATEWAY=https://vps3.phillm.net   ipfs.ls.recursive "${cid}" 2> /dev/null))"
    echo "$(date) Done"
}

function public.anime.archiveone () {

    SOURCE=kore-ssh:/callisto/Data/Upload/TV-Shows/Anime
    DEST=b2-phill:Video-Archive2/TV-Shows/Anime
    FILES=$(mktemp --tmpdir=/dev/shm)

    trap 'rm -fv -- "${FILES}"*' ERR
    trap 'rm -fv -- "${FILES}"*' EXIT

    rclone lsf --files-only --recursive "${SOURCE}" | tee "${FILES}"

    while [ -s "${FILES}" ]; do
        # Get the first 1
        head -n 1 "${FILES}" > "${FILES}-batch"
        # Cut the 1 off the top of `${FILES}`
        tail -n +2 "${FILES}" > "${FILES}-new"
        mv -v "${FILES}-new" "${FILES}"

        # Now transfer the data
        rclone move -vvv --files-from-raw "${FILES}-batch" "${SOURCE}" "${DEST}"
        read -p "Press enter to continue"
    done
}

function public.anime.archiveone.reverse () {

    local SOURCE
    local DEST
    local FILES

    SOURCE=kore-ssh:/callisto/Data/Upload/TV-Shows/Anime
    DEST=b2-phill:Video-Archive2/TV-Shows/Anime
    FILES=$(mktemp --tmpdir=/dev/shm)

    trap 'rm -fv -- "${FILES}"*' ERR
    trap 'rm -fv -- "${FILES}"*' EXIT

    rclone lsf --files-only --recursive "${SOURCE}" | tee "${FILES}"

    while [ -s "${FILES}" ]; do

        # Get the last 1
        tail -n 1 "${FILES}" > "${FILES}-batch"

        # Now transfer the data
        rclone move -vvv --files-from-raw "${FILES}-batch" "${SOURCE}" "${DEST}"
        read -p "Press enter to continue"
        rclone lsf --files-only --recursive "${SOURCE}" | tee "${FILES}"
    done
}

export -f public.root.hash
export -f public.pins.missing.local
export -f public.pins.monitor
export -f public.list.preload
