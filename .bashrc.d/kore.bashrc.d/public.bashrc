#! /bin/bash

function public.anime.add ()
{
    (
        cd /callisto/Data/Staging/Webtorrent \
        && ipfs_find_add_folder "*${1}*" "/Public/Anime/${1}"
    ) \
    && mv -v  /callisto/Data/Staging/Webtorrent/*"${1}"* "/callisto/Data/Upload/TV-Shows/Anime/${1}"
}