#! /bin/bash


function mimas.staging.fetch () {
    tee mimas.staging.dirs.txt < <(cd '/e/Staging/Mimas/Downloads' && find . -mindepth 1 -maxdepth 1 -type d -printf "%f\n")
    dircount=$(wc -l < mimas.staging.dirs.txt)
    dcount=1

    while ((dcount < dircount)); do
        head -n $((dcount++)) < mimas.staging.dirs.txt > >(
            tail -n 1 > >(
                read -r incdirname;
                echo
                echo "$(date) Transfering ${incdirname}";
                cd '//DESKTOP-PSTLV07/G/Staging/Mimas' && \
                    /c/Scripts/rclone.exe move -v \
                    --delete-empty-src-dirs \
                    --dry-run=false \
                    --include "${incdirname}"'/**' \
                    'E:\Staging\Mimas\Downloads' \
                    'Downloads';
                    echo
            )
        )
        read -p 'Press enter'
        echo
    done
}