#! /bin/bash

function vps4.staging.import () {

docker run --rm peelvalley/rclone-b2 'rclone cat phill-gdrive:ipfs-export/${dcid}.car' | mbuffer | docker exec -i phill-dev_ipfs_1 ipfs dag import --pin-roots=false

ipfs.files.cp.deep "/ipfs/${dcid}" "'/${mfspath}'"
}