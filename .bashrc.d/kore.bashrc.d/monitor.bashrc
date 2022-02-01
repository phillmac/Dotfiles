#! /bin/bash

function monitor_metis_site_vpn ()
{
    while :
    do
        sleep 5m &
        if sshp external7.ddns.peelvalley.com.au curl -s --fail -m 30 192.168.42.32:8081/ping > /dev/null
        then
            echo "$(date) ok"
        else
            echo "$(date) fail"
        fi
        wait
    done
}