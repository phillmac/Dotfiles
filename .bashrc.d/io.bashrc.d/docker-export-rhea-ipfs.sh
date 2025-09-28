#!/usr/bin/env bash
set -euo pipefail

# Root folder in MFS to hold everything
MFS_DIR="/docker-images/io/$(date +%Y%m%d-%H%M%S)"
echo "Creating MFS dir: $MFS_DIR"
rhea_ipfs_local_api files mkdir -p "$MFS_DIR"

sanitize() {
  # make a safe filename from repo:tag (or image id)
  # replace / and : with __ and strip spaces
  echo "$1" | tr '/:' '__' | tr -s ' ' '_'
}

# Iterate over repo:tag and ID (prefer names; fall back to ID when <none>)
# This includes all local images; adjust query if you want to filter.
while IFS=$'\t' read -r repo_tag image_id; do
  # Handle dangling images
  if [[ "$repo_tag" == "<none>:<none>" || -z "$repo_tag" ]]; then
    base="image-${image_id}"
  else
    base="$repo_tag"
  fi

  fname="$(sanitize "$base")_$image_id.tar"
  mfs_path="$MFS_DIR/$fname"

  echo "$(date) Exporting $repo_tag ($image_id) -> $mfs_path"

  # Stream docker save directly into MFS
  # --create: create file; --parents: ensure dirs exist
  # If you ever rerun for same file, add --truncate to overwrite.
  docker save "$image_id" | mbuffer | rhea_ipfs_local_api files write --create --parents "$mfs_path"

done < <(docker images --format "{{.Repository}}:{{.Tag}}\t{{.ID}}")

# Flush MFS and get a stable directory CID for the whole folder
rhea_ipfs_local_api files flush "$MFS_DIR" >/dev/null
ROOT_CID=$(rhea_ipfs_local_api files stat --hash "$MFS_DIR")

echo "------------------------------------------------------------"
echo "MFS directory: $MFS_DIR"
echo "Root CID:      $ROOT_CID"
echo "Listing:"
rhea_ipfs_local_api files ls -l "$MFS_DIR"
echo "------------------------------------------------------------"

# Optional: also create an explicit pin for the folder root (MFS already keeps it reachable)
# rhea_ipfs_local_api pin add "$ROOT_CID" >/dev/null && echo "Pinned $ROOT_CID"