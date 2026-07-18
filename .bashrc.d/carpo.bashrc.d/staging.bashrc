#! /bin/bash
function staging.upload () {

    docker run --rm -v /data/ipfs-export:/ipfs-export peelvalley/rclone-b2 rclone move -v '/ipfs-export/${dcid}.car' "phill-gdrive:ipfs-export"
}

function staging.upload.gdrive.all () {

    (
        cd /data/ipfs-export && while :; do
            timest=$(date '+%Y%m%d%H%M')
            rclone move -vvv --fast-list --drive-chunk-size 256M  --include '*.car' --delete-empty-src-dirs /data/ipfs-export "phill-gdrive:ipfs-export3/${timest}"
            sleep 300
        done
     )
}

function staging.upload.mega.all () {

    (
        cd /data/ipfs-export && while :; do
            timest=$(date '+%Y%m%d%H%M')
            rclone move -vvv --fast-list --drive-chunk-size 256M  --include '*.car' --delete-empty-src-dirs /data/ipfs-export "mega:ipfs-export/${timest}"
            sleep 300
        done
     )
}