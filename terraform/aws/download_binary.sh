#!/bin/bash
# This script takes the name of a binary and downloads it from S3.
# This is meant to be copied over to the instance first, then invoked
# in a "remote-exec" provisioner.
#
# eg:
# myexample.tf <<<
# ...
# provisioner "file" {
#   source = "download_binary.sh"
#   destination = "/home/ubuntu/download_binary.sh"
# }
# provisioner "remote-exec" {
#   inline = [
#     "bash download_binary.sh block_writer",
#     "nohup ./block_writer --db-url=localhost:26259 > example.STDOUT 2>&1 &",
#     "sleep 5",
#   ]
# }
# ...
# <<<
set -ex

# Lookup name of latest binary.
BUCKET_PATH="cockroach/bin"
LATEST_SUFFIX=".LATEST"

binary_name=$1
if [ -z "${binary_name}" ]; then
  echo "binary not specified, run with: $0 [binary-name]"
  exit 1
fi

latest_url="https://s3.amazonaws.com/${BUCKET_PATH}/${binary_name}${LATEST_SUFFIX}"
latest_name=$(curl ${latest_url})
if [ -z "${latest_name}" ]; then
  echo "Could not fetch latest binary: ${latest_url}"
  exit 1
fi

# Fetch binary and symlink.
binary_url="https://s3.amazonaws.com/${BUCKET_PATH}/${latest_name}"
time curl -O ${binary_url}
chmod 755 ${latest_name}
ln -s -f ${latest_name} ${binary_name}

echo "Successfully fetched ${latest_name}"
