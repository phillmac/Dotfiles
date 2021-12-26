#! /bin/bash


function masonry.publish ()
{
    docker pull phillmac/ipfs-masonry-publish >&2

    if [[ "$(docker network ls --format '{{.Name}}')" = *"phill-dev_ipfs"* ]]
    then
        docker run --rm --net phill-dev_ipfs phillmac/ipfs-masonry-publish "${@}";
    else
        docker run --rm --net pvs-dev_ipfs phillmac/ipfs-masonry-publish "${@}";
    fi
}

function archive.ipns.update () {

    local update_ipns_record
    local update_query_addr

    update_ipns_record=${1:-${UPDATE_IPNS_RECORD}}

    update_query_addr=${2:-${UPDATE_IPNS_QUERY_ADDR}}


    if [[ -z "${update_query_addr}" ]];
    then
        echo "UPDATE_IPNS_QUERY_ADDR is required" >&2
        return 252
    fi

    docker run --rm --net host\
        -e "CF_TOKEN=jloiYa7e-B29xbQi3um34m9NyWeUGcdLS3RY1u6V" \
        -e "CF_ZONE_NAME=ipfs-archive.online" \
        -e "CF_RECORD=${update_ipns_record}" \
        -e "IPFS_KEY=${update_query_addr}" \
        peelvalley/cloudflare scripts/update-ipns.py
}

function archive.pin () {
    local ipfs_pin_addr
    local path_filter

    ipfs_pin_addr=${1:-${IPFS_PIN_ADDR}}
    path_filter=${2:-${ipfs_pin_addr}/.*/}

    if [[ -z "${ipfs_pin_addr}" ]]
    then
        echo "IPFS pin addr is required" >&2
        return 252
    fi

    while read -r itemhash pathname
    do
        echo "$(date) Pinning folder ${pathname}" >&2
        ipfs pin add --progress "${itemhash}"
    done < <(ipfs.ls.recursive.dirs.filtered "${ipfs_pin_addr}" "${path_filter}")
}

#shellcheck disable=SC2120
function archive.entries () {
    local entries_addr
    local path_filter
    local entries_addr_resolved

    entries_addr=${1:-${ARCHIVE_ENTRIES_ADDR}}
    entries_addr=${entries_addr:-/ipns/staging.ipfs-archive.online/Archive/DA}
    entries_addr_resolved=$(ipfs resolve --timeout 10m "${entries_addr}")
    path_filter=${2:-${entries_addr_resolved}/.*/}


    if [[ -z "${entries_addr_resolved}" ]]
    then
        echo "IPFS entries addr is required" >&2
        return 252
    fi

    while read -r itemhash pathname
    do
        echo "$(date) Found item ${itemhash} ${pathname}" >&2
        echo "${itemhash}"
    done < <(ipfs.ls.recursive.dirs.filtered "${entries_addr_resolved}" "${path_filter}")
}

function archive.pin.ls ()
{
    local docker_host
    local docker_net

    docker_host=${1:-${ARCHIVE_PIN_LS_HOST}}
    docker_net=${2:-${ARCHIVE_PIN_LS_NET}}
    cut -f 1 -d ' ' < <(
        docker \
            run --rm -it \
                --net "${docker_net}" \
                docker sh -c \
                "docker --host ${docker_host}:2377 \
                    run \
                        --rm -it \
                        --net phill-dev_ipfs \
                        peelvalley/ipfs-cli \
                        pin ls --type=recursive"
    )
}

export -f masonry.publish
export -f archive.ipns.update
export -f archive.pin
export -f archive.entries
export -f archive.pin.ls
