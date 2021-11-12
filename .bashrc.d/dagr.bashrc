#!/bin/bash

function populate_queue () {
    while true
    do
        while (( 0"$(_curl  192.168.20.50:3002/waiting | jq '.waiting')" <= 1 ));
        do
            sleep 30;
        done;
        echo "queue empty"
        read -r url  < output;
        echo "$url"
        _curl 192.168.20.50:3002/url -d "url=$url"
    done
}

export -f populate_queue