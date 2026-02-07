#! /bin/bash

function staging.add.export () {
    local dname=${1}
    local args=( "$@" );
    local dpath=( "${args[@]:1}" )

    local bname
    local dcid
    local empty
    local elem
    local mfspath



    if ! dcid=$(ipfs add -Q -r -w --pin=false "${dname}")
    then
        echo "Add ${dname} to IPFS failed"
        return 1
    fi
    empty=$(ipfs object new unixfs-dir)

    echo "Base dcid: ${dcid}" >&2

    for elem in "${dpath[@]}"
    do
        echo "Adding link ${elem} ${dcid} for mfs path ${mfspath}" >&2

        if ! dcid=$(ipfs object patch add-link -- "${empty}" "${elem}" "${dcid}")
        then
            echo "Failed to patch object ${empty} ${elem} ${dcid}"
            return 1
        fi

        mfspath="${elem}/${mfspath}"
    done

    echo "/ipfs/${dcid} /${mfspath}" >&2

    if ! grep -q "${dcid}" "/cygdrive/e/Staging/staging cids.txt"
    then
        echo "Exporting ${dcid}" >&2

        ipfs dag export -p "${dcid}" > "/cygdrive/h/ipfs-export/${dcid}.car"

        /cygdrive/c/rclone/rclone move -v "H:\ipfs-export\\${dcid}.car" carpo:/data/ipfs-staging
        /cygdrive/c/rclone/rclone move -v "carpo:/data/ipfs-staging/${dcid}.car" carpo:/data/ipfs-export

        echo "${dcid}" >> "/cygdrive/e/Staging/staging cids.txt"
    else
        echo "Found ${dcid} already exported" >&2
    fi

    bname=$(basename "${dname}")
    dnamepath=$(dirname "${dname}")

    echo "bname: ${bname}" >&2
    echo "dnamepath: ${dnamepath}" >&2


    (
        cd "${dnamepath}" \
            && pwd \
            && find "${bname}" -type f -printf '%P\n' | tee list.txt \
            && ( \
                cd "${bname}" &&
                /cygdrive/c/rclone/rclone.exe move \
                    -vv \
                    --checksum \
                    --delete-empty-src-dirs \
                    --files-from ../list.txt \
                    --local-encoding None \
                    --backup-dir="b2-phill-all:Archive-Store/_/Staging/${dpath[2]}/Downloads-Backup/${dname}/$(date '+%Y%m%d%H%M')" \
                    . \
                    "b2-phill-all:Archive-Store/_/Staging/${mfspath}" \
                    || /cygdrive/c/rclone/rclone.exe move \
                    -vv \
                    --checksum \
                    --delete-empty-src-dirs \
                    --files-from ../list.txt \
                    --backup-dir="b2-phill-all:Archive-Store/_/Staging/${dpath[2]}/Downloads-Backup/${dname}/$(date '+%Y%m%d%H%M')" \
                    . \
                    "b2-phill-all:Archive-Store/_/Staging/${mfspath}"
                    ) && rm -v list.txt
        )
}

function laptop.staging.add.export ()
{
    if [[ -z "${1}" ]]
    then

        while read -r odirname
        do
            bodirname=$(basename "${odirname}")

            if ! laptop.staging.add.export "${bodirname}"
            then
                return 1
            fi

        done < <(
            find /cygdrive/e/Staging/Laptop/Downloads -maxdepth 1 -mindepth 1 -type d -exec stat --format='%W %n' {} \; \
                | sort -n \
                | cut -d ' ' -f2-
            )

        return
    fi

    if [[ "${1}" == /* ]]
    then
        sname=${1}
    else
        sname=/cygdrive/e/Staging/Laptop/Downloads/${1}
    fi

    bsname=$(basename "${1}")

    (
        cd "${sname}" && {
            for sdname in */
            do
                bsdname=$(basename "${sdname}")

                if [[ -d  "/cygdrive/e/Staging/Laptop/Downloads/${bsname}/${bsdname}" ]]
                then
                    echo "$(date) adding ${bsdname}" >&2
                    staging.add.export "E:\\Staging\\Laptop\\Downloads\\${bsname}\\${bsdname}" "${bsname}" Downloads Laptop
                else
                    echo "Skipping nonexistent dir ${bsdname}" >&2
                fi

            done
        }
    )

    /cygdrive/c/rclone/rclone.exe rmdirs -vv --local-encoding=none "E:\\Staging\\Laptop\\Downloads\\${bsname}" \
    || /cygdrive/c/rclone/rclone.exe rmdirs -vv "E:\\Staging\\Laptop\\Downloads\\${bsname}"
}

function ipfs.mimas.add.staging () {

    if [[ -z "${1}" ]]
    then

        while read -r odirname
        do
            bodirname=$(basename "${odirname}")

            if ! laptop.staging.add.export "${bodirname}"
            then
                return 1
            fi

        done < <(
            find /cygdrive/g/Staging/Mimas/Downloads  -maxdepth 1 -mindepth 1 -type d -exec stat --format='%W %n' {} \; \
                | sort -n \
                | cut -d ' ' -f2-
            )

        return
    fi

    if [[ "${1}" == /* ]]
    then
        sname=${1}
    else
        sname=/cygdrive/g/Staging/Mimas/Downloads/${1}
    fi

    (
        cd "${sname}" && {
            for sdname in */
            do
                bsdname=$(basename "${sdname}")
                if [[ -d  "/cygdrive/g/Staging/Mimas/Downloads/${1}/${bsdname}" ]]
                then
                    echo "$(date) adding ${bsdname}" >&2
                    staging.add.export "G:\Staging\Mimas\Downloads\\${1}\\${bsdname}" "${1}" Downloads Mimas
                else
                    echo "Skipping nonexistent dir ${bsdname}" >&2
                fi
            done
        }
    )
}

