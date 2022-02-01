#! /bin/bash

function test_metis_site_vpn ()

{
    sshp external7.ddns.peelvalley.com.au curl -s --fail -m "${1:-30}" 192.168.42.32:8081/ping > /dev/null
}

function monitor_metis_site_vpn ()
{
    local retest_fail_count

    while :
    do
        sleep 5m &
        if test_metis_site_vpn 30
        then
            echo "$(date) ok"
        else
            ((retest_fail_count=0))
            while ((retest_fail_count < 10))
            do
                if test_metis_site_vpn 15
                then
                    break
                else
                    echo "$(date) fails ${retest_fail_count}"
                    ((retest_fail_count++))
                fi
            done

            if ((retest_fail_count==5))
            then
                echo 'Reseting VPN connection'
                #ssh -p 35682 pfsense2 '/usr/local/sbin/pfSsh.php playback svc stop openvpn server 4'
            fi
        fi
        wait
    done
}