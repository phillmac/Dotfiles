#! /bin/bash

function public.anime.add ()
{
    local anime_has_dir
    anime_has_dir=$(ipfs files ls "/Public/Anime" | grep "${1}")

    if [[ -z "${anime_has_dir}" ]]
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
    ) \
    && mv -v  /callisto/Data/Staging/Webtorrent/*"${1}"* "/callisto/Data/Upload/TV-Shows/Anime/${1}"
}

public.list.preload ()
{
    local cid
    cid=$(curl -s --fail 'https://ipfs-admin.phillm.net/api/v0/files/stat?hash=true&arg=/Public' | jq -r .Hash)
    IPFS_HTTP_GATEWAY=192.168.42.208:8080 ipfs.ls.recursive "${cid}"
    IPFS_HTTP_GATEWAY=192.168.30.57:8080 ipfs.ls.recursive "${cid}"
    IPFS_HTTP_GATEWAY=192.168.20.51:8080 ipfs.ls.recursive "${cid}"
    IPFS_HTTP_GATEWAY=192.168.35.51:8080 ipfs.ls.recursive "${cid}"
}