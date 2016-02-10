#!/bin/bash
#
# This script runs the cockroach benchmarks on AWS.
#
# If run as a cron job, make sure you set your basic environment variables.
# Run with:
# run_benchmarks.sh [log dir]
#
# Logs will be saved in [log dir]/date-time/[instance number]/
#
# Requirements for this to work:
# * basic environment variables set: HOME, PATH, GOPATH
# * ~/.aws/credentials with valid AWS credentials
# * terraform installed in your PATH
# * benchstat installed in your PATH
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
# 0 0 * * * /home/MYUSER/cockroach/src/github.com/cockroachdb/cockroach-prod/scripts/run_benchmarks.sh /MYLOGDIR/ > /MYLOGDIR/LATEST 2>&1

set -x

source $(dirname $0)/utils.sh

COCKROACH_BASE="${GOPATH}/src/github.com/cockroachdb"
LOGS_DIR="${1-$(mktemp -d)}"
MAILTO="${MAILTO-}"
KEY_NAME="${KEY_NAME-cockroach-${USER}}"

SSH_KEY="$HOME/.ssh/${KEY_NAME}.pem"
SSH_USER="ubuntu"
BINARY_PATH="cockroach/static-tests.tar.gz"

PROD_REPO="${COCKROACH_BASE}/cockroach-prod"
run_timestamp=$(date  +"%Y-%m-%d-%H:%M:%S")

CODESPEED_SERVER="${CODESPEED_SERVER}"
uploader=$(cd `dirname "${BASH_SOURCE[0]}"` && pwd)/upload_benchmarks.py

which terraform > /dev/null
if [ $? -ne 0 ]; then
  echo "Could not find terraform in your path"
  exit 1
fi

# ensure we have the latest version of our benchstat fork
go get -u github.com/cockroachdb/benchstat

which benchstat > /dev/null
if [ $? -ne 0 ]; then
  echo "Could not find benchstat in your path"
  exit 1
fi

monitor="${PROD_REPO}/tools/supervisor/supervisor"
if [ ! -e "${monitor}" ]; then
  echo "Could not locate supervisor monitor at ${monitor}"
  exit 1
fi

benchmarks_sha=$(latest_sha ${BINARY_PATH})

cd "${COCKROACH_BASE}/cockroach/cloud/aws/benchmarks"

# Start the instances and work.
do_retry "terraform apply --var=key_name=${KEY_NAME} --var=benchmarks_sha=${benchmarks_sha}" 5 5
if [ $? -ne 0 ]; then
  echo "Terraform apply failed."
  return 1
fi

# Fetch instances names.
instances=$(terraform output instance|cut -d'=' -f2|tr ',' ' ')
supervisor_hosts=$(echo ${instances}|fmt -1|awk '{print $1 ":9001"}'|xargs|tr ' ' ',')

status="PASSED"
summary=$(${monitor} --program=benchmarks --addrs=${supervisor_hosts})
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

cd "${LOGS_DIR}"
binary_sha_link ${BINARY_PATH} ${benchmarks_sha} > summary.html
if [ ! -z "${CODESPEED_SERVER}" ]; then
  echo "<BR>" >> summary.html
  echo "Benchmarks dashboard: ${CODESPEED_SERVER}" >> summary.html
fi
echo "<BR>" >> summary.html
echo "${summary}" >> summary.html
echo "<BR>" >> summary.html

for i in ${instances}; do
  pushd ${i}
  for test in $(find cockroach/ -type f -name '*.stdout' | sed 's/.stdout$//' | sort); do
    out=$(benchstat -html "${test}.stdout")
    if [ -z "${out}" ]; then
      continue
    fi
    echo "<br><h2>${test}</h2><br>" >> ../summary.html
    echo "${out}" >> ../summary.html
    echo "<br>" >> ../summary.html

    if [ ! -z "${CODESPEED_SERVER}" ]; then
      benchstat -json "${test}.stdout" | sed 's/.test.stdout//g' > "${test}.json"
      $uploader -e aws -r ${benchmarks_sha} -p cockroach -s ${CODESPEED_SERVER} "${test}.json"
    fi
  done
  popd
done

# Send email.
if [ -z "${MAILTO}" ]; then
  echo "MAILTO variable not set, not sending email."
  exit 0
fi

mail -a "Content-type: text/html" -s "Benchmarks ${status} ${run_timestamp}" ${MAILTO} < summary.html
