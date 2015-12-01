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
