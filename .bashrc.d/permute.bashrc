#!/bin/bash

PERMUTE_CACHRSET=({a..z} {A..Z} {0..9} _ - / . '%20')
PERMUTE_FILTERS=('/*' '//*')

permute(){
    for f in "${PERMUTE_FILTERS[@]}"
    do
        #shellcheck disable=SC2053
        [[ "$2" == $f ]] && return
    done

    (($1 == 0)) && { echo "$2"; return; }
    for char in "${PERMUTE_CACHRSET[@]}"
    do
        permute "$((${1} - 1 ))" "$2$char"
    done
}

export PERMUTE_CACHRSET
export PERMUTE_FILTERS

export -f permute

