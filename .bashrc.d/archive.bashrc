#! /bin/bash

function restart-archive-servers ()
{

    local hosts
    local services
    local h
    local s

    hosts=("docker-vps1" "docker-vps2"  "docker-vps3")

    services=('reverse-proxy' 'ipfs' 'orbitdb-api' 'db-monitor')

    for h in "${hosts[@]}"
    do
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