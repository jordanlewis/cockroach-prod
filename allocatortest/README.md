# Replica Allocator Tests

This directory contains tests for various scenarios that exercise the replica allocator.

## One-time setup

1. Make sure you have a [Google Cloud Platform](https://cloud.google.com/compute/) account.
2. [Download terraform](https://terraform.io/downloads.html), *version 0.6.7 or greater*, unzip, and add to your `PATH`.
3. Install `dsh`.
4. [Create and download GCE credentials](https://developers.google.com/identity/protocols/application-default-credentials#howtheywork).
5. In your shell startup files, set your GCE credentials in environment variables as follows:
```
$ export GOOGLE_CREDENTIALS=$(cat /path/to/your/json/credentials/file)
$ export GOOGLE_PROJECT="cockroach-shared"
```
6. Save your GCE key as `~/.ssh/google_compute_engine`.
7. Install `wait_rebalance`: `go install -v github.com/cockroachdb/cockroach-prod/tools/wait_rebalance`
8. Run `make clusterctl` in your top-level `cockroach` directory.

## Running tests

Run any of the `small_*.sh` test files in `cloud/gce/allocatortest`.

## Structure of tests

Each test looks like this:

```
NAME_PREFIX="small-3to5"
# Directory in the allocator test GCS bucket that contains the store directories
# for this test.
STORE_GCS_DIR=3nodes-10g-262ranges
START_CLUSTER_SIZE=3
END_CLUSTER_SIZE=5

# The lines below should be copied-and-pasted to new tests.
source allocatortest-common.sh
allocator_test $*
```

`NAME_PREFIX` is particularly important, because it defines the prefix that's prepended to all Terraform-managed resources. In this case, the test will initially create 3 nodes named:

* **small-3to5**-cockroach-1
* **small-3to5**-cockroach-2
* **small-3to5**-cockroach-3

It'll then download the archived store `3nodes-10g-262ranges` from Google Cloud Storage (GCS) on to all three nodes and restart them. Then, the test will grow the cluster to `END_CLUSTER_SIZE` (5) by adding the following nodes:

* **small-3to5**-cockroach-4
* **small-3to5**-cockroach-5

Finally, the test waits for the replica allocator to be idle for a sustained period (currently, 3 minutes) and reports various stats:

```
I160610 21:36:09.681493 tools/wait_rebalance/main.go:62  cluster took 19m26.960045s to rebalance
I160610 21:36:09.801048 tools/wait_rebalance/main.go:73  783 range events
I160610 21:36:09.915207 tools/wait_rebalance/main.go:94  stddev(replica count) = 0.94
```

Note that this format isn't machine friendly and will need to be changed to fit into whatever systems test framework we use.

## Manual Intervention

It takes quite a bit of work to test replica allocator changes, so every test allows you to manually perform operations.

When run without any parameters, each test will execute from beginning to end. However, to take full control over the test cluster, you can pass the following arguments to the test:

* `admin`: opens admin UI in a browser
* `copy_logs`: copies CockroachDB logs to local disk
* `create`: creates the cluster with the initial size
* `destroy`: destroy the test cluster
* `download_stores`: replaces stores on CockroachDB nodes with stores downloaded from Google Cloud Storage
* `grow`: grow the test cluster to the specified final size
* `push_cockroach`: pushes the given `cockroach` binary to the cluster and restarts CockroachDB
* `ssh_node`: SSH into node with the given node ID (e.g. "ssh_node 1")
* `start_cockroach`, `stop_cockroach`, `start_block_writer`, `stop_block_writer`: performs these operations on all relevant GCE instances
* `verify_up`, `verify_down`: verify status of CockroachDB nodes
* `wait_rebalance`: wait until the rebalancer has been inactive for 3 minutes (configurable)

## Examples

### Run a test

```
./small_1_to_3_nodes.sh
```

### Test a specific CockroachDB SHA

This uses Terraform's [environment variable overrides](https://www.terraform.io/docs/configuration/variables.html#environment-variables) to specify the SHA to download from our S3 bucket:

```
TF_VAR_cockroach_sha=7c33d4f1c43e017e4d5b59fb33d31ac11aed7da7 ./small_1_to_3_nodes.sh
```

### View admin UI for a running test

```
./small_1_to_3_nodes.sh admin
```

### Use a custom Cockroach binary

```
TF_VAR_cockroach_binary=/path/to/cockroach ./small_1_to_3_nodes.sh
```

### Run CockroachDB with custom flags

```
TF_VAR_cockroach_flags="--verbosity 1" ./small_1_to_3_nodes.sh
```

### SSH into a CockroachDB node

```
$ ./small_1_to_3_nodes.sh output | grep cockroach_instances
cockroach_instances = small-1to3-cockroach-1,small-1to3-cockroach-2,small-1to3-cockroach-3
$ gcloud compute ssh ubuntu@small-1to3-cockroach-1
```

### Destroy a test cluster

If a test aborted abnormally, you can destroy the test cluster:

```
./small_1_to_3_nodes.sh destroy
```

### Push your own cockroach binary to the cluster

```
./small_1_to_3_nodes.sh push_cockroach /path/to/cockroach/binary
```
