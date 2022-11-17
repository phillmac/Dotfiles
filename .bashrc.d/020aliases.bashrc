#!/bin/bash

function source_dir_files ()
{
    for file in "${1}"/*.bashrc
    do
        [[ "${SOURCE_DEBUG}" ]] || [[ "${BASH_RC_D_DEBUG}" ]] && {
            echo "Sourcing ${file}" >&2
        }
        source "${file}"
    done
}

function _curl () {

    local retries
    local maxtime
    local result
    local curl_usr_pass
    curl_usr_pass="${CURL_USR}:${CURL_PASS}"

    retries=${CURL_RETRIES:-0}
    maxtime=${CURL_MAXTIME:-300}

    if [[ -n "${ENABLE_DEBUG}" ]] || [[ -n "${DEBUG_CURL}" ]]
    then
        
        if [[ "${curl_usr_pass}" = ':' ]]
        then
            curl -n --verbose --fail --retry "${retries}" --max-time "${maxtime}" "${@}"
            result=$?
        else
            curl -n --verbose --fail --retry "${retries}" -u "${curl_usr_pass}" --max-time "${maxtime}" "${@}"
            result=$?
        fi
    else
        if [[ "${curl_usr_pass}" = ':' ]]
        then
            curl -n --silent --fail "${@}"
            result=$?
        else
            curl -n --silent --fail -u "${curl_usr_pass}" "${@}"
            result=$?
        fi
    fi
    echo
    return ${result}
}

function curljson () {
    _curl  -H "Content-Type: application/json" "${@}"
}

function curljsonp () {
    _curl  -X POST -H "Content-Type: application/json" "${@}"
}

function rawurlencode () {
  local string="${1}"
  local strlen=${#string}
  local encoded=""
  local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * )               printf -v o '%%%02x' "'$c"
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

function jsawk () {
    docker run --rm -i peelvalley/jsawk bash -c "jsawk ${*}"
}

function ipfs () {
    if which ipfs > /dev/null; then
        $(which ipfs) "${@}"
    else
        if [[ "$(docker network ls --format '{{.Name}}')" = *"phill-dev_ipfs"* ]]
        then
            if [[ -t 1 ]] &&  [[ -t 2 ]] && [[ ! -p /dev/stdout ]] && [[ ! -p /dev/stdin ]]
            then
                echo 'Detected TTY' >&2
                docker run --rm -it -v "$(pwd)":/tmp -w /tmp --net phill-dev_ipfs --log-driver none peelvalley/ipfs-cli "${@}"
            else
                docker run --rm -v "$(pwd)":/tmp -w /tmp --net phill-dev_ipfs --log-driver none peelvalley/ipfs-cli "${@}"
            fi
        else
            if [[ -t 1 ]] &&  [[ -t 2 ]] && [[ ! -p /dev/stdout ]] && [[ ! -p /dev/stdin ]]
            then
                echo 'Detected TTY' >&2
                docker run --rm -it -v "$(pwd)":/tmp -w /tmp --net pvs-dev_ipfs --log-driver none peelvalley/ipfs-cli "${@}"
            else
                docker run --rm -v "$(pwd)":/tmp -w /tmp --net pvs-dev_ipfs --log-driver none peelvalley/ipfs-cli "${@}"

            fi
        fi
    fi
}

function ipfs.dag.import()
{
    if [[ "$(docker network ls --format '{{.Name}}')" = *"phill-dev_ipfs"* ]]
    then
        docker run --rm -i -v "$(pwd)":/tmp -w /tmp --net phill-dev_ipfs --log-driver none peelvalley/ipfs-cli dag import --pin-roots=false
    else
        docker run --rm -i -v "$(pwd)":/tmp -w /tmp --net pvs-dev_ipfs --log-driver none peelvalley/ipfs-cli dag import --pin-roots=false
    fi
}

function _ipfs() {
    if [[ "$(docker network ls --format '{{.Name}}')" = *"phill-dev_ipfs"* ]]
    then
        
        docker run --rm -v "$(pwd)":/tmp -w /tmp --net phill-dev_ipfs --log-driver none peelvalley/ipfs-cli "${@}"
    else
        
        docker run --rm -v "$(pwd)":/tmp -w /tmp --net pvs-dev_ipfs --log-driver none peelvalley/ipfs-cli "${@}"
    fi

}

function ipfs-exec () {
    if [[ "$(docker network ls --format '{{.Name}}')" = *"phill-dev_ipfs"* ]]; then
        docker run --rm -v "$(pwd)":/tmp -w /tmp --net phill-dev_ipfs --log-driver none --entrypoint bash peelvalley/ipfs-cli "${@}"
    else
        docker run --rm -v "$(pwd)":/tmp -w /tmp --net pvs-dev_ipfs --log-driver none --entrypoint bash peelvalley/ipfs-cli "${@}"
    fi

}

function ipfs_find_add_folder() {
    local patern
    local folder
    local files_count

    files_count=0

    patern="${1}"
    folder="${2}"

    while read -r fname
    do
        ((files_count++))
        ipfs_add_folder "${fname}" "${folder}"
    done < <(find . -type f '(' -iname "${patern}*.mkv" -o -iname "${patern}*.mp4" ')')
    echo "Found ${files_count} files" >&2
}

function ipfs_add_folder() {
    local file
    local fname
    local folder
    local file_hash
    local existing
    local isExisting=false

    file="${1#'./'}"
    folder="${2}"
    fname=$(basename "${file}")

    while read -r existing
    do
        if [[ "${fname}" = "${existing}" ]]; then
            isExisting=true
        fi
    done < <(ipfs files ls "${folder}")

    if [[ ${isExisting} = true ]]; then
        echo "Skiping existing file ${fname} in folder ${folder}" >&2
        return
    fi

    echo "$(date) Adding ${fname}" >&2

    file_hash=$(ipfs add --pin=false -Q "${file}")

    echo "$(date) Copying  ${file_hash} for ${fname} to ${folder}" >&2

    ipfs files cp "/ipfs/${file_hash}" "${folder}/${fname}"

    echo "$(date) Done" >&2
}

function ipfs_provide_folder() {
    local folder
    local fname
    local listing
    local file_hash
    local size
    local len

    folder="${1}"
    echo "Recursing into ${folder}"

    while read -r -a listing
    do
        size=${listing[-1]}
        len=$((${#listing[@]} -2 ))
        fname=$(basename "${listing[*]:0:$len}")
        if [[ "${size}" -eq 0 ]]; then
           ipfs_provide_folder "${folder}/${fname}"
        else
            file_hash=${listing[-2]}
            echo "$(date '+%Y/%M/%d %H:%M') Providing ${fname} - ${file_hash}"
            ipfs dht provide --timeout 900s "${file_hash}"
        fi
    done < <(ipfs files ls -l "/${folder}")
}

function clone_repo () {
    local kalyke_ssh_port

    kalyke_ssh_port=${2:-${KALYKE_SSH_PORT}}
    kalyke_ssh_port=${kalyke_ssh_port:-22}

    if [[ ! -d  "${HOME}/source/repos" ]]
    then
        mkdir -p "${HOME}/source/repos"
    fi


    case "${1}" in
        "phill-dev" )
            if [[ ! -d  "${HOME}/source/repos/phill" ]]
            then
                mkdir -p "${HOME}/source/repos/phill"
            fi
            (cd "${HOME}/source/repos/phill" && git clone "ssh://kalyke.peelvalley.com.au:${kalyke_ssh_port}/Phill/_git/Dev-Env")
            ;;
        "pvs-dev" )
            if [[ ! -d  "${HOME}/source/repos/pvs" ]]
            then
                mkdir -p "${HOME}/source/repos/pvs"
            fi
            (cd "${HOME}/source/repos/pvs" && git clone "ssh://kalyke.peelvalley.com.au:${kalyke_ssh_port}/PVS/_git/Dev-Env")
            ;;
        "pvte-dev" )
            if [[ ! -d  "${HOME}/source/repos/pvte" ]]
            then
                mkdir -p "${HOME}/source/repos/pvte"
            fi
            (cd "${HOME}/source/repos/pvte" && git clone "ssh://kalyke.peelvalley.com.au:${kalyke_ssh_port}/PVTE/_git/Dev-Env")
            ;;
        * )
            echo "Unkown repo ${1}" ;;

    esac
}

function youtube_dl () {
    docker run --rm -v "/callisto/Data/ytdl/${SHORT_HOST}":/workdir -w/workdir --entrypoint yt-dlp phillmac/youtubedl "${@}"
}

function nodejs_dev () {
    docker run --rm -it -w /wd   -v "$(pwd)":/wd node:latest bash -c "${*}"
}

function video_archive () {
    docker run --rm --net host -v /root:/root -v /callisto/Data/Upload/TV-Shows:/TV-Shows peelvalley/rclone-b2 "rclone move --verbose --bwlimit 0.3125M --transfers 1 /TV-Shows  b2-phill:Video-Archive2/TV-Shows"
    docker run --rm --net host -v /root:/root -v /callisto/Data/Upload/Movies:/Movies peelvalley/rclone-b2 "rclone move --verbose --transfers 1 --bwlimit 0.3125M --delete-empty-src-dirs /Movies  b2-phill:Video-Archive2/Movies"
}

function rclone_staging () {
    docker run -it --rm --net host -v /root:/root -v /callisto/Data/Staging:/Staging -w /Staging --entrypoint bash -it peelvalley/rclone-b2
}

function rclone_move_callisto () {
    docker run --rm --net host -v /root:/root -v /callisto:/callisto peelvalley/rclone-b2 "rclone move --verbose --transfers 1 --delete-empty-src-dirs --ignore-existing ${*}"
}

function rclone () {
    if [[ -t 1 ]] &&  [[ -t 2 ]] && [[ ! -p /dev/stdout ]] && [[ ! -p /dev/stdin ]]
    then
        echo 'Detected TTY' >&2
        docker run -it --rm --net host -v /root:/root -v "$(pwd):$(pwd)" -w "$(pwd)" --entrypoint rclone peelvalley/rclone-b2 "${@}"
    else
        docker run --rm --net host -v /root:/root -v "$(pwd):$(pwd)" -w "$(pwd)" --entrypoint rclone peelvalley/rclone-b2 "${@}"
    fi

}

function load_bashrc.d () {
    for file in "${HOME}"/.bashrc.d/*.bashrc
    do
        if [[ -f "${file}" && -r "${file}" ]]; then
            source "${file}"
        fi
    done
}

function ipfs_cache_hash () {
    local hash

    hash=${1}

    if [[ -z "${hash}" ]]
    then
        read -r -p 'Enter hash: ' hash
    fi

    parallel --ungroup --env load_bashrc.d -S titan "load_bashrc.d && ipfs.get.recursive" ::: "${hash}"
    parallel --ungroup --env load_bashrc.d -S charon "load_bashrc.d && ipfs.get.recursive" ::: "${hash}"
    parallel --ungroup --env load_bashrc.d -S io "load_bashrc.d && ipfs.get.recursive" ::: "${hash}"
    parallel --ungroup --env load_bashrc.d -S vps3.phillm.net "load_bashrc.d && ipfs.get.recursive" ::: "${hash}"
    parallel --ungroup --env load_bashrc.d -S vps1.phillm.net "load_bashrc.d && ipfs.get.recursive" ::: "${hash}"
}

export -f _curl
export -f ipfs
export -f _ipfs
export -f rawurlencode
export -f ipfs_add_folder
export -f ipfs_find_add_folder
export -f ipfs_provide_folder
export -f video_archive
export -f load_bashrc.d
export -f ipfs_cache_hash


alias sshp="ssh -p 35681 -o ServerAliveInterval=10 -o ServerAliveCountMax=3"
alias dagr="docker run --rm  -v/callisto/Data/Phill/_/DA\\ Artists:/DA -w /DA phillmac/dagr_revamped:latest dagr.py"
alias dagr-bulk="docker run --rm  -v/callisto/Data/Phill/_/DA\\ Artists:/DA -w /DA  phillmac/dagr_revamped:latest  dagr-bulk.py"
alias dagr-utils="docker run --rm -it -v/callisto/Data/Phill/_/DA\\ Artists:/DA -w /DA  -v/ananke/D/Source/Phill/Repos/Phill:/Repos phillmac/dagr_revamped:latest dagr-utils.py"
alias dagr-dev="docker run --rm -it -v/callisto/Data/Phill/_/DA\\ Artists:/DA -w /DA  -v/ananke/D/Source/Phill/Repos/Phill:/Repos python bash"
alias dagr-dev-debug="docker run --rm -it -v/callisto/Data/Phill/_/DA\\ Artists:/DA -w /DA  -v/ananke/D/Source/Phill/Repos/Phill:/Repos -e 'Dagr.Logging.Level=4' python bash"

alias dagr-selenium="docker run --rm -it --net phill-dev_chrome -v/callisto/Data/Phill/_/DA\ Artists:/DA -w /DA --env-file ./dagr-selenium.env phillmac/dagr_selenium:latest -u -m"
alias dagr-selenium-debug="docker run --rm -it --net phill-dev_chrome -v/callisto/Data/Phill/_/DA\ Artists:/DA -w /DA  -e 'dagr.logging.level=4' --env-file ./dagr-selenium-debug.env  phillmac/dagr_selenium:latest -u -m"
alias rip-gallery-debug="docker run --rm -it --net phill-dev_chrome -v/callisto/Data/Phill/_/DA\ Artists:/DA -w /DA  -e 'dagr.rip_gallery.logging.level=4' phillmac/dagr_selenium:latest -u -m dagr_selenium.rip_gallery"
alias orbitdbapi="docker run --rm -it -w /Repos/orbit-db-http-api  -v pvs-dev_cert-data:/certs -v/ananke/D/Source/Phill/Repos/Phill:/Repos --net pvs-dev_ipfs node:11.13 bash"
alias orbitdbsprinkle="docker run --rm -d -w /var/www  -v/ananke/D/Source/Phill/Repos:/Repos --net pvs-dev_ipfs --name orbitdb_dash peelvalley/userfrosting"
alias youtube-dl=youtube_dl
alias nodejs-dev=nodejs_dev

alias clone-repo=clone_repo