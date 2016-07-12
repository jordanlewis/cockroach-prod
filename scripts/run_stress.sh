#!/bin/bash
#
# This script runs the cockroach stress tests on GCE.
#
# If run as a cron job, make sure you set your basic environment variables.
# Run with:
# run_stress.sh [log dir]
#
# Logs will be saved in [log dir]/date-time/[instance number]/
#
# Requirements for this to work:
# * basic environment variables set: HOME, PATH, GOPATH
# * GCE credentials as described in cockroach/cloud/gce/README.md
# * terraform installed in your PATH
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
# GITHUB_API_TOKEN=your_token_here
#
# 0 0 * * * /home/MYUSER/cockroach/src/github.com/cockroachdb/cockroach-prod/scripts/run_stress.sh /MYLOGDIR/ > /MYLOGDIR/LATEST 2>&1

set -x

source $(dirname $0)/utils.sh

COCKROACH_BASE="${GOPATH%%:*}/src/github.com/cockroachdb"
LOGS_DIR="${CIRCLE_ARTIFACTS}/stress"
MAILTO="${MAILTO-}"
KEY_NAME="${KEY_NAME-google_compute_engine}"

SSH_KEY="${HOME}/.ssh/${KEY_NAME}"
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

monitor="${GOPATH%%:*}/bin/supervisor"
if [ ! -e "${monitor}" ]; then
  echo "Could not locate supervisor monitor at ${monitor}"
  exit 1
fi

tests_sha=$(latest_sha ${TESTS_PATH})
stress_sha=$(latest_sha ${STRESS_BINARY_PATH})

cd "${COCKROACH_BASE}/cockroach/cloud/gce/stress"

START=$(date +%s)
# Assume the test failed.
status="0"

# Start the instances and work.
# N.B. Do not separate the following two lines! You will break the test.
do_retry "terraform apply --var=key_name=${KEY_NAME} --var=tests_sha=${tests_sha} --var=stress_sha=${stress_sha}" 5 5
if [ $? -eq 0 ]; then
  # Fetch instances names.
  instances=$(terraform output instance|cut -d'=' -f2|tr ',' ' ')
  supervisor_hosts=$(echo ${instances}|fmt -1|awk '{print $1 ":9001"}'|xargs|tr ' ' ',')

  summary=$(${monitor} --program=stress --addrs=${supervisor_hosts})
  if [ $? -eq 0 ]; then
    # Success!
    status="1"
  fi
else
  echo "Terraform apply failed."
fi
END=$(date +%s)
duration=$((END - START))

mkdir -p ${CIRCLE_TEST_REPORTS}/stress
$(create_junit_single_output "github.com/cockroachdb/cockroach-prod/scripts/run_stress" "stresstests" $duration $status "${CIRCLE_TEST_REPORTS}/stress/stresstests.xml")

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

function json_escape(){
  echo -n "$1" | python -c 'import json,sys; print json.dumps(sys.stdin.read()).strip("\"")'
}

function post() {
  echo "${1}" > post.json
  curl -X POST -H "Authorization: token ${GITHUB_API_TOKEN}" "https://api.github.com/repos/cockroachDB/cockroach/issues" -d @post.json
}

if [ -z "${GITHUB_API_TOKEN}" ]; then
  echo "GITHUB_API_TOKEN variable not set, not posting issues."
fi

cd "${LOGS_DIR}"
binary_sha=$(binary_sha_link ${TESTS_PATH} ${tests_sha} | tee summary.txt)
echo "${summary}" >> summary.txt
echo "" >> summary.txt
echo "" >> summary_success.txt
echo "Packages:" >> summary.txt
attach_args="--content-type=text/plain"
for i in ${instances}; do
  pushd ${i}
  for test in $(find cockroach -type f -name '*.stdout' | sed 's/.stdout$//' | sort); do
    result=$(tail -n 1 "${test}.stdout")
    if [ "${result}" != "SUCCESS" ]; then
      email_status="FAILED"
      result="FAILED"
      flat_name=$(echo ${test} | tr '/' '_')
      stdoutresponse="no ${test}.stdout file generated"
      if [ -s "${test}.stdout" ]; then
        tail -n 10000 "${test}.stdout" > ../${flat_name}.stdout
        attach_args="${attach_args} -A ${flat_name}.stdout"
        stdoutresponse=$(<${test}.stdout)
      fi
      if [ -s "${test}.stderr" ]; then
        tail -n 10000 "${test}.stderr" > ../${flat_name}.stderr
        attach_args="${attach_args} -A ${flat_name}.stderr"
      fi
      # Post Github issues.
      if [ ! -z "${GITHUB_API_TOKEN}" ]; then
        # Normal failed tests.
        failed_tests=$(grep -oh '^--- FAIL: \w*' ${test}.stderr | sed -e 's/--- FAIL: //' | tr '\n' ' ' || true)
        IFS=', ' read -r -a failed_tests_array <<< "$failed_tests"
        for failed_test in "${failed_tests_array[@]}"
        do
          status=0
          content=$(awk "/^=== RUN/ {flag=0};/^=== RUN   ${failed_test}$/ {flag=1} flag" ${test}.stderr)
          content_escaped=$(json_escape "${content}")
          title="stress: failed test in ${test}: ${failed_test}"
          details=$(json_escape "${stdoutresponse}")
          body="${binary_sha}\n\nStress build found a failed test:\n\n\`\`\`\n${content_escaped}\n\`\`\`\n\nRun Details:\n\n\`\`\`\n${details}\n\`\`\`\nPlease assign, take a look and update the issue accordingly."
          json="{ \"title\": \"${title}\", \"body\": \"${body}\", \"labels\": [\"test-failure\", \"Robot\"], \"milestone\": 1 }"
          post "${json}"
        done
        # Panics or test timeouts.
        panic=$(grep -oh '^ERROR: exit status 2' ${test}.stderr)
        if [ ! -z "${panic}" ]; then
          status=0
          failed_test=$(grep -ohn '^=== RUN   \w*$' ${test}.stderr | awk END{print})
          failed_test_first_line=$(echo ${failed_test} | awk '{print $1}' FS=":")
          failed_test_name=$(echo ${failed_test} | grep -oh '\w*$')
          content=$(awk "NR>=${failed_test_first_line}" ${test}.stderr)
          content_escaped=$(json_escape "${content}")
          title="stress: failed test in ${test}: ${failed_test_name}"
          details=$(json_escape "${stdoutresponse}")
          body="${binary_sha}\n\nStress build found a failed test:\n\n\`\`\`\n${content_escaped}\n\`\`\`\n\nRun Details:\n\n\`\`\`\n${details}\n\`\`\`\nPlease assign, take a look and update the issue accordingly."
          json="{ \"title\": \"${title}\", \"body\": \"${body}\", \"labels\": [\"test-failure\", \"Robot\"], \"milestone\": 1 }"
          post "${json}"
        fi
      fi
      echo "${test}: ${result}" >> ../summary.txt
    else
      echo "${test}: ${result}" >> ../summary_success.txt
    fi
  done
  popd
done

# Send email.
if [ -z "${MAILTO}" ]; then
  echo "MAILTO variable not set, not sending email."
else
  cat summary.txt summary_success.txt | mail ${attach_args} -s "Stress tests ${email_status} ${run_timestamp}" ${MAILTO}
fi

if [ $status -eq 0 ]; then
    # The test failed. Exit with a non-zero return code so the caller knows we
    # failed.
    exit 1
fi
