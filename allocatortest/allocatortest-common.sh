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

set -eu

die() {
    echo $* >&2
    exit 1
}

source "$(dirname $0)/../scripts/utils.sh"

readonly GCS_URL="gs://cockroach-test/allocatortest"
readonly GCS_TEMP_URL="gs://cockroach-test/allocatortest/temp"
readonly GCLOUD_SSH_KEY="${HOME}/.ssh/google_compute_engine"
readonly DSH_ARGS="-r ssh -Mc -o -q -o -oStrictHostKeyChecking=no -o -i${HOME}/.ssh/google_compute_engine"
readonly SCP_FLAGS="-q -oStrictHostKeyChecking=no -i${HOME}/.ssh/google_compute_engine"
readonly SSH_FLAGS="${SCP_FLAGS}"
readonly OUTVAR_COCKROACH_IPS="cockroach_ips"
readonly OUTVAR_BLOCK_WRITER_IPS="block_writer_ips"

verify_environment() {
    which terraform >/dev/null 2>&1 || die "Couldn't find terraform"
    which gcloud >/dev/null 2>&1 || die "Couldn't find gcloud. Is the Google Cloud SDK installed?"
    which gsutil >/dev/null 2>&1 || die "Couldn't find gcloud. Is the Google Cloud SDK installed?"
    which dsh >/dev/null 2>&1 || die "Couldn't find dsh"
    which wait_rebalance >/dev/null 2>&1 || die "Couldn't find wait_rebalance. 'go install' it."
    if [ ! -f ${GCLOUD_SSH_KEY} ]; then
        die "Couldn't find Google Cloud SSH key in ${GCLOUD_SSH_KEY}"
    fi
    [ ! -z ${GOOGLE_CREDENTIALS+x} ] ||
        die 'GOOGLE_CREDENTIALS must be set to the contents of your GCE JSON credentials file.'
    [ ! -z ${GOOGLE_PROJECT+x} ] ||
        die 'GOOGLE_PROJECT must be set to the name of your GCE project.'
}


# print_tf_args prints the Terraform arguments for the given Terraform command to
# stdout.
print_tf_args() {
    local cmd="$1"
    local state_path=""
    state_file="${NAME_PREFIX}.tfstate"

    case $cmd in
    apply)
        echo "-var=name_prefix=${NAME_PREFIX} -state=${state_file}"
        ;;
    output)
        echo "-state=${state_file}"
        ;;
    destroy)
        echo "--force -state=${state_file}"
        ;;
    default)
        die "Unknown Terraform command '$cmd'"
        ;;
    esac
}

# print_dsh_hosts outputs a comma-separated list of user@host values for the
# given Terraform output value.
print_dsh_hosts() {
    output_field="$1"

    local tf_args=$(print_tf_args output)
    local ips=$(cd terraform && terraform output ${tf_args} ${output_field} | tr ',' ' ')
    local dsh_hosts=""
    for ip in $ips; do
        if [ -z "${dsh_hosts}" ]; then
            dsh_hosts="ubuntu@${ip}"
        else
            dsh_hosts="${dsh_hosts},ubuntu@${ip}"
        fi
    done
    if [[ -z $dsh_hosts ]]; then
        die "No hosts found for output field ${output_field}"
    fi
    echo "${dsh_hosts}"
}

# ip_for_node prints the IP address for the given node ID.
print_ip_for_node() {
    local tf_args=$(print_tf_args output)
    echo $(cd terraform && terraform output ${tf_args} ${OUTVAR_COCKROACH_IPS} | tr ',' ' ' | awk "{print \$$1}")
}

tf_apply() {
    local num_nodes="$1"
    echo "* Creating / resizing cluster to ${num_nodes} nodes"
    local tf_args=$(print_tf_args apply)
    (set -x; cd terraform && terraform apply ${tf_args} -var=num_instances=${num_nodes}) || \
        die "failed to apply Terraform config"
}

