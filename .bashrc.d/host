#!/bin/bash


[[ "${HOSTENV_DEBUG}" ]] || [[ "${BASH_RC_D_DEBUG}" ]] && {
    echo "Searching for ${BASH_RC_HOST_DIR}" >&2
}
[[ -d "${BASH_RC_HOST_DIR}" ]] && {
    [[ "${HOSTENV_DEBUG}" ]] || [[ "${BASH_RC_D_DEBUG}" ]] && {
    echo "Found ${BASH_RC_HOST_DIR}" >&2
    }

    source_dir_files "${BASH_RC_HOST_DIR}"
}


