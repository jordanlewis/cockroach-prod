#!/bin/bash
#
# This script performs the following:
# - start a cockroach cluster in AWS with TOTAL_INSTANCES instances
# - start an instance running the block_writer example
# - wait WAIT_TIME
# - shut down all AWS jobs
# TODO(marc): grab logs and send summary email.
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
# 0 0 * * * /home/MYUSER/cockroach/src/github.com/cockroachdb/cockroach-prod/scripts/run_cluster.sh /MYLOGDIR/ > /MYLOGDIR/LATEST 2>&1

set -x

COCKROACH_BASE="${GOPATH}/src/github.com/cockroachdb"
PROD_REPO="${COCKROACH_BASE}/cockroach-prod"
LOGS_DIR=$1
SSH_KEY=~/.ssh/cockroach.pem
SSH_USER="ubuntu"
TOTAL_INSTANCES=5
WAIT_TIME=3600

if [ -z "${LOGS_DIR}" ]; then
  echo "No logs directory specified. Run with: $0 [logs dir]"
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

run_timestamp=$(date  +"%Y-%m-%d-%H:%M:%S")
cd "${PROD_REPO}/terraform/aws"

# Initialize infrastructure and first instance.
# We loop to retry instances that take too long to setup (it seems to happen).
while true; do
  terraform apply --var=num_instances=1 --var=action="init"
  if [ $? -eq "0" ]; then
    break
  fi
  echo "Terraform apply failed. Retrying in 3 seconds."
  sleep 3
done

# Add more instances.
while true; do
  terraform apply --var=num_instances=${TOTAL_INSTANCES}
  if [ $? -eq "0" ]; then
    break
  fi
  echo "Terraform apply failed. Retrying in 3 seconds."
  sleep 3
done

# Fetch instances names.
instances=$(terraform output instances|tr ',' ' ')

# Start the block_writer.
while true; do
  terraform apply --var=num_instances=${TOTAL_INSTANCES} --var=example_block_writer_instances=1
  if [ $? -eq "0" ]; then
    break
  fi
  echo "Terraform apply failed. Retrying in 3 seconds."
  sleep 3
done

# Fetch block writer instances.
block_writer_instance=$(terraform output example_block_writer)

# Sleep for a while.
sleep ${WAIT_TIME}

ssh -i ${SSH_KEY} -oStrictHostKeyChecking=no ${SSH_USER}@${block_writer_instance} pkill -2 block_writer
# Stop all processes.
for i in ${instances}; do
  ssh -i ${SSH_KEY} -oStrictHostKeyChecking=no ${SSH_USER}@${i} pkill -2 cockroach
done

# Wait a while for clean shutdown.
sleep 10

ssh -i ${SSH_KEY} -oStrictHostKeyChecking=no ${SSH_USER}@${block_writer_instance} pkill -15 block_writer
# Send second signal to all processes.
for i in ${instances}; do
  ssh -i ${SSH_KEY} -oStrictHostKeyChecking=no ${SSH_USER}@${i} pkill -15 cockroach
done

# Fetch all logs.
mkdir -p "${LOGS_DIR}/${run_timestamp}"
for i in ${instances}; do
  scp -C -i ${SSH_KEY} -r -oStrictHostKeyChecking=no ${SSH_USER}@${i}:logs "${LOGS_DIR}/${run_timestamp}/node.${i}"
  if [ $? -ne 0 ]; then
    echo "Failed to fetch logs from ${i}"
  fi
done

scp -C -i ${SSH_KEY} -r -oStrictHostKeyChecking=no ${SSH_USER}@${block_writer_instance}:logs "${LOGS_DIR}/${run_timestamp}/block_writer.${block_writer_instance}"

# Destroy all instances.
terraform destroy --force --var=num_instances=${TOTAL_INSTANCES}

# Send email.
if [ -z "${MAILTO}" ]; then
  echo "MAILTO variable not set, not sending email."
  exit 0
fi

cd "${LOGS_DIR}/${run_timestamp}"

# Generate message and attached STDERR for each instance.
attach_args="--content-type=text/plain"
echo "Status by instance number:" > message.txt
inum=0
for i in ${instances}; do
  spent=$(egrep "^time:" node.${i}/DONE | awk '{print $2}')
  binary=$(egrep "^binary:" node.${i}/DONE | awk '{print $2}')
  echo "${inum}: ${binary} ran ${spent} seconds" >> message.txt
  ln -s -f node.${i}/cockroach.STDERR ${inum}.STDERR
  attach_args="${attach_args} -A ${inum}.STDERR"
  let 'inum=inum+1'
done

# Attach block writer STDERR.
ln -s block_writer.${block_writer_instance}/example.STDERR block_writer.STDERR
attach_args="${attach_args} -A block_writer.STDERR"

mail ${attach_args} -s "Cluster test ${run_timestamp}" ${MAILTO} < message.txt
