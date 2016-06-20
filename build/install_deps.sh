#!/usr/bin/env bash
set -eux

# install the test supervisor, used for the terraform tests.
pushd tools/supervisor/
go get github.com/kolo/xmlrpc
GOBIN=~/bin go install
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

cd
rm -rf         "${GOPATH%%:*}/src/github.com/cockroachdb/cockroach"
mkdir -p       "${GOPATH%%:*}/src/github.com/cockroachdb/"
git clone --depth 1 -q "http://github.com/cockroachdb/cockroach" "${GOPATH%%:*}/src/github.com/cockroachdb/cockroach"
ln -s          "${GOPATH%%:*}/src/github.com/cockroachdb/cockroach" ~/cockroach

cd cockroach
go get github.com/robfig/glock
glock sync -n < GLOCKFILE

# make a keypair for gce
ssh-keygen -f ~/.ssh/google_compute_engine -N ""
