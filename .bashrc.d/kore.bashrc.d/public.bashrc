#! /bin/bash

function unstage_video_files ()
{
    python3 -c \
'
from glob import iglob
from os import rename
from os.path import basename
from re import compile

mkvs = iglob("/callisto/Data/Staging/Webtorrent/*.mkv")
mp4s = iglob("/callisto/Data/Staging/Webtorrent/*.mp4")

pattern = compile(r"((\.\/)|(\[.*?\])|(-\s*[0-9]{2}(.[0-9])?\s*\[[0-9]{3,}p\])|(-\s*[0-9]{2}(.[0-9])?\s*\([0-9]{3,}p\))|\.mkv)")

for fitem in (*mkvs, *mp4s):
    fname = basename(fitem)
    dir_name = pattern.sub("", fname).strip()
    newpath = f"/callisto/Data/Upload/TV-Shows/Anime/{dir_name}/{fname}"
    print(f"Moving '\''{fitem}'\'' to '\''{newpath}'\''")
    rename(fitem, newpath)
'
}

function public.anime.add ()
{
    local dir_name
 

    if public.anime.hasdir "${1}"
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
}

function get_anime_names () {
    python3 -c \
'
from glob import iglob
from re import compile

pattern = compile(r"((\.\/)|(\[.*?\])|(-\s*[0-9]{2}(.[0-9])?\s*\[[0-9]{3,}p\])|(-\s*[0-9]{2}(.[0-9])?\s*\([0-9]{3,}p\))|\.mkv)")
names = set()
for fname in iglob("./*.mkv"):
    names.add(pattern.sub("", fname).strip())
for n in names: print(n)
'
}


function get_most_recent_torrent () {
    python3 -c \
'
from pathlib import Path
from re import compile

files = Path.cwd().glob("*720*.torrent")
newest = max(files, key=lambda x: x.stat().st_ctime)
pattern = compile(r"((\.\/)|(\[.*?\])|(-\s*[0-9]{2}(.[0-9])?\s*\[[0-9]{3,}p\])|(-\s*[0-9]{2}(.[0-9])?\s*\([0-9]{3,}p\))|\.mkv.torrent)")
print(pattern.sub("", newest.name).strip())
'
}

function monitor_anime_rss_alt () {
    
    while :
    do
        sleep 6h & 
        ( 
            cd /callisto/Data/Phill/Sync/Staging/Torrents/ && \
            for feedurl in 'https://subsplease.org/rss/?t&r=sd' 'https://subsplease.org/rss/?t&r=1080'
            do
                while read -r url
                do 
                    wget -nc --content-disposition "${url}";
                done < <(
                    grep -o 'https://nyaa.si/view/[0-9]*/torrent' < <(
                        curl -s --fail "${feedurl}"
                    )
                )
            done
        )
        date
        wait
    done
}

function monitor_anime_rss ()
{
    local anime_name
    local last_anime_name
    local fname

    while :
    do 
        sleep 15m & 
        ( 
            cd /callisto/Data/Phill/Sync/Staging/Torrents/ && {
                while read -r url
                do
                    echo "Fetching ${url}" >&2
                    wget -q -nc --content-disposition "${url}"
                    anime_name=$(get_most_recent_torrent)
                    echo "Anime name is ${anime_name}" >&2
                    if [[ "${last_anime_name}" != "${anime_name}" ]]
                    then
                        last_anime_name="${anime_name}"
                        if public.anime.hasdir "${anime_name}"
                        then
                            for fname in *"${anime_name}"*720p*
                            do
                                if ! public.anime.hasep "${anime_name}" "${fname}"
                                then
                                    if [[ ! -f "/callisto/Data/Staging/Webtorrent/${fname}" ]]
                                    then
                                        mv -v "${fname}" /ananke/D/Queue/Anime
                                    else
                                        echo "${fname} already being proccessed" >&2
                                    fi
                                else
                                    echo "${fname} already downloaded" >&2
                                fi
                            done
                        else
                            echo "${anime_name} not in public anime" >&2
                        fi
                    else
                        echo "Skipping ${anime_name}" >&2
                    fi
                done < <(
                    grep -o 'https://nyaa.si/view/[0-9]*/torrent' < <(
                            curl -s --fail 'https://subsplease.org/rss/?t&r=720'
                        )
                    )
            }
        )
        date
        wait
    done
}


function fetch_queued_torrent () {
    python3 -c \
'
from glob import iglob
from shutil import move
from os.path import basename

existing = next(iglob("./*.torrent"), None)
if existing is None:
    tpath = next(iglob("/ananke/D/Queue/Anime/*.torrent"), None)
    if not tpath is None:
        tname = basename(tpath)
        newpath = f"./{tname}"
        print(f"Moving '\''{tpath}'\'' to '\''{newpath}'\''")
        move(tpath, newpath)
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
    done < <( get_anime_names | sort )
    unstage_video_files
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
                    if io_wtdl_remote
                    then
                        if compgen -G './*.mkv'
                        then
                            mv -vf ./*.torrent /callisto/Data/Phill/Downloads/Torrents
                            public.anime.detect.add
                        else
                            echo "$(date) Unable to find video file" >&2
                        fi
                    else
                        echo "$(date) Caught remote download fail" >&2
                    fi                       
                fi
            }
        )
        echo "$(date) Waiting"
        wait
    done
}

export -f unstage_video_files
export -f public.anime.add
export -f public.list.preload
export -f fetch_queued_torrent
export -f get_anime_names
export -f public.anime.torrents.monitor