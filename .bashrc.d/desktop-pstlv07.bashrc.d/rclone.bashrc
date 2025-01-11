#! /bin/bash

function rclone_mount_carpo ()
{
    /cygdrive/c/rclone/rclone mount \
        -vvv\
        --transfers 4 \
        --attr-timeout 5m \
        --dir-cache-time 5m \
        --vfs-cache-mode full \
        --vfs-cache-max-age 24h \
        --vfs-write-back 5m \
        --cache-dir 'H:\.cache\rclone\carpo_root' \
        carpo:/ \
        X:
}