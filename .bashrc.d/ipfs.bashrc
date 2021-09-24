#! /bin/bash

function ipfs.get.recursive () {
    local itemhash
    local itempath
    local gw_addr

    gw_addr=${2:-${IPFS_HTTP_GATEWAY}}

    if [[ -z "${gw_addr}" ]];
    then
        echo "IPFS_HTTP_GATEWAY is required" >&2
        return 252
    fi

    while read -r itemhash itempath
    do
        echo "$(date) Fetching ${itempath}" >&2
        url="${gw_addr}/ipfs/${itemhash}"

        [[ -n "${IPFS_DEBUG}" ]] &&  echo "url is ${url}" >&2

        _curl "${url}" > /dev/null
    done < <(ipfs.ls.recursive "${1}")
}

function ipfs.ls.recursive () {
    local entries
    local itemtype
    local itemhash
    local itemname

    echo "$(date) Resolving ${*}" >&2
    entries=$(ipfs.ls "${*}" | ipfs.links.info)
    while read -r itemtype itemhash itemname
    do
        if [[ -n "${itemname}" ]]
        then
            echo "${itemhash}" "${1}/${itemname}"
            if (( itemtype == 1))
            then
                ipfs.ls.recursive "${1}/${itemname}"
            fi
        fi
    done <<< "${entries}"
}

function ipfs.ls.recursive.dirs () {
    local entries
    local itemtype
    local itemhash
    local itemname

    echo "$(date) Resolving ${*}" >&2
    entries=$(ipfs.ls "${*}" | ipfs.links.info)
    while read -r itemtype itemhash itemname
    do
        if (( itemtype == 1))
        then
            echo "${itemhash}" "${1}/${itemname}"
            ipfs.ls.recursive.dirs "${1}/${itemname}"
        fi
    done <<< "${entries}"
}

function ipfs.ls.recursive.dirs () {
    local itemtype
    local itemhash
    local itemname

    echo "$(date) Resolving ${*}" >&2

    while read -r itemtype itemhash itemname
    do
        if (( itemtype == 1))
        then
            echo "${itemhash}" "${1}/${itemname}"
            ipfs.ls.recursive.dirs "${1}/${itemname}"
        fi
    done < <(ipfs.ls "${*}" | ipfs.links.info)
}

function ipfs.ls.recursive.dirs.filtered () {
    local filter
    local addr

    addr=${1:-$IPFS_ADDR}
    filter=${2:-$IPFS_FILTER}

    if [[ -z "${addr}" ]];
    then
        echo "IPFS addr is required" >&2
        return 252
    fi

    if [[ -z "${filter}" ]];
    then
        echo "IPFS filter is required" >&2
        return 252
    fi

    echo "filter is ${filter}" >&2

    ipfs.ls.recursive.dirs "${addr}" | grep "${filter}"
}


function ipfs.ls () {
    local addr
    local addr_encoded
    local url
    local result

    addr=${1:-$IPFS_ADDR}

    if [[ -z "${addr}" ]];
    then
        echo "IPFS addr is required" >&2
        return 252
    fi

    addr_encoded=$(rawurlencode "${addr}")

    [[ -n "${IPFS_DEBUG}" ]] &&  echo "addr_encoded is ${addr_encoded}" >&2

    url="${IPFS_HTTP_GATEWAY}/${IPFS_API}/ls?arg=${addr_encoded}"
    [[ -n "${IPFS_DEBUG}" ]] &&  echo "url is ${url}" >&2

    result=$(_curl "${url}")

    jq -r ".Objects[].Links" <<< "${result}"
}

function ipfs.links.info ()
{
    jq -r '.[] | "\(.Type) \(.Hash) \(.Name)"'
}

function ipfs.pin.ls () {
    ipfs pin ls --type=recursive | sort > pins.txt
}

function containsElement ()
{
  local e match="$1"
  shift
  for e; do [[ "$e" == "$match" ]] && return 0; done
  return 1
}

function ipfs.pins.prune () {
    local pinHash
    local pinItem
    local action
    local total
    local pcount
    local keepPins
    local pinsList

    keepPins=()
    pinsList=()

    test -p inp || mkfifo inp

    total=$(wc -l < pins.txt)
    pcount=1

    ipfs.pin.ls
    echo '' > ipfs.pins.remove.txt

    while read -r keepItem
    do
        keepPins+=("${keepItem}")
    done < pins.keep.txt

    while read -r pinHash pintype
    do
        pinsList+=("${pinHash}")
    done < pins.txt

    for pinItem in "${pinsList[@]}"
    do
        if ! containsElement "${pinItem}" "${keepPins[@]}"
        then
            echo "Hash is ${pinItem} [${pcount}/${total}]" >&2
            grep "${pinItem}" ipfs.dirs.hashes
            read -r -p "Action: " action
            [[ "${action}" == "q" ]] && return
            [[ "${action}" == "y" ]] && echo "${pinItem}" >> ipfs.pins.remove.txt
        fi
        ((pcount++))
    done
}

function ipfs.pins.details () {
    local pinHash
    local total
    local pcount

    total=$(wc -l < pins.txt)
    pcount=1

    while read -r pinHash pintype
    do
        echo "Hash is ${pinHash} ${pintype} [${pcount}/${total}]" >&2
        ipfs.ls "${pinHash}" | ipfs.links.info
        ((pcount++))
    done < pins.txt 2>&1 | tee pins.details.txt
}

