#!/bin/bash
# This is a simple wrapper script around the cockroach binary.
# It must be in the same directory as the cockroach binary, and invoked in one of two ways:
#
# To start the first node and initialize the cluster:
# ./launch init [gossip flag value]
# To start a node:
# ./launch start [gossip flag value]
set -ex

LOG_DIR="logs"
DATA_DIR="data"
STORES="ssd=${DATA_DIR}"
COMMON_FLAGS="--log-dir=${LOG_DIR} --logtostderr=false --alsologtostderr=true --stores=${STORES}"
START_FLAGS="--insecure"
BINARY="cockroach"

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

# Find the target of the symlink. It contains the build sha.
binary_name=$(readlink ${BINARY} || echo ${BINARY})

# Ignore errors. We want to write the DONE file.
./${BINARY} start ${COMMON_FLAGS} ${START_FLAGS} --gossip=${gossip} > \
  ${LOG_DIR}/cockroach.STDOUT 2> ${LOG_DIR}/cockroach.STDERR || true

# SECONDS is the time since the shell started. This is a good approximation for now.
echo "time: ${SECONDS}" > ${LOG_DIR}/DONE
echo "binary: ${binary_name}" >> ${LOG_DIR}/DONE
