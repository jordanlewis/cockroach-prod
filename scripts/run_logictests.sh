#!/bin/bash
#
# This script runs the sql logic test on AWS.
#
# If run as a cron job, make sure you set your basic environment variables.
# Run with:
# run_logictests.sh [log dir]
#
# Logs will be saved in [log dir]/date-time/[instance number]/
#
# Requirements for this to work:
# * basic environment variables set: HOME, PATH, GOPATH
# * ~/.aws/credentials with valid AWS credentials
# * ~/.ssh/cockroach.pem downloaded from AWS.
# * terraform installed in your PATH
# * <COCKROACH_BASE>/sqllogictest repo cloned and up to date
# * <COCKROACH_BASE>/cockroach-prod repo cloned and up to date
# * <COCKROACH_BASE>/cockroach-prod/tools/supervisor/supervisor tool compiled to ${GOPATH}/bin/
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
# 0 0 * * * /home/MYUSER/cockroach/src/github.com/cockroachdb/cockroach-prod/scripts/run_logictests.sh /MYLOGDIR/ > /MYLOGDIR/LATEST 2>&1

set -x

source $(dirname $0)/utils.sh

COCKROACH_BASE="${GOPATH}/src/github.com/cockroachdb"
LOGS_DIR="${1-$(mktemp -d)}"
MAILTO="${MAILTO-}"
KEY_NAME="${KEY_NAME-cockroach-${USER}}"

SSH_KEY="${HOME}/.ssh/${KEY_NAME}.pem"
SSH_USER="ubuntu"
BINARY_PATH="cockroach/sql.test"
run_timestamp=$(date  +"%Y-%m-%d-%H:%M:%S")

PROD_REPO="${COCKROACH_BASE}/cockroach-prod"
SQLTEST_REPO="${COCKROACH_BASE}/sqllogictest"

if [ -z "${SQLTEST_REPO}" ]; then
  echo "Could not find directory ${SQLTEST_REPO}"
  exit 1
fi

which terraform > /dev/null
if [ $? -ne 0 ]; then
  echo "Could not find terraform in your path"
  exit 1
fi

monitor="${GOPATH}/bin/supervisor"
if [ ! -e "${monitor}" ]; then
  echo "Could not locate supervisor monitor at ${monitor}"
  exit 1
fi

sqllogictest_sha=$(latest_sha ${BINARY_PATH})

cd "${COCKROACH_BASE}/cockroach/cloud/aws/tests"

# Start the instances and work.
do_retry "terraform apply --var=key_name=${KEY_NAME} --var=sqllogictest_sha=${sqllogictest_sha}" 5 5
if [ $? -ne 0 ]; then
  echo "Terraform apply failed."
  return 1
fi

# Fetch instances names.
instances=$(terraform output instance|cut -d'=' -f2|tr ',' ' ')
supervisor_hosts=$(echo ${instances}|fmt -1|awk '{print $1 ":9001"}'|xargs|tr ' ' ',')

status="PASSED"
summary=$(${monitor} --program=sql.test --addrs=${supervisor_hosts})
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
attach_args="--content-type=text/plain"
for i in ${instances}; do
  tail -n 10000 ${i}/sql.test.stdout > ${i}.stdout
  tail -n 10000 ${i}/sql.test.stderr > ${i}.stderr
  attach_args="${attach_args} -A ${i}.stdout -A ${i}.stderr"
done

binary_sha_link ${BINARY_PATH} ${sqllogictest_sha} > summary.txt
echo "" >> summary.txt
echo "${summary}" >> summary.txt
mail ${attach_args} -s "SQL logic test ${status} ${run_timestamp}" ${MAILTO} < summary.txt