function check_lockout_time () {
    local currenttime

    if [[ -z  "${IPFS_PIN_ALLOWED_START}" ]] || [[ -z "${IPFS_PIN_ALLOWED_FIN}" ]]
    then
        return 0
    fi

    currenttime=$(date +%H:%M)

    if [[ "${currenttime}" > "${IPFS_PIN_ALLOWED_START}" ]] || [[ "${currenttime}" < "${IPFS_PIN_ALLOWED_FIN}" ]]
    then
        return 0
    fi

    return 1
}

function ipfs.pin.dirs.filtered () {
    local currenttime
    local rlast
    local ipns
    local filter
    local rnew
    local pin_timeout
    local resolve_timeout
    local sleep_delay
    local itemhash
    local pathname
    ipns=${1:-$IPFS_PIN_HASH}
    filter=${2:-$IPFS_PIN_FILTER}
    pin_timeout=${3:-$IPFS_PIN_TIMEOUT}
    resolve_timeout=${4:-$IPFS_RESOLVE_TIMEOUT}
    sleep_delay=${5:-$IPFS_PIN_SLEEP}

    if [[ -z "${ipns}" ]]
    then
        echo "ipns addr is required" >&2
        return 252
    fi

    if [[ -z "${filter}" ]];
    then
        echo "IPFS filter is required" >&2
        return 252
    fi

    echo "filter is ${filter}" >&2

    while true
    do
        if rnew=$(ipfs resolve --timeout "${resolve_timeout}" "${ipns}")
        then
            if ! check_lockout_time || [[ "${rlast}" == "${rnew}" ]]
            then
                sleep "${sleep_delay}"
                continue
            fi
            echo "Pinning ${rnew}" >&2
            while read -r itemhash pathname
            do
                echo "Pinning folder ${pathname}" >&2
                ipfs pin add --progress "${itemhash}"
            done < <(ipfs.ls.recursive.dirs.filtered "${ipns}" "${filter}")
            rlast=${rnew}
            date
        fi
    done
}

function ipfs.pin.monitor () {
    local currenttime
    local rlast
    local ipns
    local rnew
    local pin_timeout
    local resolve_timeout
    local sleep_delay
    ipns=${1:-$IPFS_PIN_HASH}
    pin_timeout=${2:-$IPFS_PIN_TIMEOUT}
    resolve_timeout=${3:-$IPFS_RESOLVE_TIMEOUT}
    sleep_delay=${4:-$IPFS_PIN_SLEEP}

    if [[ -z "${ipns}" ]]
    then
        echo "ipns addr is required" >&2
        return 252
    fi
    while true
    do
        if rnew=$(ipfs resolve --timeout "${resolve_timeout}" "${ipns}")
        then
            if ! check_lockout_time || [[ "${rlast}" == "${rnew}" ]]
            then
                sleep "${sleep_delay}"
                continue
            fi
            echo "Pinning ${rnew}" >&2

            if ipfs pin add --progress --timeout "${pin_timeout}" "${rnew}"
            then
                if [[ -n "${rlast}" ]]
                then
                    echo "Removing pin for ${rlast}" >&2
                    ipfs pin rm "${rlast}"
                fi
                rlast=${rnew}
            fi
            date
        fi
    done
}

function getIPNSBase58BTC() {
    local cid
    local ipns
    ipns=${1=:$IPNS_RESOLVE_ADDR}

    if [[ -z "${ipns}" ]]
    then
	    echo "IPNS_RESOLVE_ADDR is required"
        return 252
    fi

    cid=$(ipfs resolve "${ipns}" --timeout "${IPFS_RESOLVE_TIMEOUT}" | sed 's/\/ipfs\///g' /dev/stdin)
    ipfs cid format -b base58btc "${cid}"
}

function ipfs.preload ()
{
    docker exec -i phill-dev_ipfs_1 ipfs dag export "${@}" | mbuffer -m 100m | ssh -p 35681 vps1.phillm.net docker exec -i phill-dev_ipfs_1 ipfs dag import --pin-roots=false
    docker exec -i phill-dev_ipfs_1 ipfs dag export "${@}" | mbuffer -m 100m | ssh -p 35681 vps2.phillm.net docker exec -i phill-dev_ipfs_1 ipfs dag import --pin-roots=false
    docker exec -i phill-dev_ipfs_1 ipfs dag export "${@}" | mbuffer -m 100m | ssh -p 35681 vps3.phillm.net docker exec -i phill-dev_ipfs_1 ipfs dag import --pin-roots=false
    docker exec -i phill-dev_ipfs_1 ipfs dag export "${@}" | mbuffer -m 100m | sshp io.phillm.net ./ipfs-s3 dag import --pin-roots=false
}


export -f ipfs.ls
export -f ipfs.pin.ls
export -f ipfs.ls.recursive
export -f ipfs.ls.recursive.dirs
export -f ipfs.ls.recursive.dirs.filtered
export -f ipfs.links.info
export -f ipfs.get.recursive
export -f ipfs.pins.prune
export -f ipfs.pin.dirs.filtered
export -f ipfs.pin.monitor
export -f getIPNSBase58BTC
export -f ipfs.preload

IPFS_API="api/v0"

export IPFS_API