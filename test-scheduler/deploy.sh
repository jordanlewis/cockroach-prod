#!/bin/bash

# This script deploys the build triggering app to GAE.

set -x

which appcfg.py > /dev/null
if [ $? -ne 0 ]; then
  echo "Could not find appfcg.py in your path. Install the google app engine sdk."
  exit 1
fi

if [ -z "${CIRCLE_CI_TOKEN}" ]; then
    echo "You must set CIRCLE_CI_TOKEN to your circle ci token to deploy."
    exit 1
fi

appcfg.py update -V v1 . -E CIRCLE_CI_TOKEN:${CIRCLE_CI_TOKEN}

