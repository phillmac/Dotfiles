#! /bin/bash

function sgcam_push () {
    (cd "${SOURCE_DIR}/Phill/Repos/SiteGuard/SGCam" \
    && git pull \
    && git push \
    && sshp phill@kore.peelvalley.com.au docker exec -u www-data sg-dev_sgcam_dev_1 bash -c "'cd app/sprinkles/sgcam && git fetch && git checkout origin/$(git branch --show-current)'")
}

function build_sg_image () {
  version_tag=$1
  if [[ -z "${version_tag}" ]]; then
    echo "Version tag is required"
    return 252
  fi
  sshp phill@kore.peelvalley.com.au bash -c "'source ~/.bashrc.d/dockerenv && build_sg_image sgcam --no-cache --tag siteguard/sgcam:${version_tag}'"
}
