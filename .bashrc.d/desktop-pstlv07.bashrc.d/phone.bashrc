#! /bin/bash

function ipfs.phone.add.staging ()
{
    /cygdrive/c/rclone/rclone copy -v --checksum carpo:/fileservers/mimas/E/Staging/Phone/Downloads "H:\Staging\Phone\Downloads"

    echo "Adding files to ipfs" >&2

    cid=$(ipfs add -r -w -Q --pin=false 'H:\Staging\Phone')

    ipfs dag export --progress=false "${cid}" > /cygdrive/h/ipfs-export/"${cid}".car \
        && /cygdrive/c/rclone/rclone move -v --checksum --include "${cid}.car" "H:\ipfs-export" "carpo:/data/ipfs-staging/IPFS Export Phone" \
        && /cygdrive/c/rclone/rclone move -v --checksum --include "${cid}.car" "carpo:/data/ipfs-staging" "carpo:/data/ipfs-export/IPFS Export Phone"
}