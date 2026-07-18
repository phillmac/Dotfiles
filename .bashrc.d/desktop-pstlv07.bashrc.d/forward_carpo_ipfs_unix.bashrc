#! /bin/bash

function forward_carpo_ipfs_unix()
{
    local action="${1:-start}"

    local host="carpo"
    local local_api="127.0.0.1:5001"

    # Socket created on carpo:
    local remote_socket_name="ipfs-laptop-api.sock"

    # Dedicated local SSH control socket:
    local local_run_dir="${XDG_RUNTIME_DIR:-$HOME/.var/run}"
    local control_socket="${local_run_dir}/carpo-ipfs-forward.ctl"

    local remote_home
    local remote_socket

    install -d -m 700 "$local_run_dir" || return 1

    case "$action" in
        start)
            # Do not start a duplicate managed tunnel.
            if ssh -S "$control_socket" -O check "$host" \
                    >/dev/null 2>&1; then
                echo "Carpo IPFS forwarding is already running."
                return 0
            fi

            # Remove a stale local SSH control socket.
            rm -f -- "$control_socket"

            # Confirm the laptop IPFS RPC API is available.
            if ! curl \
                    --silent \
                    --show-error \
                    --fail \
                    --max-time 3 \
                    -X POST \
                    "http://${local_api}/api/v0/version" \
                    >/dev/null
            then
                echo "IPFS RPC API is not responding at ${local_api}." >&2
                return 1
            fi

            # Initialise the runtime directory on carpo, remove any socket
            # left behind by an interrupted previous tunnel, and obtain the
            # absolute remote home directory.
            remote_home="$(
                ssh "$host" '
                    install -d -m 700 "$HOME/.var/run" &&
                    rm -f -- "$HOME/.var/run/ipfs-laptop-api.sock" &&
                    printf "%s" "$HOME"
                '
            )" || {
                echo "Unable to initialise the socket directory on carpo." >&2
                return 1
            }

            remote_socket="${remote_home}/.var/run/${remote_socket_name}"

            # Start a background SSH control-master connection.
            if ! ssh \
                    -M \
                    -S "$control_socket" \
                    -fNT \
                    -o ExitOnForwardFailure=yes \
                    -o ServerAliveInterval=10 \
                    -o ServerAliveCountMax=12 \
                    -R "${remote_socket}:${local_api}" \
                    "$host"
            then
                echo "Unable to establish the IPFS forwarding tunnel." >&2
                rm -f -- "$control_socket"

                ssh "$host" \
                    'rm -f -- "$HOME/.var/run/ipfs-laptop-api.sock"' \
                    >/dev/null 2>&1 || true

                return 1
            fi

            echo "IPFS forwarding started:"
            echo "  laptop ${local_api}"
            echo "      -> carpo:${remote_socket}"
            ;;

        stop)
            if ssh -S "$control_socket" -O check "$host" \
                    >/dev/null 2>&1
            then
                ssh -S "$control_socket" -O exit "$host" \
                    >/dev/null 2>&1 || true
            fi

            rm -f -- "$control_socket"

            # Explicitly remove the remote listener in case it was left stale.
            if ! ssh "$host" \
                    'rm -f -- "$HOME/.var/run/ipfs-laptop-api.sock"'
            then
                echo "Warning: could not clean the socket on carpo." >&2
                echo "It will be removed during the next start." >&2
            fi

            echo "IPFS forwarding stopped."
            ;;

        status)
            if ssh -S "$control_socket" -O check "$host" \
                    >/dev/null 2>&1
            then
                echo "Carpo IPFS forwarding is running."

                ssh "$host" '
                    if [ -S "$HOME/.var/run/ipfs-laptop-api.sock" ]; then
                        echo "Remote socket: $HOME/.var/run/ipfs-laptop-api.sock"
                    else
                        echo "Warning: SSH is running but the remote socket is absent."
                    fi
                '
            else
                echo "Carpo IPFS forwarding is stopped."
                return 1
            fi
            ;;

        restart)
            forward_carpo_ipfs_unix stop
            forward_carpo_ipfs_unix start
            ;;

        *)
            echo "Usage: forward_carpo_ipfs_unix {start|stop|restart|status}" >&2
            return 2
            ;;
    esac
}