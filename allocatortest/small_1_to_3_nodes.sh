#! /bin/bash

# Copyright 2016 The Cockroach Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http:#www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied. See the License for the specific language governing
# permissions and limitations under the License.

# This test starts with a 1-node cluster containing 10G of data. It then adds
# 2 nodes to the cluster and measures how long it takes to replicate all
# ranges to all nodes.

# These control the GCE instance configs and naming of Terraform resources.
# Please prefix these with "${USER}-".
NAME_PREFIX="${USER}-small-1to3"
# Directory in the allocator test GCS bucket that contains the store directories
# for this test.
STORE_GCS_DIR=1node-10g-262ranges
START_CLUSTER_SIZE=1
END_CLUSTER_SIZE=3

# The lines below should be copied-and-pasted to new tests.
source allocatortest-common.sh
allocator_test $*
