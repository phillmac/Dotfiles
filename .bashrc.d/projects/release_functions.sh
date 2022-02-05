#!/bin/bash

function start_release () {
version_tag=$1
  if [[ -z "${version_tag}" ]]; then
    echo "Version tag is required"
  else
    git flow release start "${version_tag}"
  fi
}

function finish_release () {
  version_tag=$1
  if [[ -z "${version_tag}" ]]; then
    echo "Version tag is required"
    return 252
  fi
  git flow release finish "${version_tag}" --message "Version ${version_tag}"
}

