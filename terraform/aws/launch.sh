#!/bin/bash
# This is a simple wrapper script around the cockroach binary.
# It must be in the same directory as the cockroach binary, and invoked in one of two ways:
#
# To start the first node and initialize the cluster:
# ./launch init [gossip flag value]
# To start a node:
# ./launch start [gossip flag value]
set -ex

# Lookup name of latest cockroach binary.
BUCKET_PATH="cockroachdb/bin"
LATEST="LATEST"
binary_name=$(curl https://s3.amazonaws.com/${BUCKET_PATH}/${LATEST})
if [ -z "${binary_name}" ]; then
  echo "Could not fetch latest cockroach binary"
fi

# Fetch binary and symlink.
time curl -O https://s3.amazonaws.com/${BUCKET_PATH}/${binary_name}
chmod 755 ${binary_name}
ln -s -f ${binary_name} cockroach

DATA_DIR="data"
LOG_DIR="logs"
STORES="ssd=${DATA_DIR}"
COMMON_FLAGS="--log-dir=${LOG_DIR} --logtostderr=false --stores=${STORES}"
START_FLAGS="--insecure"

action=$1
if [ "${action}" != "init" -a "${action}" != "start" ]; then
  echo "Usage: ${0} [init|start] [gossip flag value]"
  exit 1
fi

gossip=$2
if [ -z "${gossip}" ]; then
  echo "Usage: ${0} [init|start] [gossip flag value]"
  exit 1
fi

mkdir -p ${DATA_DIR} ${LOG_DIR}

if [ "${action}" == "init" ]; then
  ./cockroach init ${COMMON_FLAGS}
fi

cmd="./cockroach start ${COMMON_FLAGS} ${START_FLAGS} --gossip=${gossip}"
nohup ${cmd} > ${LOG_DIR}/cockroach.STDOUT 2> ${LOG_DIR}/cockroach.STDERR < /dev/null &
pid=$!
echo "Launched ${cmd}: pid=${pid}"
# Sleep a bit to let the process start before we terminate the ssh connection.
sleep 5
