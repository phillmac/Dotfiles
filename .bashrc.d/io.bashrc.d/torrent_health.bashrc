#!/bin/bash

function update_fiction ()
{
    docker run --rm --net phill-dev_redis -e "REDIS_HOST=redis" -e "REDIS_PORT=6379" phillmac/torrent-health-scraper scripts/update.sh 'https://libgen.rs/fiction/repository_torrent/' fiction
}

function update_scimag ()
{
    for repo_url in 'http://libgen.rs/scimag/repository_torrent/smarch/' 'https://libgen.rs/scimag/repository_torrent/'
    do
        docker run --rm --net phill-dev_redis -e "REDIS_HOST=redis" -e "REDIS_PORT=6379" phillmac/torrent-health-scraper scripts/update.sh  "${repo_url}" scimag
    done
}

function update_books ()
{
    docker run --rm --net phill-dev_redis -e "REDIS_HOST=redis" -e "REDIS_PORT=6379" phillmac/torrent-health-scraper scripts/update.sh 'https://libgen.rs/repository_torrent/' books
}


function get-stats ()
{
    docker run \
        --rm \
        --net host \
        curlimages/curl curl --fail --silent https://oasiscraft.org/oasiscraft/torrent-health-frontend/stats-tracker-age.php
}

function format-stats ()
{
    jq -r '.[] | "\(.infohash) \(.average)"'
}

function prune-queue ()
{
    date_now=$(date +%s)
    while read -r hash scraped
    do
        if (( scraped+86400 < date_now ))
        then

           echo "${hash}"
           docker exec phill-dev_redis_1 redis-cli srem queue "${hash}"
        fi
    done

}

function fix_stuck_queue ()
{
    get-stats | format-stats | prune-queue
}
