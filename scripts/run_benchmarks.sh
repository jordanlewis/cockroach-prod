#!/bin/bash
#
# This script runs the cockroach benchmarks on GCE.
#
# If run as a cron job, make sure you set your basic environment variables.
# Run with:
# run_benchmarks.sh [log dir]
#
# Logs will be saved in [log dir]/date-time/[instance number]/
#
# Requirements for this to work:
# * basic environment variables set: HOME, PATH, GOPATH
# * GCE credentials as described in cockroach/cloud/gce/README.md
# * terraform installed in your PATH
# * benchstat installed in your PATH
# * <COCKROACH_BASE>/cockroach-prod repo cloned and up to date
# * <COCKROACH_BASE>/cockroach-prod/tools/supervisor/supervisor tool compiled to ${GOPATH}/bin/
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
LOGS_DIR="${1-CIRCLE_ARTIFACTS}"
MAILTO="${MAILTO-}"
KEY_NAME="${KEY_NAME-google_compute_engine}"

SSH_KEY="${HOME}/.ssh/${KEY_NAME}"
SSH_USER="ubuntu"
# Build type can be empty for default, or ".stdmalloc" for default allocator builds.
BUILD_TYPE="${BUILD_TYPE-}"
PACKAGE_TYPE="static-tests${BUILD_TYPE}"
BINARY_PATH="cockroach/${PACKAGE_TYPE}.tar.gz"

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

monitor="${GOPATH}/bin/supervisor"
if [ ! -e "${monitor}" ]; then
  echo "Could not locate supervisor monitor at ${monitor}"
  exit 1
fi

benchmarks_sha=$(latest_sha ${BINARY_PATH})

cd "${COCKROACH_BASE}/cockroach/cloud/gce/benchmarks"

# Start the instances and work.
do_retry "terraform apply --state=terraform${BUILD_TYPE}.tfstate --var=key_name=${KEY_NAME} --var=benchmarks_package=${PACKAGE_TYPE} --var=benchmarks_sha=${benchmarks_sha}" 5 5
if [ $? -ne 0 ]; then
  echo "Terraform apply failed."
  exit 1
fi

# Fetch instances names.
instances=$(terraform output --state=terraform${BUILD_TYPE}.tfstate instance|cut -d'=' -f2|tr ',' ' ')
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
do_retry "terraform destroy --state=terraform${BUILD_TYPE}.tfstate --var=key_name=${KEY_NAME} --force" 5 5
if [ $? -ne 0 ]; then
  echo "Terraform destroy failed."
  exit 1
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
      $uploader -e "gce${BUILD_TYPE}" -r ${benchmarks_sha} -p cockroach -s ${CODESPEED_SERVER} "${test}.json"
    fi
  done
  popd
done

# Send email.
if [ -z "${MAILTO}" ]; then
  echo "MAILTO variable not set, not sending email."
else
  mail -a "Content-type: text/html" -s "Benchmarks${BUILD_TYPE} ${status} ${run_timestamp}" ${MAILTO} < summary.html
fi

if [ ${status} -ne "PASSED" ]; then
    # If we didn't pass, make sure to return a non-zero exit code
    exit 1
fi
