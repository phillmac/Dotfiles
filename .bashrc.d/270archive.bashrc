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

function masonry.dev.combine ()
{
    local masonry_cid
    local settings_cid
    local empty_dir
    local intermediate
    local result

    empty_dir=$(ipfs object new unixfs-dir)
    echo 'Adding masonry'
    masonry_cid=$(masonry.publish -Q)

    echo 'Adding galleries'
    intermediate=$(ipfs object patch "${empty_dir}" add-link galleries "${masonry_cid}")
    echo "Intermediate dir ${intermediate}"

    echo 'Adding favourites'
    intermediate=$(ipfs object patch "${intermediate}" add-link favourites "${masonry_cid}")
    echo "Intermediate dir ${intermediate}"

    echo 'Adding dmca.txt'
    intermediate=$(ipfs object patch "${intermediate}" add-link dmca.txt QmRai1uve3mF137HXYqVvP5vCAWrD8ZRPVRfn8onsYUFAb )
    echo "Intermediate dir ${intermediate}"

    echo 'Adding copyright.txt'
    intermediate=$(ipfs object patch "${intermediate}" add-link copyright.txt QmRai1uve3mF137HXYqVvP5vCAWrD8ZRPVRfn8onsYUFAb )
    echo "Intermediate dir ${intermediate}"

    echo 'Adding robots.txt'
    intermediate=$(ipfs object patch "${intermediate}" add-link robots.txt QmSiUsNRrkDi3ERbsuxjTGz8N6EZe9n997sUxyFNUGBMaG )
    echo "Intermediate dir ${intermediate}"

    echo 'Adding Archive'
    arcive_cid=$(ipfs.resolve /ipns/staging.ipfs-archive.online/Archive)

    intermediate=$(ipfs object patch "${intermediate}" add-link Archive "${arcive_cid}" )
    echo "Intermediate dir ${intermediate}"

    echo 'Adding settings'
    settings_cid=$(cd /ananke/D/Source/Phill/Repos/Phill/masonry-settings && ipfs add -r -Q --pin=false .)

    result=$(ipfs object patch "${intermediate}" add-link settings "${settings_cid}")
    echo "Result dir ${result}"

    echo "https://ipfs.io/ipfs/${result}"
    echo "https://cf-ipfs.com/ipfs/${result}"

    curl "http://external1.ddns.peelvalley.com.au:8081/api/v0/get?arg=${result}" > /dev/null
    curl "http://192.168.30.57:8080/api/v0/get?arg=${result}" > /dev/null
    curl "http://external7.ddns.peelvalley.com.au:8080/api/v0/get?arg=${result}" > /dev/null
    curl "http://io2.phillm.net:8080/api/v0/get?arg=${result}" > /dev/null
    curl "http://external5.ddns.peelvalley.com.au:8080/api/v0/get?arg=${result}" > /dev/null
    curl "http://api.vps1.ipfs-archive.online:8080/api/v0/get?arg=${result}" > /dev/null
    curl "http://api.vps2.ipfs-archive.online:8080/api/v0/get?arg=${result}" > /dev/null
    curl "http://api.vps3.ipfs-archive.online:8080/api/v0/get?arg=${result}" > /dev/null
    curl "http://external1.ddns.peelvalley.com.au:8080/api/v0/get?arg=${result}" > /dev/null

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
    local pin_addr
    local path_filter

    pin_addr=${1:-${ARCHIVE_PIN_ADDR}}
    path_filter=${2:-${pin_addr}/.*/}

    if [[ -z "${pin_addr}" ]]
    then
        echo "IPFS pin addr is required" >&2
        return 252
    fi

    while read -r itemhash pathname
    do
        echo "$(date) Pinning folder ${pathname}" >&2
        ipfs pin add --progress "${itemhash}"
    done < <(ipfs.ls.recursive.dirs.filtered "${pin_addr}" "${path_filter}")
}

#shellcheck disable=SC2120
function archive.entries () {
    local entries_addr
    local path_filter
    local entries_addr_resolved

    entries_addr=${1:-${ARCHIVE_ENTRIES_ADDR}}
    entries_addr=${entries_addr:-/ipns/staging.ipfs-archive.online/Archive/DA}
    entries_addr_resolved=$(ipfs.resolve "${entries_addr}")
    path_filter=${2:-${entries_addr_resolved}/.*/}

    if [[ -z "${entries_addr_resolved}" ]]
    then
        echo "IPFS entries addr is required" >&2
        return 252
    fi

    echo '' > archive.entries.txt

    while read -r itemhash pathname
    do
        echo "$(date) Found item ${itemhash} ${pathname}" >&2
        echo "${itemhash} ${pathname}" >> archive.entries.txt
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

function archive.root.hash () {
    curl -s --fail 'https://ipfs-admin.phillm.net/api/v0/files/stat?hash=true&arg=/ipfs-archive.online' | jq -r .Hash
}

function archive.pin.add.local () {
    if [[ -n "${ARCHIVE_DAG_EXPORT_GATEWAY}" ]]
    then
       while ! docker run \
                --rm \
                --net host \
                curlimages/curl curl --fail \
                    "${ARCHIVE_DAG_EXPORT_GATEWAY}/${IPFS_API}/dag/export?arg=${1}" > "${1}"
        do
            date >&2
            sleep 30m
        done

        ipfs.dag.import < <( mbuffer < "${1}")
        rm -v "${1}"

    else
        _ipfs pin add --progress --timeout "${IPFS_PIN_TIMEOUT}" "${1}"
    fi
}

function archive.pins.missing.local () {
    local pinned_count
    local entry
    local archive_addr

    archive_addr=${1:-$(archive.root.hash)/Archive/DA}

    archive.entries "${archive_addr}" | sort --unique > archive.entries.cids.txt

    ipfs pin ls --type=recursive | cut -f 1 -d ' ' | sort --unique > ipfs.pins.local.txt
    pinned_count=$(wc -l  < ipfs.pins.local.txt)

    if ((pinned_count <= 1))
    then
        echo "Error: pin count too low" >&2
    else
        while read -r pincid
        do
            entry=$(grep "${pincid}" archive.entries.txt)
            echo "Missing pin item ${entry}" >&2

            archive.pin.add.local "${pincid}"
            date
        done < <( comm -23  archive.entries.cids.txt ipfs.pins.local.txt)
    fi
}

export -f masonry.publish
export -f archive.ipns.update
export -f archive.pin
export -f archive.entries
export -f archive.pin.ls
export -f archive.root.hash
export -f archive.pins.missing.local
