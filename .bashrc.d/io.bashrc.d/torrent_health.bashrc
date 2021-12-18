#!/bin/bash

function update_scimag ()
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