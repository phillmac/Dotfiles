#! /bin/bash

function restart-archive-servers ()
{

    local hosts
    local services
    local h
    local s

    hosts=("docker-vps1" "docker-vps2" "docker-vps3")

    services=('ipfs' 'reverse-proxy' 'orbitdb-api' 'db-monitor')

    for h in "${hosts[@]}"
    do
        docker run --rm --net phill-dev_default docker sh -c "docker --host ${h}:2377 exec phill-dev_ipfs_1 ipfs shutdown"
        echo 'ipfs shutdown complete'
        for s in "${services[@]}"
        do
            echo "$(date) Restarting ${h} ${s}"
            docker run --rm --net phill-dev_default docker sh -c "docker --host ${h}:2377 restart phill-dev_${s}_1"
            sleep 30
        done
    done
}

function db_monitor_logs ()
{
    local hosts

    hosts=("docker-vps1" "docker-vps2"  "docker-vps3")
    for h in "${hosts[@]}"
    do
        docker run --rm --net phill-dev_default docker sh -c "docker --host ${h}:2377 logs --tail 100 phill-dev_db-monitor_1"
    done
}

function db.open.remote ()
{
    local hosts

    hosts=("docker-vps1" "docker-vps2"  "docker-vps3")
    for h in "${hosts[@]}"
    do
        docker run --rm --net phill-dev_default docker sh -c "docker --host ${h}:2377 exec phill-dev_db-monitor_1 bash -c 'source /scripts/functions.sh && db.open ${1}'"
    done
}


function db.get.contents.remote ()
{
    local hosts

    hosts=("docker-vps1" "docker-vps2"  "docker-vps3")
    for h in "${hosts[@]}"
    do
        docker run --rm --net phill-dev_default docker sh -c "docker --host ${h}:2377 exec phill-dev_db-monitor_1 bash -c 'source /scripts/functions.sh && db.get.contents ${1}'"
    done
}

function ipfs.pin.add.remote ()
{
    local hosts

    hosts=("docker-vps1" "docker-vps2"  "docker-vps3")
    for h in "${hosts[@]}"
    do
        docker run --rm --net phill-dev_default docker sh -c "docker --host ${h}:2377 exec phill-dev_ipfs_1 sh -c 'ipfs pin add --progress ${*}'"
    done
}

function ipfs_masonry_publish ()
{
    docker pull phillmac/ipfs-masonry-publish >&2

    if [[ "$(docker network ls --format '{{.Name}}')" = *"phill-dev_ipfs"* ]]
    then
        docker run --rm --net phill-dev_ipfs phillmac/ipfs-masonry-publish "${@}";
    else
        docker run --rm --net pvs-dev_ipfs phillmac/ipfs-masonry-publish "${@}";
    fi
}

