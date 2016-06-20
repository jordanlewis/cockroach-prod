#!/usr/bin/env bash

set -eux

cd "$(dirname "$0")"

cat <<'EOF' | parallel -j0 --linebuffer --verbose
./run_clustertest.sh
./run_logictests.sh
EOF
