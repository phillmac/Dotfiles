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