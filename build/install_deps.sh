#!/usr/bin/env bash
set -eux

# install the test supervisor, used for the terraform tests.
pushd tools/supervisor/
go get github.com/kolo/xmlrpc
go install
popd

go get github.com/tebeka/go2xunit

# if you update the version of terraform here, you should update the
# cache_directories entry to match in circle.yml.
TERRAFORM_VERSION="terraform_0.6.16_linux_amd64"
if [[ ! -e ${TERRAFORM_VERSION} ]]; then
    wget -q "https://releases.hashicorp.com/terraform/0.6.16/${TERRAFORM_VERSION}.zip"
    unzip -q -d "${TERRAFORM_VERSION}" "${TERRAFORM_VERSION}.zip"
fi
ln -sf "$(pwd -P)/${TERRAFORM_VERSION}/terraform" ~/bin/terraform

COCKROACH_PATH="${GOPATH%%:*}/src/github.com/cockroachdb/cockroach"
if [ ! -e "${COCKROACH_PATH}" ]; then
    git clone --depth 1 -q "https://github.com/cockroachdb/cockroach" "${COCKROACH_PATH}"
else
    cd "${COCKROACH_PATH}"
    git fetch && git reset --hard origin/master
fi

cd
ln -s "${GOPATH%%:*}/src/github.com/cockroachdb/cockroach" ~/cockroach

cd cockroach
go get github.com/robfig/glock
glock sync -n < GLOCKFILE

SQLLOGICTEST_PATH="${GOPATH%%:*}/src/github.com/cockroachdb/sqllogictest"
if [ ! -e ${SQLLOGICTEST_PATH} ]; then
    git clone --depth 1 -q "https://github.com/cockroachdb/sqllogictest" ${SQLLOGICTEST_PATH}
else
    cd ${SQLLOGICTEST_PATH}
    git fetch && git reset --hard origin/master
fi

# make a keypair for gce
ssh-keygen -f ~/.ssh/google_compute_engine -N ""
