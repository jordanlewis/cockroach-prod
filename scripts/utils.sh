do_retry() {
  cmd="$1"
  retry_times=$2
  retry_wait=$3

  c=0
  while [ $c -lt $((retry_times+1)) ]; do
    c=$((c+1))
    $1 && return $?
    if [ ! $c -eq $retry_times ]; then
      sleep $retry_wait
    else
      return 1
    fi
  done
}

# latest_sha takes a [repo]/[binary] and looks up the latest sha in S3.
# eg: latest_sha cockroach/sql.test
BUCKET_NAME="cockroach"
LATEST_SUFFIX=".LATEST"
latest_sha() {
  binary_path="$1"
  if [ -z "${binary_path}" ]; then
    echo "binary not specified, run with: [repo-name]/[binary-name]"
    exit 1
  fi
  latest_url="https://s3.amazonaws.com/${BUCKET_NAME}/${binary_path}${LATEST_SUFFIX}"
  sha=$(curl ${latest_url})
  if [ -z "${sha}" ]; then
    echo "Could not fetch latest binary: ${latest_url}"
    exit 1
  fi
  echo ${sha}
}

# binary_sha_link takes a binary path and a sha and prints
# the html link to the commit log on github.
# eg: binary_sha_link cockroach/sql.test c7c582a6abfbe7ce3c1d23597d928bc8b6f370f6
#  Binary: cockroach/sql.test sha:
#  https://github.com/cockroachdb/cockroach/commits/c7c582a6abfbe7ce3c1d23597d928bc8b6f370f6
binary_sha_link() {
  binary_path="$1"
  sha="$2"
  if [ -z "${binary_path}" ]; then
    echo "binary not specified, run with: [repo-name]/[binary-name] [sha]"
    exit 1
  fi
  if [ -z "${sha}" ]; then
    echo "sha not specified, run with: [repo-name]/[binary-name] [sha]"
    exit 1
  fi
  repo=$(dirname "${binary_path}")
  if [ -z "${repo}" ]; then
    echo "bad repo-name/binary-name, run with: [repo-name]/[binary-name] [sha]"
    exit 1
  fi
  echo "Binary: ${binary_path} sha: https://github.com/cockroachdb/${repo}/commits/${sha}"
}
