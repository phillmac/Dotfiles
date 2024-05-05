#! /bin/bash

function ipfs.phone.add.staging ()
{
    /cygdrive/c/rclone/rclone copy \
        -v \
        --checksum \
        --backup-dir="H:/Staging/Phone/Downloads-Backup/$(date '+%Y%m%d%H%M')" \
        carpo:/fileservers/mimas/E/Staging/Phone/Downloads \
        "H:/Staging/Phone/Downloads"

    /cygdrive/c/rclone/rclone move \
        -v \
        --checksum \
        --delete-empty-src-dirs \
        carpo:/fileservers/mimas/E/Staging/Phone/Downloads-Backup \
        H:/Staging/Phone/Downloads-Backup

    echo "Adding files to ipfs" >&2

    cid=$(ipfs add -r -w -Q --pin=false 'H:\Staging\Phone')

    ipfs dag export --progress=false "${cid}" > /cygdrive/h/ipfs-export/"${cid}".car \
        && /cygdrive/c/rclone/rclone move -v --checksum --include "${cid}.car" "H:\ipfs-export" "carpo:/data/ipfs-staging/IPFS Export Phone" \
        && /cygdrive/c/rclone/rclone move -v --checksum --include "${cid}.car" "carpo:/data/ipfs-staging" "carpo:/data/ipfs-export/IPFS Export Phone"
}