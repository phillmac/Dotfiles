#! /bin/bash

# function masonry.dev.combine ()
# {
#     local masonry_cid
#     local settings_cid
#     local empty_dir
#     local intermediate
#     local result

#     empty_dir=$(ipfs object new unixfs-dir)
#     echo 'Adding masonry'
#     masonry_cid=$(masonry.publish -Q)
#     echo 'Adding settings'
#     settings_cid=$(cd /fileservers/ananke/D/Source/Phill/Repos/Phill/masonry-settings && ipfs add -r -Q --pin=false .)

#     intermediate=$(ipfs object patch "${empty_dir}" add-link galleries "${masonry_cid}")
#     echo "Intermediate dir ${intermediate}"
#     result=$(ipfs object patch "${intermediate}" add-link settings "${settings_cid}")

#     echo "https://ipfs.io/ipfs/${result}"
#     echo "https://cf-ipfs.com/ipfs/${result}"

#     curl "http://external1.ddns.peelvalley.com.au:8081/api/v0/get?arg=${result}" > /dev/null
#     curl "http://192.168.30.57:8080/api/v0/get?arg=${result}" > /dev/null
#     curl "http://external7.ddns.peelvalley.com.au:8080/api/v0/get?arg=${result}" > /dev/null
#     curl "http://io2.phillm.net:8080/api/v0/get?arg=${result}" > /dev/null
#     curl "http://external5.ddns.peelvalley.com.au:8080/api/v0/get?arg=${result}" > /dev/null
#     curl "http://api.vps1.ipfs-archive.online:8080/api/v0/get?arg=${result}" > /dev/null
#     curl "http://api.vps2.ipfs-archive.online:8080/api/v0/get?arg=${result}" > /dev/null
#     curl "http://api.vps3.ipfs-archive.online:8080/api/v0/get?arg=${result}" > /dev/null
#     curl "http://external1.ddns.peelvalley.com.au:8080/api/v0/get?arg=${result}" > /dev/null

# }