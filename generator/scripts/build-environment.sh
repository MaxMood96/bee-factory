#!/bin/bash

set -o errexit
set -o pipefail

usage() {
    cat << USAGE >&2
USAGE:
    $ build-environment.sh [PARAMETERS]
PARAMETERS:
    --build-base-bee                          The base bee image will be built from source code
    --base-bee-commit-hash=string             the source code commit hash of the base bee; Default: HEAD; Dependency: --build-base-bee
    --gen-traffic                             Generate traffic before bee image commit.
    --gen-traffic-upload-node=string          The traffic will be generated on the node under the given API URL. Default: http://locahost:1635; Dependency: --gen-traffic
    --gen-traffic-upload-node-debug=string    The traffic will be generated on the node under the given API URL. Default: http://locahost:1635; Dependency: --gen-traffic
    --gen-traffic-checker-node-debug=string   The incoming cheques will be checked on the node under the given Debug API URL. Default: http://localhost:11635; Dependency: --gen-traffic
    --cheques-count=number                    This amount of cheques is intended to be generated by the traffic gen. Default: 1; Dependency: --gen-traffic
USAGE
    exit 1
}

echoerr() {
     >&2 echo "$@"
}

build_bee() {
    # Clone source code
    BEE_SOURCE_PATH=$MY_PATH/../bee
    if [ -d "$BEE_SOURCE_PATH" ] ; then
        rm -rf "$BEE_SOURCE_PATH"
    fi
    mkdir "$BEE_SOURCE_PATH" && cd "$BEE_SOURCE_PATH" || exit 1
    git init
    git remote add origin https://github.com/ethersphere/bee.git
    git fetch origin --depth=1 "$COMMIT_HASH"
    git reset --hard FETCH_HEAD
    # Build bee and make docker image
    export BEE_VERSION=${COMMIT_HASH::7}-commit
    make binary
    echo "Bee image will be built with version: $BEE_VERSION"
    docker build . -t ethersphere/bee:$BEE_VERSION
    cd "$MY_PATH" || exit 1
    # Set build image tag so that other terminal session can retrieve
    "$MY_PATH/utils/build-image-tag.sh" set "$BEE_VERSION"
}

deploy_contracts_and_return_labels() {
  LABELS=""

  while IFS=$'\n' read -r contract; do
    LABELS+=" --label org.ethswarm.beefactory.contracts.$(echo $contract | cut -d ":" -f 4)=$(echo $contract | cut -d ":" -f 5)"
  done < <(npm run migrate:contracts | grep ^::CONTRACT)

  echo "$LABELS"
}

MY_PATH=$(dirname "$0")
MY_PATH=$( cd "$MY_PATH" && pwd )
COMMIT_HASH=HEAD
BUILD_BASE_BEE=false
GEN_TRAFFIC=false
GEN_TRAFFIC_CHECKER_NODE_DEBUG="http://localhost:1635"
GEN_TRAFFIC_UPLOAD_NODE="http://localhost:11633"
GEN_TRAFFIC_UPLOAD_NODE_DEBUG="http://localhost:11635"
CHEQUES_COUNT=1
# Bee version here means the base bee version on which the images will be built
BEE_VERSION=$("$MY_PATH/utils/env-variable-value.sh" BEE_VERSION)
BLOCKCHAIN_VERSION=$("$MY_PATH/utils/env-variable-value.sh" BLOCKCHAIN_VERSION)

SUPPORTED_WORKER_N=4

# handle passed options
while [ $# -gt 0 ]
do
    case "$1" in
        --build-base-bee)
        BUILD_BASE_BEE=true
        shift 1
        ;;
        --base-bee-commit-hash=*)
        COMMIT_HASH="${1#*=}"
        shift 1
        ;;
        --gen-traffic)
        GEN_TRAFFIC=true
        shift 1
        ;;
        --cheques-count=*)
        CHEQUES_COUNT=${1#*=}
        shift 1
        ;;
        --gen-traffic-upload-node=*)
        GEN_TRAFFIC_UPLOAD_NODE="${1#*=}"
        shift 1
        ;;
        --gen-traffic-upload-node-debug=*)
        GEN_TRAFFIC_UPLOAD_NODE_DEBUG="${1#*=}"
        shift 1
        ;;
        --gen-traffic-checker-node-debug=*)
        GEN_TRAFFIC_CHECKER_NODE_DEBUG="${1#*=}"
        shift 1
        ;;
        *)
        echoerr "Unknown argument: $1"
        usage
        ;;
    esac
done

# cleanup for start from an empty state
"$MY_PATH/bee-cleanup.sh"

if $BUILD_BASE_BEE ; then
    build_bee
fi
"$MY_PATH/network.sh"
"$MY_PATH/blockchain.sh"
DOCKER_CONTRACT_LABELS=$(deploy_contracts_and_return_labels)
npm run supply
chmod -R 777 "$MY_PATH/bee-data-dirs/"

if $GEN_TRAFFIC ; then
    export STATE_COMMIT='true'
    echo "Bee image with special state will be commited... traffic generation is on."
    # give the permission to the bee user
    echo "Start Bee nodes so that traffic can be generated and commited to the images"
    "$MY_PATH/bee.sh" start --version="$BEE_VERSION" --workers=$SUPPORTED_WORKER_N --detach
    echo "Generating traffic on Bee node $GEN_TRAFFIC_UPLOAD_NODE"
    echo "Run traffic generation until $CHEQUES_COUNT incoming cheques will arrive to node under Debug API $GEN_TRAFFIC_CHECKER_NODE_DEBUG"
    npm run gen:traffic -- "$CHEQUES_COUNT" "$GEN_TRAFFIC_CHECKER_NODE_DEBUG;$GEN_TRAFFIC_UPLOAD_NODE;$GEN_TRAFFIC_UPLOAD_NODE_DEBUG"
    echo "traffic has been generated"

    # This sets output parameter in Github Actions that
    # is then used to trigger Bee-js PR creation
    if [ "$CI" == 'true' ]; then
      echo "Image version tag will be extracted from the bee version command..."
      docker pull "ethersphere/bee:$BEE_VERSION"
      FULL_BEE_VERSION=$(docker run --rm "ethersphere/bee:$BEE_VERSION" version 2>&1)
      echo "Extracted Bee version: $FULL_BEE_VERSION"
      echo "::set-output name=full-version::$FULL_BEE_VERSION"

      npm run setApiVersions "$GEN_TRAFFIC_CHECKER_NODE_DEBUG"
    fi

    "$MY_PATH/bee.sh" stop
    docker container prune -f

    export BLOCKCHAIN_VERSION+="-for-$BEE_VERSION"
fi
"$MY_PATH/bee-docker-build.sh" "$DOCKER_CONTRACT_LABELS"
"$MY_PATH/blockchain-docker-build.sh"