tf_output() {
    local tf_args=$(print_tf_args output)
    (cd terraform && terraform output ${tf_args}) || die 'failed to destroy'
}

tf_destroy() {
    echo "* Destroying cluster"
    local tf_args=$(print_tf_args destroy)
    (set -x; cd terraform && terraform destroy ${tf_args}) || die 'failed to destroy'
}

verify_up() {
    echo "* Verifying CockroachDB is up"
    local dsh_hosts=$(print_dsh_hosts ${OUTVAR_COCKROACH_IPS})
    # TODO(cuongdo): add a timeout
    dsh ${DSH_ARGS} -m ${dsh_hosts} -- "./cockroach sql -e 'SELECT 1' >/dev/null || (echo 'CockroachDB is DOWN'; /bin/false)"
}

verify_down() {
    echo "* Verifying CockroachDB is down"
    local dsh_hosts=$(print_dsh_hosts ${OUTVAR_COCKROACH_IPS})
    dsh ${DSH_ARGS} -m ${dsh_hosts} -- "pidof cockroach >/dev/null && (echo 'CockroachDB is still running but is not supposed to be!'; /bin/false) || /bin/true"
}

start_cockroach() {
    echo "* Starting CockroachDB"
    local dsh_hosts=$(print_dsh_hosts ${OUTVAR_COCKROACH_IPS})
    (set -x; dsh ${DSH_ARGS} -m ${dsh_hosts} -- "supervisorctl -c supervisor.conf start cockroach")
}

stop_cockroach() {
    echo "* Stopping CockroachDB"
    local dsh_hosts=$(print_dsh_hosts ${OUTVAR_COCKROACH_IPS})
    (set +e -x; dsh ${DSH_ARGS} -m ${dsh_hosts} -- "supervisorctl -c supervisor.conf stop cockroach")
}

download_stores() {
    echo "* Downloading stores on every node"
    verify_down
    local dsh_hosts=$(print_dsh_hosts ${OUTVAR_COCKROACH_IPS})
    (set -x; dsh ${DSH_ARGS} -m ${dsh_hosts} -- "./nodectl download ${GCS_URL}/${STORE_GCS_DIR}")
}

admin() {
    local tf_args=$(print_tf_args output)
    local url=$(cd terraform && terraform output ${tf_args} admin_urls | tr ',' ' ' | awk '{print $1}')
    open ${url}
}

run_wait_rebalance() {
    echo "* Waiting for rebalance"
    local ip=$(print_ip_for_node 1)
    wait_rebalance ${ip}
}

start_block_writer() {
    local dsh_hosts=$(print_dsh_hosts ${OUTVAR_BLOCK_WRITER_IPS})
    (set -x; dsh ${DSH_ARGS} -m ${dsh_hosts} -- "supervisorctl -c supervisor.conf start block_writer")
}

stop_block_writer() {
    local dsh_hosts=$(print_dsh_hosts ${OUTVAR_BLOCK_WRITER_IPS})
    (set -x; dsh ${DSH_ARGS} -m ${dsh_hosts} -- "supervisorctl -c supervisor.conf stop block_writer")
}

