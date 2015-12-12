#!/bin/bash
#
# A thin wrapper around the `terrafarm` test runner.
# Requirements for this to work:
# * working Go environment: GOPATH (but possibly HOME, PATH, GOPATH, GOROOT)
# * ~/.aws/credentials with valid AWS credentials
# * ~/.ssh/${KEY_NAME}.pem downloaded from AWS.
# * terraform installed in your PATH
# * for mailing the results to work: Linux.
#
# A sample crontab (to be filled-in) to run this nightly would be:
# MAILTO=myaddress@myprovider.com
# KEY_NAME=cockroach-craig
# HOME=/home/MYUSER
# PATH=/bin:/sbin:/usr/bin:/usr/bin:/usr/local/bin:/usr/local/sbin:/home/MYUSER/bin:/home/MYUSER/go/bin
# GOPATH=/home/MYUSER/cockroach
#
# 0 0 * * * /home/MYUSER/cockroach/src/github.com/cockroachdb/cockroach-prod/scripts/run_cluster.sh

set -eu

LOGS_DIR="${1-$(mktemp -d)}"
KEY_NAME="${KEY_NAME}" # no default, want to crash if not supplied
MAILTO="${MAILTO-}"

mkdir -p "${LOGS_DIR}"

function finish() {
  [[ $? -eq 0 ]] && STATUS="OK" || STATUS="FAIL"
  set +e

  cd "${LOGS_DIR}"
  pwd

  if [ -z "${MAILTO}" ]; then
    echo "MAILTO variable not set, not sending email."
    return
  fi

  # Generate message and attach logs for each instance.
  attach_args="--content-type=text/plain"
  for i in $(seq 0 4); do
    tail -n 10000 node.${i}/cockroach.stderr > node.${i}.stderr
    tail -n 10000 node.${i}/cockroach.stdout > node.${i}.stdout
    tail -n 10000 writer.${i}/block_writer.stderr > block_writer.stderr
    tail -n 10000 writer.${i}/block_writer.stdout > block_writer.stdout
    attach_args="${attach_args} -A node.${i}.stderr -A node.${i}.stdout"
    attach_args="${attach_args} -A writer.${i}.stderr -A writer.${i}.stdout"
  done

  mail ${attach_args} -s "[${STATUS}] nightly cluster test" "${MAILTO}" < test.txt
}

trap finish EXIT

exec go test -v -timeout 24h -run FiveNodesAndWriters \
  github.com/cockroachdb/cockroach-prod/tools/terrafarm \
  -d 1h -key-name "${KEY_NAME}" -l "${LOGS_DIR}" 2>&1 \
  | tee "${LOGS_DIR}/test.txt"
