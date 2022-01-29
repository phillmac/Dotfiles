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

function archive.publish.dev ()
{
    local masonry_cid
    local settings_cid
    local dev_cid

    masonry_cid=$(masonry.publish -Q)
    settings_cid=$(cd /ananke/D/Source/Phill/Repos/Phill/masonry-settings && ipfs add -r -Q --pin=false .)

    ipfs files rm -r /dev.ipfs-archive.online/galleries
    ipfs files cp "/ipfs/${masonry_cid}" /dev.ipfs-archive.online/galleries

    ipfs files rm -r /dev.ipfs-archive.online/settings
    ipfs files cp "/ipfs/${settings_cid}" /dev.ipfs-archive.online/settings

    dev_cid=$(ipfs files stat --hash /dev.ipfs-archive.online)

    archive.ipns.update dev "${dev_cid}"

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

    archive.entries "${1}" | sort --unique > archive.cids.txt

    for h in "${hosts[@]}"
    do
        echo "$(date) Listing pins for ${h}" >&2
        echo '' > "archive.pins.${h}.txt"
        archive.pin.ls "${h}" phill-dev_default | sort --unique > "archive.pins.${h}.txt"
        pinned_count=$(wc -l  < "archive.pins.${h}.txt")

        if ((pinned_count <= 1))
        then
            echo "Error: pin count too low" >&2
        else
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
                date
            done < <( comm -23 archive.cids.txt "archive.pins.${h}.txt")
        fi
    done
}

function archive.pins.missing.pvs () {
    local hosts
    local pin_count
    local archive_addr

    hosts=("docker-charon" "docker-titan" "docker-carpo")

    archive_addr=${1:-$(archive.root.hash)}

    archive.entries "${archive_addr}" | sort --unique > archive.cids.txt

    for h in "${hosts[@]}"
    do
        echo "$(date) Listing pins for ${h}" >&2
        archive.pin.ls "${h}" pvs-dev_scheduler | sort --unique > "archive.pins.${h}.txt"
        pin_count=$(wc -l < "archive.pins.${h}.txt")
        if ((pin_count > 0))
        then
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
                date
            done < <( comm -23 archive.cids.txt "archive.pins.${h}.txt")
        else
            echo "Pincount is 0. Skipping pins for host ${h}" >&2
        fi
    done
}



function archive.root.hash () {
    curl -s --fail 'https://ipfs-admin.phillm.net/api/v0/files/stat?hash=true&arg=/ipfs-archive.online' | jq -r .Hash
}

function archive.list.preload ()
{
    local cid
    cid=$( archive.root.hash )
    echo "Janus" && IPFS_HTTP_GATEWAY=192.168.42.208:8080 ipfs.ls.recursive "${cid}"
    echo "Carpo" && IPFS_HTTP_GATEWAY=192.168.50.53:8080 ipfs.ls.recursive "${cid}"
    echo "Charon" && IPFS_HTTP_GATEWAY=192.168.30.57:8080 ipfs.ls.recursive "${cid}"
    echo "Io" && IPFS_HTTP_GATEWAY=http://192.168.20.33:8080 ipfs.ls.recursive "${cid}"
    echo "Titan" && IPFS_HTTP_GATEWAY=192.168.35.51:8080 ipfs.ls.recursive "${cid}"
    echo "VPS1" && IPFS_HTTP_GATEWAY=https://vps1.phillm.net ipfs.ls.recursive "${cid}"
    echo "VPS2" && IPFS_HTTP_GATEWAY=https://vps2.phillm.net ipfs.ls.recursive "${cid}"
    echo "VPS3" && IPFS_HTTP_GATEWAY=https://vps3.phillm.net ipfs.ls.recursive "${cid}"
    echo "$(date) Done"
}
