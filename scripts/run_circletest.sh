#!/usr/bin/env bash

set -ex

source $(dirname $0)/utils.sh

BUCKET_NAME="cockroach"
LATEST_SUFFIX=".LATEST"

$(download_binary "cockroach/acceptance.test")

LOGS_DIR="${CIRCLE_ARTIFACTS}"

./acceptance.test -test.v -test.run FiveNodesAndWriter -test.timeout 24h -remote -nodes 1 -d 1m -key-name google_compute_engine -l $LOGS_DIR -cwd "${HOME}/cockroach/cloud/gce" > >(tee "${LOGS_DIR}/test.stdout.txt") 2> >(tee "${LOGS_DIR}/test.stderr.txt" >&2)
# trick go2xunit - go test binaries won't print the package summary for some reason
echo 'ok github.com/cockroachdb/cockroach/acceptance 10.000s' >> "${LOGS_DIR}/test.stdout.txt"
mkdir -p ${CIRCLE_TEST_REPORTS}/acceptance
go2xunit < "${LOGS_DIR}/test.stdout.txt" > "${CIRCLE_TEST_REPORTS}/acceptance/acceptance.xml"
