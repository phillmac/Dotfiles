#! /bin/bash

function ipfs.phone.add.staging ()
{
    /cygdrive/c/rclone/rclone copy -v --checksum carpo:/fileservers/mimas/E/Staging/Phone/Downloads "H:\Staging\Phone\Downloads"

    cid=$(ipfs add -r -w -Q --pin=false 'H:\Staging\Phone')

    ipfs dag export --progress=false "${cid}" > /cygdrive/h/ipfs-export/"${cid}".car \
        && /cygdrive/c/rclone/rclone move -v --checksum --include '*.car' "H:\ipfs-export" "carpo:/data/ipfs-export/IPFS Export Phone"
}