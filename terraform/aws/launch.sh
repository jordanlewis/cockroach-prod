#!/bin/bash
# This is a simple wrapper script around the cockroach binary.
# It must be in the same directory as the cockroach binary, and invoked in the following ways:
#
# To initialize the cluster and start the first node:
# ./launch init [gossip flag value]
# To start a node:
# ./launch start [gossip flag value]
# To (ruthlessly) kill a node:
# ./launch kill
# To restart a node (killing it first if it is running):
# ./launch restart
set -e

LOG_DIR="logs"
DATA_DIR="data"
STORES="ssd=${DATA_DIR}"
COMMON_FLAGS="--log-dir=${LOG_DIR} --logtostderr=false --alsologtostderr=true --stores=${STORES}"
START_FLAGS="--insecure"
BINARY="cockroach"
CMD_FILE=".cockroach.last"

action=$1

mkdir -p ${DATA_DIR} ${LOG_DIR}

if [ "${action}" == "init" ]; then
  ./cockroach init ${COMMON_FLAGS} # intentionally unquoted
  action="start"
fi

if [ "${action}" == "start" ]; then
  gossip=$2
  if [ -z "${gossip}" ]; then
    echo "Usage: ${0} [init|start] [gossip flag value]"
    exit 1
  fi

  # Find the target of the symlink. It contains the build sha.
  binary_name=$(readlink ${BINARY} || echo ${BINARY})

  cmd="./${BINARY} start ${COMMON_FLAGS} ${START_FLAGS} --gossip=${gossip}"
  echo "${cmd}" > "${CMD_FILE}"
elif [ "${action}" == "kill" ]; then
  pkill -9 cockroach
  exit 0
elif [ "${action}" == "restart" ]; then
  $0 kill || true
  cmd=$(cat "${CMD_FILE}")
  action="start"
fi

if [ "${action}" != "start" ]; then
  echo "Usage: ${0} [init|start] [gossip flag value]"
  echo "       ${0} [kill|restart]"
  exit 1
fi

# Ignore errors. We want to write the DONE file.
${cmd} > ${LOG_DIR}/cockroach.STDOUT 2> ${LOG_DIR}/cockroach.STDERR || true
# SECONDS is the time since the shell started. This is a good approximation for now.
echo "time: ${SECONDS}" > ${LOG_DIR}/DONE
echo "binary: ${binary_name}" >> ${LOG_DIR}/DONE
