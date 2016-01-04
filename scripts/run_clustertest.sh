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
# 0 0 * * * /home/MYUSER/cockroach/src/github.com/cockroachdb/cockroach-prod/scripts/run_clustertest.sh

set -eux

LOGS_DIR="${1-$(mktemp -d)}"
KEY_NAME="${KEY_NAME-cockroach-${USER}}"
MAILTO="${MAILTO-}"
run_timestamp=$(date  +"%Y-%m-%d-%H:%M:%S")

mkdir -p "${LOGS_DIR}"

# Takes a log directory prefix (in the local directory) and log file name,
# creates trimmed versions and outputs the attach args to stdout.
function collate_logs() {
  prefix=$1
  name=$2
  a=""
  for i in ${prefix}*; do
    if [ -s "${i}/${name}.stderr" ]; then
      tail -n 10000 ${i}/${name}.stderr > ${i}.stderr
      a="${a} -A ${i}.stderr"
    fi
    if [ -s "${i}/${name}.stdout" ]; then
      tail -n 10000 ${i}/${name}.stdout > ${i}.stdout
      a="${a} -A ${i}.stdout"
    fi
  done
  echo ${a}
}

function finish() {
  [[ $? -eq 0 ]] && status="PASSED" || status="FAILED"
  set +e
  echo "Job status: ${status}"

  cd "${LOGS_DIR}"
  pwd

  if [ -z "${MAILTO}" ]; then
    echo "MAILTO variable not set, not sending email."
    return
  fi

  # Generate message and attach logs for each instance.
  node_args=$(collate_logs node cockroach)
  writer_args=$(collate_logs writer block_writer)

  cat test.stdout.txt test.stderr.txt |
  mail --content-type=text/plain ${node_args} ${writer_args} \
    -s "Cluster test ${status} ${run_timestamp}" "${MAILTO}"
}

trap finish EXIT

go test -v -tags acceptance -timeout 24h -run FiveNodesAndWriters \
  github.com/cockroachdb/cockroach/acceptance \
  -num-remote 1 -d 1h -key-name "${KEY_NAME}" -l "${LOGS_DIR}" \
  > "${LOGS_DIR}/test.stdout.txt" 2> "${LOGS_DIR}/test.stderr.txt"
