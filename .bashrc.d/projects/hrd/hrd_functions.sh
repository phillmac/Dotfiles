#!/bin/bash


function hrd_push () {
    (cd "${SOURCE_DIR}Phill/Repos/EPRA/HRDSprinkle" \
    && git pull \
    && git push \
    && sshp phill@kore.peelvalley.com.au docker exec -u www-data epra-dev_hrd_dev_1 bash -c "'cd app/sprinkles/hrd && git fetch && git checkout origin/$(git branch --show-current)'")
}


