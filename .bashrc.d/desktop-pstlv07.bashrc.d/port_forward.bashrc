#! /bin/bash

function port_foraward () {
    while :
    do
        sshp -vN phill@external1.ddns.peelvalley.com.au \
          -L 40261:192.168.42.230:40261 \
          -L 3388:192.168.42.208:3389 \
          -L 3387:192.168.30.50:3389 \
          -L 8442:192.168.42.228:443 \
          -L 22022:192.168.42.228:22
        sleep 5
        echo "$(date) Reconnecting"
    done
}