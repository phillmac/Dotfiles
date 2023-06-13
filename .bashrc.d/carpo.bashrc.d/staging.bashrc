#! /bin/bash
function staging.upload () {
    docker run --rm -v /data/ipfs-export:/ipfs-export peelvalley/rclone-b2 rclone move -v '/ipfs-export/${dcid}.car' phill-gdrive:ipfs-export
}