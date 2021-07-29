#!/bin/bash


function hrd_push () {
    (cd "${SOURCE_DIR}/Phill/Repos/EPRA/HRDSprinkle" \
    && git pull \
    && git push \
    && sshp phill@kore.peelvalley.com.au docker exec -u www-data epra-dev_hrd_dev_1 bash -c "'cd app/sprinkles/hrd && git fetch && git checkout origin/$(git branch --show-current)'")
}

function build_hrd_image () {
  version_tag=$1
  if [[ -z "${version_tag}" ]]; then
    echo "Version tag is required"
    return 252
  fi
  sshp phill@kore.peelvalley.com.au bash -c "'source ~/.bashrc.d/dockerenv && build_epra_image hrd --no-cache --tag epra/hrd:${version_tag}'"
}
