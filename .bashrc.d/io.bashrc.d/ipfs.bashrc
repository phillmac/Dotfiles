#!/bin/bash


IPFS_GET_BATCH_COUNT=10
IPFS_GET_TIMEOUT="3600s"
IPFS_PIN_TIMEOUT="4h"
IPFS_RESOLVE_TIMEOUT="15m"
IPFS_PIN_SLEEP="1h"

IPFS_PIN_ALLOWED_START="19:00"
IPFS_PIN_ALLOWED_FIN="02:00"

IPFS_HTTP_GATEWAY="192.168.20.33:8080"


# function io.ipfs.preload ()
# {
#     local tmppipe

#     tmppipe=$(mktemp -u)
#     mkfifo -m 600 "${tmppipe}"
#     echo "Created ${tmppipe}"

#     tmux split ssh -p 35681 vps1.phillm.net 'mbuffer -I 40471 | docker exec -i phill-dev_ipfs_1 ipfs dag import --pin-roots=false'
#     tmux select-layout even-vertical
#     tmux split ssh -p 35681 vps2.phillm.net 'mbuffer -I 40471 | docker exec -i phill-dev_ipfs_1 ipfs dag import --pin-roots=false'
#     tmux select-layout even-vertical
#     tmux split ssh -p 35681 vps3.phillm.net 'mbuffer -I 40471 | docker exec -i phill-dev_ipfs_1 ipfs dag import --pin-roots=false'
#     tmux select-layout even-vertical
#     # tmux split ssh -p 35681 external5.ddns.peelvalley.com.au 'mbuffer -I 40471 | docker exec -i phill-dev_ipfs_1 ipfs dag import --pin-roots=false'
#     # tmux select-layout even-vertical
#     tmux split mbuffer -t -i "${tmppipe}" \
#         -O vps1.phillm.net:40471 \
#         -O vps2.phillm.net:40471 \
#         -O vps3.phillm.net:40471 \
#         # -O 192.168.35.51:40471
#     tmux select-layout even-vertical
#     echo "Exporting ${*}"
#     ipfs dag export -p "${@}" > "${tmppipe}"
#     # docker exec -i phill-dev_ipfs_1 ipfs dag export "${@}" | mbuffer | ./ipfs-s3 dag import --pin-roots=false
# }

# function io.ipfs.preload.s3 ()
# {
#     local tmppipe

#     tmppipe=$(mktemp -u)
#     mkfifo -m 600 "${tmppipe}"
#     echo "Created ${tmppipe}"

#     tmux split mbuffer < "${tmppipe}" | /home/phill/ipfs-s3 dag import --pin-roots=false
#     docker exec -i phill-dev_ipfs_1 ipfs dag export "${@}" > "${tmppipe}"
# }

function ipfs-wasabi ()
{
    IPFS_PATH='/home/phill/.ipfs-wasabi' ipfs-s3 "${@}"
}

function ipfs-backblaze ()
{
  IPFS_PATH='/home/phill/.ipfs-backblaze' ipfs-s3 "${@}"
}

export IPFS_GET_BATCH_COUNT
export IPFS_GET_TIMEOUT
export IPFS_PIN_TIMEOUT
export IPFS_RESOLVE_TIMEOUT
export IPFS_PIN_SLEEP
export IPFS_PIN_ALLOWED_START
export IPFS_PIN_ALLOWED_FIN
export IPFS_HTTP_GATEWAY

export -f io.ipfs.preload