#! /bin/bash

function rclone_move_ananke () {
    docker run --rm --net host -v /root:/root -v /callisto:/callisto -v /ananke:/ananke peelvalley/rclone-b2 "rclone move --delete-empty-src-dirs -v ${*}"
}