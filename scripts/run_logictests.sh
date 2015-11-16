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

set -ex

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
if [ $? -ne "0" ]; then
  echo "Could not find terraform in your path"
  exit 1
fi

run_timestamp=$(date  +"%Y%m%d-%H%M%S")
cd "${PROD_REPO}/terraform/aws/tests"

# Start the instances and work.
# We loop to retry instances that take too long to setup (it seems to happen).
set +e
while true; do
  terraform apply
  if [ $? -eq "0" ]; then
    break
  fi
  echo "Terraform apply failed. Retrying in 3 seconds."
  sleep 3
done
set -e

# Fetch instances names.
instances=$(terraform output instance|cut -d'=' -f2|tr ',' ' ')

# Wait for jobs to complete.
hasall=0
while [ ${hasall} -eq 0 ];
do
  sleep 60
  hasall=1
  for i in ${instances}; do
    set +e
    ssh -i ${SSH_KEY} -oStrictHostKeyChecking=no ${SSH_USER}@${i} stat logs/DONE \> /dev/null 2\>\&1
    success=$?
    set -e
    if [ ${success} -ne 0 ]; then
       hasall=0
       break
    fi
  done
done

# Fetch all logs.
mkdir -p "${LOGS_DIR}/${run_timestamp}"
for i in ${instances}; do
  set +e
  scp -i ${SSH_KEY} -r -oStrictHostKeyChecking=no ${SSH_USER}@${i}:logs "${LOGS_DIR}/${run_timestamp}/${i}"
  if [ $? -ne 0 ]; then
    echo "Failed to fetch logs from ${i}"
  fi
  set -e
done

# Destroy all instances.
terraform destroy --force

# Send email.
if [ -z "${MAILTO}" ]; then
  echo "MAILTO variable not set, not sending email."
  exit 0
fi

cd "${LOGS_DIR}/${run_timestamp}"
attach_args="--content-type=text/plain"
echo "Status by instance number:" > message.txt
status="PASSED"
inum=0
for i in ${instances}; do
  passed=$(tail -n 1 ${i}/sql.test.STDOUT)
  if [ "${passed}" != "PASS" ]; then
    status="FAILED"
  fi
  spent=$(egrep "^time:" ${i}/DONE | awk '{print $2}')
  binary=$(egrep "^binary:" ${i}/DONE | awk '{print $2}')
  echo "${inum}: ${binary} ${passed} in ${spent} seconds" >> message.txt
  ln -s -f ${i}/sql.test.STDOUT ${inum}.STDOUT
  attach_args="${attach_args} -A ${inum}.STDOUT"
  let 'inum=inum+1'
done
mail ${attach_args} -s "SQL logic test ${status} ${run_timestamp}" ${MAILTO} < message.txt
