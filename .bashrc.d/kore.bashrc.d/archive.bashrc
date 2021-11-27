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

function db.monitor.logs ()
{
    local hosts

    hosts=("docker-vps1" "docker-vps2"  "docker-vps3")
    for h in "${hosts[@]}"
    do
        docker run --rm --net phill-dev_default docker sh -c "docker --host ${h}:2377 logs --tail 100 phill-dev_db-monitor_1"
    done
}

function reverse-proxy.logs () {
    docker run --rm -it --net phill-dev_default docker sh -c "docker --host ${1}:2377 logs -f --tail 100 phill-dev_reverse-proxy_1"
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

function archive.publish ()
{
    archive.ipns.update '' /ipns/staging.ipfs-archive.online
    archive.ipns.update staging "$(ipfs files stat --hash /ipfs-archive.online)"
}

function archive.add.da () {
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

function archive.stats ()
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

function archive.pins.missing () {
    local hosts
    local pinned_count

    hosts=("docker-vps1" "docker-vps2" "docker-vps3")

    archive.entries | sort --unique > archive.entries.txt

    for h in "${hosts[@]}"
    do
        echo "$(date) Listing pins for ${h}" >&2
        echo '' > "archive.pins.${h}.txt"
        archive.pin.ls "${h}" phill-dev_default | sort --unique > "archive.pins.${h}.txt"
        pinned_count=$(wc -l  "archive.pins.${h}.txt")

        if ((pinned_count <= 1))
        then
            echo "Error: pin count too low" >&2
        else
            while read -r pincid
            do
                echo "${h} missing item ${pincid}" >&2

                docker run --rm -i --net phill-dev_default docker sh -c \
                    "docker --host ${h}:2377 \
                        run \
                        --rm -i --net phill-dev_ipfs \
                        peelvalley/ipfs-cli \
                            pin add \
                                --progress \
                                --timeout 2h \
                                ${pincid}"
                date
            done < <( comm -23 archive.entries.txt "archive.pins.${h}.txt")
        fi
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

            docker run --rm -i --net pvs-dev_scheduler docker sh -c \
                "docker --host ${h}:2377 \
                    run \
                    --rm -i --net phill-dev_ipfs \
                    peelvalley/ipfs-cli \
                        pin add \
                            --progress \
                            --timeout 2h \
                            ${pincid}"
            date
        done < <( comm -23 archive.entries.txt "archive.pins.${h}.txt")
    done
}