function archive_update_ipns () {

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

function ipfs_masonry_deploy_dev ()
{
    local masonry_cid
    local dev_cid

    masonry_cid=$(ipfs_masonry_publish -Q)

    ipfs files rm -r /dev.ipfs-archive.online/galleries
    ipfs files cp "/ipfs/${masonry_cid}" /dev.ipfs-archive.online/galleries

    dev_cid=$(ipfs files stat --hash /dev.ipfs-archive.online)

    archive_update_ipns dev "${dev_cid}"

}

function ipfs_archive_publish ()
{
    archive_update_ipns '' /ipns/staging.ipfs-archive.online
    archive_update_ipns staging "$(ipfs files stat --hash /ipfs-archive.online)"
}

function ipfs_archive_add () {
    (
        local artist_name

        artist_name=${1}

        if [[ -z "${artist_name}" ]]
        then
            read -r -p 'Enter artist name: ' artist_name
        fi
        cd "/callisto/Data/Phill/_/DA Artists" \
        && (
            cd "${artist_name}/gallery" \
            && docker run --rm --net none \
                -v "$(pwd)":/wd \
                -w /wd \
                peelvalley/imagemagick bash -c "source /scripts/functions.sh && generate-thumbs"
            # &&  python3 /callisto/Data/Scripts/Python/rename-thumbs.py
        ) \
        && ipfs add --pin=false --progress -r -w "${artist_name}"
        echo
    )
}

function archive.pin.remote ()
{
    local hosts
    local pinner_version=pinner-v1.1.0
    local archive_addr

    archive_addr=${1:-/ipns/ipfs-archive.online/Archive/DA}


    hosts=("docker-vps1" "docker-vps2" "docker-vps3")

    for h in "${hosts[@]}"
    do
        echo "Pining on ${h}"
        docker run --rm --net phill-dev_default docker sh -c \
            "docker --host ${h}:2377 pull peelvalley/ipfs-cli:${pinner_version}"

        docker run --rm -it --net phill-dev_default docker sh -c \
            "docker --host ${h}:2377 \
                run \
                --rm  -it --net phill-dev_ipfs \
                -e 'IPFS_HTTP_GATEWAY=http://ipfs:8080' \
                --entrypoint bash peelvalley/ipfs-cli:${pinner_version} \
                -c 'source /scripts/functions.sh \
                && ipfs.pin.recursive ${archive_addr}'"
    done
}

function archive.pin.remote.pvs ()
{
    local hosts
    local pinner_version=pinner-v1.1.0
    local archive_addr

    archive_addr=${1:-/ipns/ipfs-archive.online/Archive/DA}


    hosts=("docker-charon" "docker-titan")

    for h in "${hosts[@]}"
    do
        echo "Pining on ${h}"
        docker run --rm --net pvs-dev_scheduler docker sh -c \
            "docker --host ${h}:2377 pull peelvalley/ipfs-cli:${pinner_version}"

        docker run --rm -it --net pvs-dev_scheduler docker sh -c \
            "docker --host ${h}:2377 \
                run \
                --rm  -it --net phill-dev_ipfs \
                -e 'IPFS_HTTP_GATEWAY=http://ipfs:8080' \
                --entrypoint bash peelvalley/ipfs-cli:${pinner_version} \
                -c 'source /scripts/functions.sh \
                && ipfs.pin.recursive ${archive_addr}'"
    done
}

function archive.stats.remote ()
{
    local hosts

    hosts=("docker-vps1" "docker-vps2" "docker-vps3")

    for h in "${hosts[@]}"
    do
        echo "Stats for ${h}"

        docker run --rm -it --net phill-dev_default docker sh -c \
            "docker --host ${h}:2377 \
                run \
                    --rm -it \
                    --net phill-dev_ipfs \
                    peelvalley/ipfs-cli \
                        repo stat \
                            --size-only \
                            --human"
    done
}

function archive.stats.pvs ()
{
    local hosts

    hosts=("docker-charon" "docker-titan" "docker-io")

    for h in "${hosts[@]}"
    do
        echo "Stats for ${h}"

        docker run --rm -it --net pvs-dev_scheduler docker sh -c \
            "docker --host ${h}:2377 \
                run \
                    --rm -it \
                    --net phill-dev_ipfs \
                    peelvalley/ipfs-cli \
                        repo stat \
                            --size-only \
                            --human"
    done
}

function archive.dag.get ()
{
    local hosts
    local dag_addr

    dag_addr=${1:-/ipns/ipfs-archive.online/Archive/DA}


    hosts=("docker-vps1" "docker-vps2" "docker-vps3")

    for h in "${hosts[@]}"
    do
        echo "Fetching dag on ${h}"

        docker run --rm -it --net phill-dev_default docker sh -c \
            "docker --host ${h}:2377 exec phill-dev_ipfs_1 ipfs dag get ${dag_addr}"
    done
}

function archive.dag.get.pvs ()
{
    local hosts
    local dag_addr

    dag_addr=${1:-/ipns/ipfs-archive.online/Archive/DA}


    hosts=("docker-charon" "docker-titan" "docker-io")

    for h in "${hosts[@]}"
    do
        echo "Fetching dag on ${h}"

        docker run --rm -it --net pvs-dev_scheduler docker sh -c \
            "docker --host ${h}:2377 exec phill-dev_ipfs_1 ipfs dag get ${dag_addr}"
    done
}

function archive.dht.provide ()
{
    local hosts
    local provide_addr
    local cid

    provide_addr=${1:-/ipns/ipfs-archive.online/Archive/DA}

    cid=$(ipfs resolve "${provide_addr}" --timeout "${IPFS_RESOLVE_TIMEOUT}" | sed 's/\/ipfs\///g' /dev/stdin)

    hosts=("docker-vps1" "docker-vps2" "docker-vps3")

    for h in "${hosts[@]}"
    do
        echo "$(date) Providing ${cid} on ${h}"

        docker run --rm -it --net phill-dev_default docker sh -c \
            "docker --host ${h}:2377 \
            run \
              --rm -it \
              --net phill-dev_ipfs \
              peelvalley/ipfs-cli \
              dht provide \
                --verbose \
                --timeout 10m \
                ${cid}"
        echo "$(date) Done"
    done
}

function archive.dht.provide.pvs ()
{
    local hosts
    local provide_addr
    local cid

    provide_addr=${1:-/ipns/ipfs-archive.online/Archive/DA}

    cid=$(ipfs resolve "${provide_addr}" --timeout "${IPFS_RESOLVE_TIMEOUT}" | sed 's/\/ipfs\///g' /dev/stdin)

    hosts=("docker-charon" "docker-titan" "docker-io")

    for h in "${hosts[@]}"
    do
        echo "$(date) Providing ${cid} on ${h}"

        docker run --rm -it --net pvs-dev_scheduler docker sh -c \
            "docker --host ${h}:2377 \
            run \
              --rm -it \
              --net phill-dev_ipfs \
              peelvalley/ipfs-cli \
              dht provide \
                --verbose \
                --timeout 10m \
                ${cid}"
        echo "$(date) Done"
    done
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

function archive.entries () {
    local ipfs_entries_addr
    local path_filter

    ipfs_entries_addr=${1:-${IPFS_ENTRIES_ADDR}}
    ipfs_entries_addr=${ipfs_entries_addr:-/ipns/staging.ipfs-archive.online/Archive/DA}
    path_filter=${2:-${ipfs_entries_addr}/.*/}

    if [[ -z "${ipfs_entries_addr}" ]]
    then
        echo "IPFS entries addr is required" >&2
        return 252
    fi

    while read -r itemhash pathname
    do
        echo "$(date) Found item ${itemhash} ${pathname}" >&2
        echo "${itemhash}"
    done < <(ipfs.ls.recursive.dirs.filtered "${ipfs_entries_addr}" "${path_filter}")
}

function archive.pin.ls ()
{
    local docker_host
    local docker_net

    docker_host=${1:-${ARCHIVE_PIN_LS_HOST}}
    docker_net=${2:-${ARCHIVE_PIN_LS_NET}}
    while read -r cid pintype
    do
        echo "${cid}"
    done < <(
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

function archive.pins.missing () {
    local hosts

    hosts=("docker-vps1" "docker-vps2" "docker-vps3")

    archive.entries | sort --unique > archive.entries.txt

    for h in "${hosts[@]}"
    do
        echo "$(date) Listing pins for ${h}" >&2
        echo '' > "archive.pins.${h}.txt"
        archive.pin.ls "${h}" phill-dev_default | sort --unique > "archive.pins.${h}.txt"
        while read -r pincid
        do
            echo "${h} missing item ${pincid}" >&2

            docker run --rm --net phill-dev_default docker sh -c \
                "docker --host ${h}:2377 \
                    run \
                    --rm --net phill-dev_ipfs \
                    peelvalley/ipfs-cli \
                        pin add \
                            --progress \
                            --timeout 2h \
                            ${pincid}"
        done < <( comm -23 archive.entries.txt "archive.pins.${h}.txt")
    done
}

function archive.pins.missing.pvs () {
    local hosts

    hosts=("docker-charon" "docker-titan")

    archive.entries | sort --unique > archive.entries.txt

    for h in "${hosts[@]}"
    do
        echo "$(date) Listing pins for ${h}" >&2
        echo '' > "archive.pins.${h}.txt"
        archive.pin.ls "${h}" pvs-dev_scheduler | sort --unique > "archive.pins.${h}.txt"
        while read -r pincid
        do
            echo "${h} missing item ${pincid}" >&2

            docker run --rm --net pvs-dev_scheduler docker sh -c \
                "docker --host ${h}:2377 \
                    run \
                    --rm --net phill-dev_ipfs \
                    peelvalley/ipfs-cli \
                        pin add \
                            --progress \
                            --timeout 2h \
                            ${pincid}"
        done < <( comm -23 archive.entries.txt "archive.pins.${h}.txt")
    done
}

export -f archive.pin
export -f archive.entries
