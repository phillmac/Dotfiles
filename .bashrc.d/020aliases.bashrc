#!/bin/bash

function source_dir_files ()
{
    for fname in "${1}"/*.bashrc
    do
        [[ "${SOURCE_DEBUG}" ]] || [[ "${BASH_RC_D_DEBUG}" ]] && {
            echo "Sourcing ${fname}" >&2
        }
        source "${fname}"
    done
}

function _curl () {

    local retries
    local maxtime
    local result
    local debug
    local options
    local unix_sock_addr
    local curl_usr_pass
    local curl_method

    unix_sock_addr=${CURL_SOCK_ADDR}
    retries=${CURL_RETRIES:-0}
    maxtime=${CURL_MAXTIME:-300}
    curl_usr_pass="${CURL_USR}:${CURL_PASS}"
    curl_method="${CURL_METHOD}"

    options=(-n --fail)

    if [[ -n "${unix_sock_addr}" ]]
    then
        options=("${options[@]}" --unix-socket "${unix_sock_addr}")
    fi

    if [[ -n "${ENABLE_DEBUG}" ]] || [[ -n "${DEBUG_CURL}" ]]
    then
        options=("${options[@]}" --verbose --retry "${retries}" --max-time "${maxtime}")
        debug=1
    else
        options=("${options[@]}" --silent)
        debug=0
    fi

    if [[ "${curl_usr_pass}" != ':' ]]
    then
        options=("${options[@]}" -u "${curl_usr_pass}")
    fi

    if [[ -n "${curl_method}" ]]
    then
        options=("${options[@]}" -X "${curl_method}")
    fi

    options=("${options[@]}" "${@}")

    if ((debug))
    then
        echo "CURL options: ${options[*]}" >&2
    fi

    curl "${options[@]}"
    result=$?

    echo

    if ((debug))
    then
        echo "CURL result code: ${result}" >&2
    fi

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
        "$(which ipfs)" "${@}"
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

function ipfs.dag.import.bigblock()
{
    if [[ "$(docker network ls --format '{{.Name}}')" = *"phill-dev_ipfs"* ]]
    then
        docker run --rm -i -v "$(pwd)":/tmp -w /tmp --net phill-dev_ipfs --log-driver none peelvalley/ipfs-cli dag import --pin-roots=false --allow-big-block
    else
        docker run --rm -i -v "$(pwd)":/tmp -w /tmp --net pvs-dev_ipfs --log-driver none peelvalley/ipfs-cli dag import --pin-roots=false --allow-big-block
    fi
}

function _ipfs() {
    if which ipfs > /dev/null; then
        "$(which ipfs)" "${@}"
    else
        if [[ "$(docker network ls --format '{{.Name}}')" = *"phill-dev_ipfs"* ]]
        then

            docker run --rm -v "$(pwd)":/tmp -w /tmp --net phill-dev_ipfs --log-driver none peelvalley/ipfs-cli "${@}"
        else

            docker run --rm -v "$(pwd)":/tmp -w /tmp --net pvs-dev_ipfs --log-driver none peelvalley/ipfs-cli "${@}"
        fi
    fi

}

function ipfs-exec () {
    if [[ "$(docker network ls --format '{{.Name}}')" = *"phill-dev_ipfs"* ]]; then
        docker run --rm -v "$(pwd)":/tmp -w /tmp --net phill-dev_ipfs --log-driver none --entrypoint bash peelvalley/ipfs-cli "${@}"
    else
        docker run --rm -v "$(pwd)":/tmp -w /tmp --net pvs-dev_ipfs --log-driver none --entrypoint bash peelvalley/ipfs-cli "${@}"
    fi

}

function ipfs-car () {
    docker run --rm -v "$(pwd)":/tmp -w /tmp --net none --log-driver none phillmac/ipfs-car "${@}"
}

function ipfs.mfs.exists ()
{
    local fname
    local folder
    local existing
    local isExisting=false
    local ipfs_cmd=${IPFS_CMD:-_ipfs}

    iname="${1}"
    mfspath="${2}"

    while read -r existing
    do
        if [[ "${iname}" = "${existing}" ]]; then
            isExisting=true
        fi
    done < <("${ipfs_cmd}" files ls "${mfspath}")

    if [[ ${isExisting} = true ]]; then
        echo "${iname} exists in mfs at ${mfspath}" >&2
        return 0
    fi

    return 1
}

function ipfs.mfs.create.dir ()
{
    local create_path=${1}
    local mfs_basedir=${2}
    local current_part=""
    local ipfs_cmd=${IPFS_CMD:-_ipfs}

    local IFS='/'

    read -ra path_parts <<< "$create_path"

    for part in "${path_parts[@]}"
    do
        current_part="$current_part/$part"
        echo "Current part: $current_part"

        if ! ipfs.mfs.exists "${part}" "${mfs_basedir}/${last_path}"
        then
            echo "Creating missing mfs dir ${mfs_basedir}/${current_part}" >&2
            "${ipfs_cmd}" files mkdir "${mfs_basedir}/${current_part}"
        fi

        last_path="$current_part"
    done
}

function ipfs_add_folder() {
    local fpath
    local fname
    local folder
    local file_hash
    local existing
    local isExisting=false

    fpath="${1#'./'}"
    folder="${2}"
    fname=$(basename "${fpath}")


    if _ipfs files ls "${folder}/${fname}"
    then
        echo "Skiping existing file ${fname} in folder ${folder}" >&2
        return
    fi

    echo "$(date) Adding ${fname}" >&2

    file_hash=$(ipfs add --pin=false -Q "${fname}")

    if [[ -z "${file_hash}" ]]
    then
        echo "Empty file hash for ${fname}" >&2
        return 255
    fi

    echo "$(date) Copying ${file_hash} for ${fname} to ${folder}" >&2

    ipfs files cp "/ipfs/${file_hash}" "${folder}/${fname}"

    echo "$(date) Done" >&2
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
    docker run --rm --net host -v /root:/root -v /callisto/Data/Upload/TV-Shows:/TV-Shows peelvalley/rclone-b2  "rclone move -vvv  --checksum --transfers 1 --bwlimit 0.3125M                           /TV-Shows   b2-phill:Video-Archive2/TV-Shows"
    docker run --rm --net host -v /root:/root -v /callisto/Data/Upload/Movies:/Movies peelvalley/rclone-b2      "rclone move -vvv --checksum --transfers 1 --bwlimit 0.3125M --delete-empty-src-dirs   /Movies     b2-phill:Video-Archive2/Movies"
}

function rclone_staging () {
    docker run -it --rm --net host -v /root:/root --log-driver none -v /callisto/Data/Staging:/Staging -w /Staging --entrypoint bash -it peelvalley/rclone-b2
}

function rclone_move_callisto () {
    docker run --rm --net host -v /root:/root -v /callisto:/callisto peelvalley/rclone-b2 "rclone move --verbose --transfers 1 --delete-empty-src-dirs --ignore-existing ${*}"
}

function rclone () {
    if [[ -t 1 ]] &&  [[ -t 2 ]] && [[ ! -p /dev/stdout ]] && [[ ! -p /dev/stdin ]]
    then
        echo 'Detected TTY' >&2
        docker run -it --rm --net host --log-driver none -v /root:/root -v "$(pwd):$(pwd)" -w "$(pwd)" --entrypoint rclone peelvalley/rclone-b2 "${@}"
    else
        docker run --rm --net host --log-driver none -v /root:/root -v "$(pwd):$(pwd)" -w "$(pwd)" --entrypoint rclone peelvalley/rclone-b2 "${@}"
    fi

}

function rclone_data () {
    if [[ -t 1 ]] &&  [[ -t 2 ]] && [[ ! -p /dev/stdout ]] && [[ ! -p /dev/stdin ]]
    then
        echo 'Detected TTY' >&2
        docker run -it --rm --net host --log-driver none -v /root:/root -v /data:/data -v "$(pwd):$(pwd)" -w "$(pwd)" --entrypoint rclone peelvalley/rclone-b2 "${@}"
    else
        docker run --rm --net host --log-driver none -v /root:/root -v /data:/data -v "$(pwd):$(pwd)" -w "$(pwd)" --entrypoint rclone peelvalley/rclone-b2 "${@}"
    fi

}

function rclone_fuse () {
    if [[ -t 1 ]] &&  [[ -t 2 ]] && [[ ! -p /dev/stdout ]] && [[ ! -p /dev/stdin ]]
    then
        echo 'Detected TTY' >&2
        docker run \
            -it \
            --rm \
            --net host \
            --log-driver none \
            --device /dev/fuse \
            --cap-add SYS_ADMIN \
            --security-opt apparmor:unconfined \
            --label "rclone-fuse:${RCLONE_FUSE_LABEL}" \
            -v /root:/root \
            -v "$(pwd):$(pwd):shared" \
            -w "$(pwd)" \
            --entrypoint rclone \
            peelvalley/rclone-b2 \
                "${@}"
    else
        docker run \
            --rm \
            --net host \
            --log-driver none \
            --device /dev/fuse \
            --cap-add SYS_ADMIN \
            --security-opt apparmor:unconfined \
            --label "rclone-fuse:${RCLONE_FUSE_LABEL}" \
            -v /root:/root \
            -v "$(pwd):$(pwd):shared" \
            -w "$(pwd)" \
            --entrypoint rclone \
            peelvalley/rclone-b2 \
                "${@}"
    fi

}

function rclone_fuse_data () {
    if [[ -t 1 ]] &&  [[ -t 2 ]] && [[ ! -p /dev/stdout ]] && [[ ! -p /dev/stdin ]]
    then
        echo 'Detected TTY' >&2
        docker run \
            -it \
            --rm \
            --net host \
            --log-driver none \
            --device /dev/fuse \
            --cap-add SYS_ADMIN \
            --security-opt apparmor:unconfined \
            --label "rclone-fuse:${RCLONE_FUSE_LABEL}" \
            -v /root:/root \
            -v /data:/data \
            -v "$(pwd):$(pwd):shared" \
            -w "$(pwd)" \
            --entrypoint rclone \
            peelvalley/rclone-b2 \
                "${@}"
    else
        docker run \
            --rm \
            --net host \
            --log-driver none \
            --device /dev/fuse \
            --cap-add SYS_ADMIN \
            --security-opt apparmor:unconfined \
            --label "rclone-fuse:${RCLONE_FUSE_LABEL}" \
            -v /root:/root \
            -v /data:/data \
            -v "$(pwd):$(pwd):shared" \
            -w "$(pwd)" \
            --entrypoint rclone \
            peelvalley/rclone-b2 \
                "${@}"
    fi

}

function rclone_mount () {
    if [[ -d /data ]]
    then
        rclone_fuse_data --dir-cache-time 1d --vfs-refresh "${@}"
    else
        rclone_fuse --dir-cache-time 1d --vfs-refresh "${@}"
    fi
}


function rclonei () {
    docker run -i --rm --net host --log-driver none -v /root:/root -v "$(pwd):$(pwd)" -w "$(pwd)" --entrypoint rclone peelvalley/rclone-b2 "${@}"
}

function load_bashrc.d () {
    for fname in "${HOME}"/.bashrc.d/*.bashrc
    do
        if [[ -f "${fname}" && -r "${fname}" ]]; then
            source "${fname}"
        fi
    done
}

function sync-develop ()
{
    git pull origin master --ff && git push origin master && git checkout develop && git pull origin develop --ff && git merge master && git push origin develop && git checkout master
}

function sync-develop-github ()
{
    git pull github master --ff && git push github master && git checkout develop && git pull github develop --ff && git merge master && git push github develop && git checkout master
}

function sync-develop-phill-github ()
{
    git pull phill-github master --ff && git push phill-github master && git checkout develop && git pull phill-github develop --ff && git merge master && git push phill-github develop && git checkout master
}

function sync-develop-all ()
{
    sync-develop && sync-develop-github && sync-develop-phill-github
}

function monitor_output () {
    # Check if a command is provided as an argument
    if [ -z "$1" ]; then
        echo "Usage: $0 <command_to_monitor>"
        exit 1
    fi

    # The command to monitor is provided as an argument
    command_to_monitor="$1"

    # Run the specified command and capture the output
    current_output=$($command_to_monitor)

    # Specify a file to store the previous output
    previous_output_file="/tmp/previous_output_$$.txt"

    # Check if the file exists and read the previous output
    if [ -e "$previous_output_file" ]; then
        previous_output=$(<"$previous_output_file")

        # Compare the current and previous output
        if [ "$current_output" != "$previous_output" ]; then
            echo "Output has changed."
            # Do something when the output has changed
            echo "$current_output" > "$previous_output_file"
            exit 0  # Success exit code
        else
            echo "Output is the same."
            # Do something when the output is the same
            exit 1  # Failure exit code
        fi
    else
        echo "Previous output file not found. Creating it."
        echo "$current_output" > "$previous_output_file"
        exit 0  # Success exit code since it's the first run
    fi

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