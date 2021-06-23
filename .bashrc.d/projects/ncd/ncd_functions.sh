#!/bin/bash

alias sshp="ssh -p35681"

function ncd_push () {
    (cd "${SOURCE_DIR}/Phill/Repos/PVTE/NCDSprinkle" \
    && git pull \
    && git push \
    && sshp phill@kore.peelvalley.com.au docker exec -u www-data pvte-dev_ncd_dev_1 bash -c "'cd app/sprinkles/ncd && git fetch && git checkout origin/$(git branch --show-current)'")
}


function ncd_reset() {
  (cd "${SOURCE_DIR}/Phill/Repos/PVTE/NCDSprinkle" \
   && git reset --hard
  )
}


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

function build_ncd_image () {
  version_tag=$1
  if [[ -z "${version_tag}" ]]; then
    echo "Version tag is required"
    return 252
  fi
  sshp phill@kore.peelvalley.com.au bash -c "'source ~/.bashrc.d/dockerenv && build_pvte_image ncd --no-cache --tag 991291726468.dkr.ecr.ap-southeast-2.amazonaws.com/pvte/ncd:latest --tag 991291726468.dkr.ecr.ap-southeast-2.amazonaws.com/pvte/ncd:${version_tag}'"
}

function ncd_release () {
  version_tag=$1
  if [[ -z "${version_tag}" ]]; then
    echo "Version tag is required"
  else
    (cd "${SOURCE_DIR}/Phill/Repos/PVTE/NCDSprinkle" \
    && start_release "${version_tag}" \
    && sleep 30 \
    && finish_release "${version_tag}"
    ) \
    && ncd_push \
    && build_ncd_image "${version_tag}"
  fi
}

function ncd_publish () {
  version_tag=$1
  if [[ -z "${version_tag}" ]]; then
    echo "Version tag is required"
    return 252
  fi
  sshp phill@kore.peelvalley.com.au bash -c "'source ~/.bashrc.d/dockerenv && aws_publish pvte/ncd ${version_tag}'"
}

function ncd_deploy () {
    sshp phill@kore.peelvalley.com.au bash -c "'source ~/.bashrc.d/dockerenv && pvte_prod_service_deploy_hughes ncd'"
}