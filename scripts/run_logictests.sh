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
# * <COCKROACH_BASE>/cockroach-prod/tools/supervisor/supervisor tool compiled
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
SQLTEST_REPO="${COCKROACH_BASE}/sqllogictest"
PROD_REPO="${COCKROACH_BASE}/cockroach-prod"
LOGS_DIR=$1
SSH_KEY=~/.ssh/cockroach.pem
SSH_USER="ubuntu"

if [ -z "${LOGS_DIR}" ]; then
  echo "No logs directory specified. Run with: $0 [logs dir]"
  exit 1
fi

if [ -z "${SQLTEST_REPO}" ]; then
  echo "Could not find directory ${SQLTEST_REPO}"
  exit 1
fi

if [ -z "${PROD_REPO}" ]; then
  echo "Could not find directory ${PROD_REPO}"
  exit 1
fi

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

run_timestamp=$(date  +"%Y-%m-%d-%H:%M:%S")
cd "${PROD_REPO}/terraform/aws/tests"

# Start the instances and work.
do_retry "terraform apply" 5 5
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
mkdir -p "${LOGS_DIR}/${run_timestamp}"
for i in ${instances}; do
  scp -i ${SSH_KEY} -r -oStrictHostKeyChecking=no ${SSH_USER}@${i}:logs "${LOGS_DIR}/${run_timestamp}/${i}"
  if [ $? -ne 0 ]; then
    echo "Failed to fetch logs from ${i}"
  fi
  ssh -i ${SSH_KEY} -oStrictHostKeyChecking=no ${SSH_USER}@${i} readlink sql.test > "${LOGS_DIR}/${run_timestamp}/${i}/BINARY"
done

# Destroy all instances.
do_retry "terraform destroy --force" 5 5
if [ $? -ne 0 ]; then
  echo "Terraform destroy failed."
  return 1
fi

# Send email.
if [ -z "${MAILTO}" ]; then
  echo "MAILTO variable not set, not sending email."
  exit 0
fi

cd "${LOGS_DIR}/${run_timestamp}"
attach_args="--content-type=text/plain"
binary=$(cat */BINARY|sort|uniq|xargs)
for i in ${instances}; do
  ln -s ${i}/sql.test.stdout ${i}.stdout
  ln -s ${i}/sql.test.stderr ${i}.stderr
  attach_args="${attach_args} -A ${i}.stdout -A ${i}.stderr"
done

echo "Binary: ${binary}" > summary.txt
echo "" >> summary.txt
echo "${summary}" >> summary.txt
mail ${attach_args} -s "SQL logic test ${status} ${run_timestamp}" ${MAILTO} < summary.txt
