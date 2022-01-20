#! /bin/bash

function port_forward () {
    while :
    do
        sshp -vN phill@external1.ddns.peelvalley.com.au \
          -R 22022:127.0.0.1:22 \
          -R 3388:192.168.50.53:3389 \
          -R 3387:192.168.50.50:3389
        sleep 5
        echo "$(date) Reconnecting"
    done
}