function laptop.staging.processed.upload ()
(
    cd  /cygdrive/E/Staging/Laptop \
    && /cygdrive/C/rclone/rclone move \
        --local-encoding=None \
        --progress \
        --transfers 15 \
        --delete-empty-src-dirs \
        --backup-dir="b2-phill-all:Archive-Store/_/Staging/Laptop/Downloads-Backup/$(date '+%Y%m%d%H%M')" \
        Downloads-Processed \
        b2-phill-all:Archive-Store/_/Staging/Laptop/Downloads
)


function mimas.staging.processed.upload ()
(
    cd  /cygdrive/G/Staging/Mimas \
    && /cygdrive/C/rclone/rclone move \
        --local-encoding=None \
        --progress \
        --transfers 15 \
        --delete-empty-src-dirs \
        --backup-dir="b2-phill-all:Archive-Store/_/Staging/Mimas/Downloads-Backup/$(date '+%Y%m%d%H%M')" \
        Downloads-Processed \
        b2-phill-all:Archive-Store/_/Staging/Mimas/Downloads
)

function mimas.staging.fetch () {
    local src_root='//mimas/E/Staging/Mimas/Downloads'
    local src_parent='//mimas/E/Staging/Mimas'
    local dst_root='G:\Staging\Mimas\Downloads'

    # Persistent ledger for the 24h sliding window (epoch_seconds<TAB>bytes<TAB>dirname)
    local state_dir="${HOME}/.mimas-staging"
    local log_file="${state_dir}/transfer_ledger.tsv"
    mkdir -p "$state_dir"

    # --- helpers -------------------------------------------------------------

    # Return size in BYTES for a directory (best-effort across du variants)
    folder_bytes() {
        local p="$1" out
        if out=$(du --apparent-size -sb "$p" 2>/dev/null); then
            printf '%s\n' "$out" | awk '{print $1}'
        elif out=$(du -sb "$p" 2>/dev/null); then
            printf '%s\n' "$out" | awk '{print $1}'
        elif out=$(du --apparent-size -sk "$p" 2>/dev/null); then
            printf '%s\n' "$out" | awk '{print $1*1024}'
        elif out=$(du -sk "$p" 2>/dev/null); then
            printf '%s\n' "$out" | awk '{print $1*1024}'
        else
            echo 0
        fi
    }

    # Human readable bytes
    human_bytes() {
        local b="${1:-0}"
        if command -v numfmt >/dev/null 2>&1; then
            numfmt --to=iec-i --suffix=B --format="%.2f" "$b"
        else
            awk -v b="$b" 'BEGIN{
                split("B KiB MiB GiB TiB PiB",u," ");
                i=1;
                while(b>=1024 && i<6){ b/=1024; i++ }
                printf "%.2f %s", b, u[i]
            }'
        fi
    }

    # Sum bytes transferred within the last 24h (sliding window), and prune old rows
    last24_bytes() {
        local now cutoff tmp sum
        now=$(date +%s)
        cutoff=$((now - 86400))

        [[ -f "$log_file" ]] || { echo 0; return; }

        sum=$(awk -v cutoff="$cutoff" '$1>=cutoff {sum+=$2} END{printf "%.0f", sum+0}' "$log_file")
        tmp="${log_file}.tmp.$$"
        awk -v cutoff="$cutoff" '$1>=cutoff' "$log_file" > "$tmp" && mv -f "$tmp" "$log_file"
        echo "${sum:-0}"
    }

    # --- main ----------------------------------------------------------------

    tee mimas.staging.dirs.txt < <(cd "$src_root" && find . -mindepth 1 -maxdepth 1 -type d -printf "%f\n")
    local dircount dcount=1
    dircount=$(wc -l < mimas.staging.dirs.txt)

    while IFS= read -r incdirname; do
        ((dcount++))

        local src_dir="$src_root/$incdirname"
        local bytes total_before total_after now

        bytes=$(folder_bytes "$src_dir")
        total_before=$(last24_bytes)

        echo "[$dcount/$dircount] $(date) Transferring ${incdirname}"
        echo "  Folder size:        $(human_bytes "$bytes") (${bytes} bytes)"
        echo "  Last 24h (sliding): $(human_bytes "$total_before") (${total_before} bytes)"

        cd "$src_parent" && \
            /cygdrive/c/rclone/rclone.exe move -v \
                --delete-empty-src-dirs \
                --include "${incdirname}/**" \
                'Downloads' \
                "$dst_root"
        local rc=$?

        if (( rc == 0 )); then
            now=$(date +%s)
            printf '%s\t%s\t%s\n' "$now" "$bytes" "$incdirname" >> "$log_file"
            total_after=$(last24_bytes)
            echo "  ✅ Counted this transfer."
            echo "  Last 24h (sliding): $(human_bytes "$total_after") (${total_after} bytes)"
        else
            echo "  ❌ rclone failed (exit $rc); not counting this transfer in 24h total." >&2
        fi

        read -p 'Press enter' </dev/tty
    done < mimas.staging.dirs.txt
}
