#!/bin/bash
#
# This script runs the cockroach stress tests on AWS.
#
# If run as a cron job, make sure you set your basic environment variables.
# Run with:
# run_stress.sh [log dir]
#
# Logs will be saved in [log dir]/date-time/[instance number]/
#
# Requirements for this to work:
# * basic environment variables set: HOME, PATH, GOPATH
# * ~/.aws/credentials with valid AWS credentials
# * terraform installed in your PATH
# * <COCKROACH_BASE>/cockroach-prod repo cloned and up to date
# * <COCKROACH_BASE>/cockroach-prod/tools/supervisor/supervisor tool compiled
# * EC2 keypair under ~/.ssh/cockroach-${USER}.pem
#
# This script retries various operations quite a bit, but without
# a limit on the number of retries. This may cause issues.
#
# A sample crontab (to be filled-in) to run this nightly would be:
# MAILTO=myaddress@myprovider.com
# USER=MYUSER
# HOME=/home/MYUSER
# PATH=/bin:/sbin:/usr/bin:/usr/bin:/usr/local/bin:/usr/local/sbin:/home/MYUSER/bin:/home/MYUSER/go/bin
# GOPATH=/home/MYUSER/cockroach
#
# 0 0 * * * /home/MYUSER/cockroach/src/github.com/cockroachdb/cockroach-prod/scripts/run_stress.sh /MYLOGDIR/ > /MYLOGDIR/LATEST 2>&1

set -x

source $(dirname $0)/utils.sh

COCKROACH_BASE="${GOPATH}/src/github.com/cockroachdb"
LOGS_DIR="${1-$(mktemp -d)}"
MAILTO="${MAILTO-}"
KEY_NAME="${KEY_NAME-cockroach-${USER}}"

SSH_KEY="~/.ssh/${KEY_NAME}.pem"
SSH_USER="ubuntu"
TESTS_PATH="cockroach/static-tests.tar.gz"
STRESS_BINARY_PATH="stress/stress"
run_timestamp=$(date  +"%Y-%m-%d-%H:%M:%S")

PROD_REPO="${COCKROACH_BASE}/cockroach-prod"

which terraform > /dev/null
if [ $? -ne 0 ]; then
  echo "Could not find terraform in your path"
  exit 1
fi

monitor="${PROD_REPO}/tools/supervisor/supervisor"
if [ ! -e "${monitor}" ]; then
  echo "Could not locate supervisor monitor at ${monitor}"
  exit 1
fi

tests_sha=$(latest_sha ${TESTS_PATH})
stress_sha=$(latest_sha ${STRESS_BINARY_PATH})

cd "${COCKROACH_BASE}/cockroach/cloud/aws/stress"

# Start the instances and work.
do_retry "terraform apply --var=key_name=${KEY_NAME} --var=tests_sha=${tests_sha} --var=stress_sha=${stress_sha}" 5 5
if [ $? -ne 0 ]; then
  echo "Terraform apply failed."
  return 1
fi

# Fetch instances names.
instances=$(terraform output instance|cut -d'=' -f2|tr ',' ' ')
supervisor_hosts=$(echo ${instances}|fmt -1|awk '{print $1 ":9001"}'|xargs|tr ' ' ',')

status="PASSED"
summary=$(${monitor} --program=stress --addrs=${supervisor_hosts})
if [ $? -ne 0 ]; then
  status="FAILED"
fi

# Fetch all logs.
mkdir -p "${LOGS_DIR}"
for i in ${instances}; do
  scp -i ${SSH_KEY} -r -oStrictHostKeyChecking=no ${SSH_USER}@${i}:logs "${LOGS_DIR}/${i}"
  if [ $? -ne 0 ]; then
    echo "Failed to fetch logs from ${i}"
  fi
done

# Destroy all instances.
do_retry "terraform destroy --var=key_name=${KEY_NAME} --force" 5 5
if [ $? -ne 0 ]; then
  echo "Terraform destroy failed."
  return 1
fi

# Send email.
if [ -z "${MAILTO}" ]; then
  echo "MAILTO variable not set, not sending email."
  exit 0
fi

cd "${LOGS_DIR}"
binary_sha_link ${TESTS_PATH} ${tests_sha} > summary.txt
echo "${summary}" >> summary.txt
echo "" >> summary.txt
echo "Packages:" >> summary.txt
attach_args="--content-type=text/plain"
for i in ${instances}; do
  pushd ${i}
  for test in $(find cockroach/ -type f -name '*.stdout' | sed 's/.stdout$//' | sort); do
    result=$(tail -n 1 "${test}.stdout")
    if [ "${result}" != "SUCCESS" ]; then
      status="FAILED"
      result="FAILED"
    fi
    echo "${test}: ${result}" >> ../summary.txt
    flat_name=$(echo ${test} | tr '/' '_')
    if [ -s "${test}.stdout" ]; then
      tail -n 10000 "${test}.stdout" > ../${flat_name}.stdout
      attach_args="${attach_args} -A ${flat_name}.stdout"
    fi
    if [ -s "${test}.stderr" ]; then
      tail -n 10000 "${test}.stderr" > ../${flat_name}.stderr
      attach_args="${attach_args} -A ${flat_name}.stderr"
    fi
  done
  popd
done

mail ${attach_args} -s "Stress tests ${status} ${run_timestamp}" ${MAILTO} < summary.txt