push_cockroach() {
    if [ $# -ne 1 ]; then
        die 'path to cockroach binary must be specified'
    fi
    local src="$1"
    local date=$(date +%Y%m%d-%H%M%S)
    local user=${USER}
    local basename="cockroach-${user}-${date}"
    local temp_url="${GCS_TEMP_URL}/${basename}"

    # Copy the binary to GCS, then have all nodes download the binary in parallel.
    echo "* Copying binary to temp file"
    gsutil cp -Z "${src}" "${temp_url}"
    local dsh_hosts=$(print_dsh_hosts $OUTVAR_COCKROACH_IPS)
    echo "* Downloading temp file on all nodes"
    dsh ${DSH_ARGS} -m ${dsh_hosts} -- "gsutil cp ${temp_url} . && ln -vsf ${basename} cockroach && chmod +x cockroach"
}

ssh_node() {
    if [[ $# -ne 1 ]]; then
        die "ssh_node takes the CockroachDB node ID as its only argument"
    fi
    node_num="$1"
    local ip=$(print_ip_for_node ${node_num})
    if [[ -z $ip ]]; then
        die "Couldn't find IP address for node ${node_num}"
    fi
    ssh ${SSH_FLAGS} ubuntu@${ip}
}

copy_logs() {
    echo "* Copying CockroachDB logs"
    local tf_args=$(print_tf_args output)
    local ips=$(cd terraform && terraform output ${tf_args} ${OUTVAR_COCKROACH_IPS} | tr ',' ' ')
    local logs_dir="logs-$(date +%Y%m%d-%H%M%S)"
    echo "* Copying logs to ./${logs_dir}"
    mkdir "${logs_dir}"
    local node_id=0
    for ip in $ips; do
        echo "* Copying logs from ${ip} (node ${node_id})"
        node_id=$((node_id+1))
        (set -x; scp ${SCP_FLAGS} -Cpr ubuntu@${ip}:logs "${logs_dir}/${node_id}")
    done
}

# run_allocator_test runs a replica allocator test that sets up a test cluster,
# downloads archived store(s) to the cluster, resizes the cluster to the
# specified target, and waits for the cluster to be rebalanced.
allocator_test() {
    verify_environment

    if [ $# -eq 0 ]; then
        action="run"
    else
        action=$1
    fi

    [ ! -z ${NAME_PREFIX+x} ] || die '$NAME_PREFIX must be set'

    case $action in
    run)
        [ ! -z ${STORE_GCS_DIR+x} ] || die '$STORE_GCS_DIR must be set'
        [ ! -z ${START_CLUSTER_SIZE+x} ] || die '$START_CLUSTER_SIZE must be set'
        [ ! -z ${END_CLUSTER_SIZE+x} ] || die '$END_CLUSTER_SIZE must be set'
        [ $START_CLUSTER_SIZE -lt $END_CLUSTER_SIZE ] ||
            die '$END_CLUSTER_SIZE must be greater than $START_CLUSTER_SIZE'

        # Create the cluster, restore archived stores, resize cluster, and wait
        # for rebalance to finish.
        tf_apply ${START_CLUSTER_SIZE}
        verify_up
        stop_cockroach
        download_stores
        start_cockroach
        verify_up
        # Grow the cluster.
        tf_apply ${END_CLUSTER_SIZE}
        # Wait for new nodes to start up; otherwise, wait_rebalance will exit
        # right away.
        echo "* Waiting for new nodes to join cluster"
        sleep 30
        # TODO(cuongdo): make this more sophisticated
        verify_up
        run_wait_rebalance
        tf_destroy
        ;;
    admin)
        admin
        ;;
    copy_logs)
        copy_logs
        ;;
    create)
        tf_apply ${START_CLUSTER_SIZE}
        ;;
    destroy)
        tf_destroy
        ;;
    download_stores)
        download_stores
        ;;
    grow)
        tf_apply ${END_CLUSTER_SIZE}
        ;;
    push_cockroach)
        # Pushes a custom CockroachDB binary and restarts CockroachDB.
        stop_cockroach
        verify_down
        shift
        push_cockroach $@
        start_cockroach
        ;;
    ssh_node)
        ssh_node "${@:2}"
        ;;
    start_block_writer)
        start_block_writer
        ;;
    start_cockroach)
        start_cockroach
        ;;
    stop_cockroach)
        stop_cockroach
        ;;
    stop_block_writer)
        stop_block_writer
        ;;
    verify_down)
        verify_down
        ;;
    verify_up)
        verify_up
        ;;
    wait_rebalance)
        run_wait_rebalance
        ;;
    *)
        echo "Unknown command. Consult the source for valid commands."
        ;;
    esac
}
