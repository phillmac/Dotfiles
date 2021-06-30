#!/bin/bash

function source_env_files () {
    local repos_dir
    repos_dir="${REPOS_DIR:-${HOME}/source/repos}"

    local repo_dirs_list=(
            "kapcd/Dev-Env"
            "pvs/Dev-Env"
            # "pvs/Build-Env"
            "phill/Dev-Env"
            "pvte/Dev-Env"
            "pvte/Prod-Env"
            "scouts/Dev-Env"
            "epra/Dev-Env"
            )

    for repo in "${repo_dirs_list[@]}"; do
        local scripts_dir
        scripts_dir="${repos_dir}/${repo}"/Scripts
        [[ "${DOCKERENV_DEBUG}" ]] || [[ "${BASH_RC_D_DEBUG}" ]] && {
            echo "Searching for ${scripts_dir}"
        }
        [[ -d "${repos_dir}/${repo}/Scripts" ]] && {
            [[ "${DOCKERENV_DEBUG}" ]]  || [[ "${BASH_RC_D_DEBUG}" ]] && {
                echo "Found ${scripts_dir}"
            }
            source_dir_files "${repos_dir}/${repo}/Scripts"
        }
    done

    if [[ -z "${SHORT_HOST}" ]]
    then
        echo "SHORT_HOST is empty" >&2
    else
        case "${SHORT_HOST}" in
            'io' )
                alias_pvs_dev_io
                alias_pvs_dev_update
                #alias_pvs_build_io
                #alias_pvs_build_update
                alias_kapcd_dev_io
                alias_kapcd_dev_update
                alias_phill_dev_io
                alias_phill_dev_update
                ;;
            'desktop-pstlv07' )
                ;;
            'charon' )
                alias_pvs_dev_charon
                alias_pvs_dev_update
                #alias_pvs_build_charon
                #alias_pvs_build_update
                #alias_kapcd_dev_charon
                #alias_kapcd_dev_update
                alias_phill_dev_charon
                alias_phill_dev_update
                ;;
            'callisto')
                alias_phill_dev_callisto
                alias_phill_dev_update
                ;;
            'kore' )
                alias_pvs_dev_kore
                alias_pvs_dev_update
                #alias_pvs_build_kore
                #alias_pvs_build_update
                alias_kapcd_dev_kore
                alias_kapcd_dev_update
                alias_phill_dev_kore
                alias_phill_dev_update
                alias_pvte_dev_kore
                alias_pvte_dev_update
                alias_scouts_dev_update
                alias_scouts_dev_kore
                alias_epra_dev_update
                alias_epra_dev_kore
                ;;
            'atlas' )
                alias_phill_dev_atlas
                alias_phill_dev_update
                ;;
            'hughes' )
                alias_pvte_prod_hughes
                alias_pvte_prod_update
                ;;

            'vps1' )
                alias_phill_dev_vps1
                alias_phill_dev_update
                ;;
            'vps2' )
                alias_phill_dev_vps2
                alias_phill_dev_update
                ;;
            'vps3' )
                alias_phill_dev_vps3
                alias_phill_dev_update
                ;;
            *)
                echo "Unkown host ${SHORT_HOST}"
                ;;
        esac
fi
}

source_env_files
