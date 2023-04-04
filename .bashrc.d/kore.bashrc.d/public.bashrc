#! /bin/bash

function unstage_video_files ()
{

    batchdircount=$(find /callisto/Data/Staging/Webtorrent -maxdepth 1 -mindepth 1 -type d -iname '*batch*' | wc -l)
    if (( 0$batchdircount > 0 )) 
    then
        echo "Unstaging in batch mode"
        python3 -c \
'
from glob import iglob
from os import rename, makedirs, listdir, rmdir
from os.path import basename, dirname, exists
from re import compile

mkvs = iglob("/callisto/Data/Staging/Webtorrent/*Batch*/*.mkv")
mp4s = iglob("/callisto/Data/Staging/Webtorrent/*Batch*/*.mp4")

pattern = compile(r"((\.\/)|(\[.*?\])|(-\s*[0-9]{2}(.[0-9])?\s*\[[0-9]{3,}p\])|(-\s*[0-9]{2}(.[0-9])?\s*\([0-9]{3,}p\))|\.mkv)")

for fitem in (*mkvs, *mp4s):
    oldbatchpath = dirname(fitem)
    batchname = basename(oldbatchpath)
    fname = basename(fitem)
    dir_name = pattern.sub("", fname).strip()
 
    newbatchpath = f"/callisto/Data/Upload/TV-Shows/Anime/{dir_name}/{batchname}"
    if not exists(newbatchpath):
        print(f"Creating {newbatchpath}")
        mkdirs(newbatchpath)

    newpath = f"{newbatchpath}/{fname}"

    print(f"Moving '\''{fitem}'\'' to '\''{newpath}'\''")
    # rename(fitem, newpath)
    
    if listdir(oldbatchpath).len == 0:
        print(f"Removing empty batch dir '\''{newbatchpath}'\''")
        rmdir(oldbatchpath)
    else:
        print(f"Batch dir '\''{newbatchpath}'\'' not empty. Leaving in place.")
'

    else


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
    # rename(fitem, newpath)
'
    fi
}

function public.anime.add ()
{
    if ! public.anime.hasdir "${1}"
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
import os

pattern = compile(r"((\.\/)|(\[.*?\])|(-\s*[0-9]{2}(.[0-9])?\s*\[[0-9]{3,}p\])|(-\s*[0-9]{2}(.[0-9])?\s*\([0-9]{3,}p\))|\.mkv)")
names = set()
for fname in iglob("./*.mkv"):
    names.add(pattern.sub("", fname).strip())
for n in names: print(n)


pattern = compile(r"((\.\/)|(\[.*?\])|(\(\s*[0-9]{2}-\s*[0-9]{2}\))|(\s*\[[0-9]{3,}p\])|(\s*\([0-9]{3,}p\)))")
for fname in [ f.path for f in os.scandir(".") if f.is_dir() ]:
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
    local downloaded
    local found

    while :
    do
        sleep 15m &
        (
            downloaded=()
            cd /callisto/Data/Phill/Sync/Staging/Torrents/ && {
                while read -r url
                do
                    mapfile -t downloaded < public.anime.torrents.downloaded
                    echo "Downloaded count ${#downloaded[@]}" >&2
                    found="no"
                    for i in "${downloaded[@]}"
                    do
                        if [[ "${i}" == "${url}" ]];
                        then
                            found='yes'
                            break
                        fi
                    done

                    if [[ "${found}" == 'yes' ]]
                    then
                        echo "Skipping already downloaded ${url}" >&2
                        continue
                    else
                        echo "Found: ${found}" >&2
                    fi

                    echo "Fetching ${url}" >&2
                    wget -q -nc --content-disposition "${url}"
                    echo "${url}" >> public.anime.torrents.downloaded
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
    local anime_name

    while read -r anime_name
    do
        if [[ -n "${anime_name}" ]]
        then
            echo "Adding files to ${anime_name}" >&2
            if public.anime.add  "${anime_name}"
            then
                public.name.publish
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
                        batchdircount=$(find /callisto/Data/Staging/Webtorrent -maxdepth 1 -mindepth 1 -type d -iname '*batch*' | wc -l)
                        if (( 0$batchdircount > 0 )) || compgen -G './*.mkv'
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

function public.name.publish ()
{
    docker run --rm \
        --net pvs-dev_ipfs  \
        --entrypoint sh  \
        peelvalley/ipfs-cli \
            -c \
                'sh /scripts/ipfs-cli.sh name publish --timeout 10m --key Public $(sh /scripts/ipfs-cli.sh files stat --hash /Public)'
}

export -f unstage_video_files
export -f public.anime.add
export -f public.name.publish
export -f public.anime.detect.add
export -f fetch_queued_torrent
export -f get_anime_names
export -f public.anime.torrents.monitor