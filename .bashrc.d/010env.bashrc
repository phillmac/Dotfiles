#! /bin/bash
shorthost=$(cut -d"." -f1 <<<"$HOSTNAME")
SHORT_HOST=${shorthost,,}
BASH_RC_DIR="${HOME}/.bashrc.d"
BASH_RC_HOST_DIR="${HOME}/.bashrc.d/${SHORT_HOST}.bashrc.d"

export SHORT_HOST
export BASH_RC_DIR
export BASH_RC_HOST_DIR