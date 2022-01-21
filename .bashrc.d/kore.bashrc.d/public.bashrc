#! /bin/bash

function unstage_video_files ()
{
    python3 -c \
'
import re
from glob import iglob
from os import rename
from os.path import basename

mkvs = iglob("/callisto/Data/Staging/Webtorrent/*.mkv")
mp4s = iglob("/callisto/Data/Staging/Webtorrent/*.mp4")

pattern = re.compile(r"((\.\/)|(\[.*?\])|(-\s*[0-9]{2}(.[0-9])?\s*\[[0-9]{3,}p\])|(-\s*[0-9]{2}(.[0-9])?\s*\([0-9]{3,}p\))|\.mkv)")

for fitem in (*mkvs, *mp4s):
    fname = basename(fitem)
    dir_name = pattern.sub("", fname).strip()
    newpath = f"/callisto/Data/Upload/TV-Shows/Anime/{dirname}/{fname}"
    print(f"Moving '\''{fitem}'\'' to '\''{newpath}'\''")
    rename(fitem, newpath)
'
}

function public.anime.add ()
{
    local anime_has_dir
    local dir_name

    anime_has_dir='FALSE'

    while read -r dir_name
    do
        if [[ "${dir_name}" == "${1}" ]]
        then
            anime_has_dir='TRUE'
        fi
    done < <(ipfs files ls '/Public/Anime')

    if [[ "${anime_has_dir}" != 'TRUE' ]]
    then
        echo "Creating ipfs mfs dir /Public/Anime/${1}"
        ipfs files mkdir "/Public/Anime/${1}"
    fi

    if [[ ! -d "/callisto/Data/Upload/TV-Shows/Anime/${1}" ]]
    then
        mkdir -v "/callisto/Data/Upload/TV-Shows/Anime/${1}"
    fi

    (
        cd /callisto/Data/Staging/Webtorrent \
        && ipfs_find_add_folder "*${1}*" "/Public/Anime/${1}"
    )
    unstage_video_files
}


function public.root.hash () {
    curl -s --fail 'https://ipfs-admin.phillm.net/api/v0/files/stat?hash=true&arg=/Public' | jq -r .Hash
}

function public.list.preload ()
{
    local cid
    cid=$( public.root.hash )
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


function get_anime_names () {
    python3 -c \
'
import re
from glob import iglob

pattern = re.compile(r"((\.\/)|(\[.*?\])|(-\s*[0-9]{2}(.[0-9])?\s*\[[0-9]{3,}p\])|(-\s*[0-9]{2}(.[0-9])?\s*\([0-9]{3,}p\))|\.mkv)")
names = set()
for fname in iglob("./*.mkv"):
    names.add(pattern.sub("", fname).strip())
for n in names: print(n)
'
}


function fetch_queued_torrent () {
    python3 -c \
'
from glob import iglob
from os import rename
from os.path import basename

existing = next(iglob("./*.torrent"), None)
if existing is None:
    tpath = next(iglob("../Queue/*.torrent"), None)
    if not tpath is None:
        tname = basename(tpath)
        newpath = f"./{tname}"
        print(f"Moving '\''{tpath}'\'' to '\''{newpath}'\''")
        rename(tpath, newpath)
    else:
        print("Queue is empty")
        exit(1)
else:
    print(f"Found existing torrent '\''{existing}'\''")
'
}

function public.anime.detect.add ()
{
    while read -r anime_name
    do
        if [[ -n "${anime_name}" ]]
        then
            echo "Adding files to ${anime_name}" >&2
            if public.anime.add  "${anime_name}"
            then
                public.list.preload > "${HOME}/public.list.preload.log.txt" 2>&1 &
            fi
        else
            echo "Empty anime name" >&2
        fi
    done < <( get_anime_names )
}


function public.anime.torrents.monitor ()
{
    while :
    do
        sleep 5m &
        (
            cd /callisto/Data/Staging/Webtorrent && {
                if fetch_queued_torrent
                then
                    if io_wtdl_remote && compgen -G './*.mkv'
                    then
                        mv -vf ./*.torrent /callisto/Data/Phill/Downloads/Torrents
                        public.anime.detect.add
                    fi
                fi
            }
        )
        wait
    done
}

export -f unstage_video_files
export -f public.anime.add
export -f public.list.preload
export -f fetch_queued_torrent
export -f get_anime_names
export -f public.anime.torrents.monitor