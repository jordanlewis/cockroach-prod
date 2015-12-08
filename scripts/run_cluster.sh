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
# 0 0 * * * /home/MYUSER/cockroach/src/github.com/cockroachdb/cockroach-prod/scripts/run_cluster.sh /MYLOGDIR/ > /MYLOGDIR/LATEST 2>&1

set -x

source $(dirname $0)/utils.sh

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

monitor="${PROD_REPO}/tools/supervisor/supervisor"
if [ ! -e "${monitor}" ]; then
  echo "Could not locate supervisor monitor at ${monitor}"
  exit 1
fi

run_timestamp=$(date  +"%Y-%m-%d-%H:%M:%S")
cd "${PROD_REPO}/terraform/aws"

# Initialize infrastructure and first instance.
# We loop to retry instances that take too long to setup (it seems to happen).
do_retry "terraform apply --var=num_instances=${TOTAL_INSTANCES}" 5 5
if [ $? -ne 0 ]; then
  echo "Terraform apply failed."
  return 1
fi

# Fetch instances names.
instances=$(terraform output instances|tr ',' ' ')
supervisor_hosts=$(echo ${instances}|fmt -1|awk '{print $1 ":9001"}'|xargs|tr ' ' ',')

# Start the block_writer.
do_retry "terraform apply --var=num_instances=${TOTAL_INSTANCES} --var=example_block_writer_instances=1" 5 5
if [ $? -ne 0 ]; then
  echo "Terraform apply failed."
  return 1
fi

# Fetch block writer instances.
block_writer_instance=$(terraform output example_block_writer)

# Sleep for a while.
sleep ${WAIT_TIME}

# Stop all processes through supervisor.
# TODO(marc): switch to --signal when supported (supervisor 3.2.0).
summary_block_writer=$(${monitor} --program=block_writer --stop --addrs=${block_writer_instance}:9001)
summary_nodes=$(${monitor} --program=cockroach --stop --addrs=${supervisor_hosts})

# Fetch all logs.
mkdir -p "${LOGS_DIR}/${run_timestamp}"
for i in ${instances}; do
  scp -C -i ${SSH_KEY} -r -oStrictHostKeyChecking=no ${SSH_USER}@${i}:logs "${LOGS_DIR}/${run_timestamp}/node.${i}"
  if [ $? -ne 0 ]; then
    echo "Failed to fetch logs from ${i}"
  fi
  ssh -i ${SSH_KEY} -oStrictHostKeyChecking=no ${SSH_USER}@${i} readlink cockroach > "${LOGS_DIR}/${run_timestamp}/node.${i}/BINARY"
done

scp -C -i ${SSH_KEY} -r -oStrictHostKeyChecking=no ${SSH_USER}@${block_writer_instance}:logs "${LOGS_DIR}/${run_timestamp}/block_writer.${block_writer_instance}"
ssh -i ${SSH_KEY} -oStrictHostKeyChecking=no ${SSH_USER}@${block_writer_instance} readlink block_writer > "${LOGS_DIR}/${run_timestamp}/block_writer.${block_writer_instance}/BINARY"

# Destroy all instances.
do_retry "terraform destroy --force --var=num_instances=${TOTAL_INSTANCES}" 5 5

# Send email.
if [ -z "${MAILTO}" ]; then
  echo "MAILTO variable not set, not sending email."
  exit 0
fi

cd "${LOGS_DIR}/${run_timestamp}"

# Generate message and attach logs for each instance.
attach_args="--content-type=text/plain"
node_binary=$(cat node.*/BINARY|sort|uniq|xargs)
for i in ${instances}; do
  tail -n 10000 node.${i}/cockroach.stderr > node.${i}.stderr
  tail -n 10000 node.${i}/cockroach.stdout > node.${i}.stdout
  attach_args="${attach_args} -A node.${i}.stderr -A node.${i}.stdout"
done

# Attach block writer logs.
block_writer_binary=$(cat block_writer.*/BINARY|sort|uniq|xargs)
tail -n 10000 block_writer.${block_writer_instance}/block_writer.stderr > block_writer.stderr
tail -n 10000 block_writer.${block_writer_instance}/block_writer.stdout > block_writer.stdout
attach_args="${attach_args} -A block_writer.stderr -A block_writer.stdout"

echo "Binary: ${node_binary}" > summary.txt
echo "${summary_nodes}" >> summary.txt
echo "" >> summary.txt
echo "Binary: ${block_writer_binary}" >> summary.txt
echo "${summary_block_writer}" >> summary.txt
mail ${attach_args} -s "Cluster test ${run_timestamp}" ${MAILTO} < summary.txt
