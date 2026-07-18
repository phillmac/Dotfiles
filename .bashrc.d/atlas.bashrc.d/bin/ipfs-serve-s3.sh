#! /bin/bash

function rclone_data_s3cache () {
    if [[ -t 1 ]] &&  [[ -t 2 ]] && [[ ! -p /dev/stdout ]] && [[ ! -p /dev/stdin ]]
    then
        echo 'Detected TTY' >&2
        podman run -it \
            --rm \
            --net host \
            --log-driver none \
            -v /data/s3cache:/data/s3cache \
            -v "${HOME}":/root \
            -v /home/almalinux/.var/run/:/home/almalinux/.var/run/ \
            --entrypoint rclone \
            peelvalley/rclone-b2 "${@}"
    else
        podman run \
            --rm \
            --net host \
            --log-driver none \
            -v /data/s3cache:/data/s3cache \
            -v "${HOME}":/root \
            -v /home/almalinux/.var/run/:/home/almalinux/.var/run/ \
            --entrypoint rclone \
            peelvalley/rclone-b2 "${@}"
    fi

}


function serve_ipfs_wasabi ()
{
    rclone_data_s3cache -vvv serve s3 \
        --addr 127.0.1.1:9100 \
        --transfers 10 \
        --no-modtime \
        --dir-cache-time 24h \
        --vfs-cache-mode full \
        --vfs-cache-max-age 30d \
        --vfs-write-back 5s \
        --vfs-fast-fingerprint \
        --vfs-cache-min-free-space 1T \
        --vfs-cache-max-size 5T \
        --cache-dir /data/ipfs-wasabi-s3-cache \
        wasabi-us-east-2:
}

function serve_ipfs_wasabi_test ()
{
    rclone_data_s3cache -vvv serve s3 \
        --addr 127.0.1.1:9100 \
        --transfers 10 \
        --no-modtime \
        --dir-cache-time 24h \
        --vfs-cache-mode full \
        --vfs-cache-max-age 30d \
        --vfs-write-back 5s \
        --vfs-fast-fingerprint \
        --vfs-cache-min-free-space 1T \
        --vfs-cache-max-size 5T \
        --cache-dir /data/ipfs-wasabi-s3-cache \
        local:/root/ipfs-wasabi-test-blocks
}
