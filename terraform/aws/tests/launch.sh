#!/bin/bash
# This is a simple wrapper script to download and run sql.test.
set -ex

# Lookup name of latest cockroach binary.
BUCKET_PATH="cockroachdb/bin"
LATEST_SUFFIX=".LATEST"
LOG_DIR="logs"
BINARY="sql.test"

binary_name=$(curl https://s3.amazonaws.com/${BUCKET_PATH}/${BINARY}${LATEST_SUFFIX})
if [ -z "${binary_name}" ]; then
  echo "Could not fetch latest binary"
fi

# Fetch binary and symlink.
time curl -O https://s3.amazonaws.com/${BUCKET_PATH}/${binary_name}
chmod 755 ${binary_name}
ln -s -f ${binary_name} ${BINARY}

mkdir -p ${LOG_DIR}

# We ignore errors from here on. Failing tests are fine, and we still want
# to create the DONE file.
set +e

time ./${BINARY} --test.run=TestLogic -d "test/index/*/*/*.test" > \
  ${LOG_DIR}/${BINARY}.STDOUT 2> ${LOG_DIR}/${BINARY}.STDERR < /dev/null

# SECONDS is the time since the shell started. This is a good approximation for now,
# more details are in the output.
echo "time: ${SECONDS}" > ${LOG_DIR}/DONE
echo "binary: ${binary_name}" >> ${LOG_DIR}/DONE
