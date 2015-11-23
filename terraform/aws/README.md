# Deploy cockroach cluster on AWS using Terraform

This directory contains the [Terraform](https://terraform.io/) configuration
files needed to launch a cockroach cluster on AWS.

The following steps will create a three node cluster.

## One-time setup steps
1. Have an [AWS](http://aws.amazon.com/) account
2. [Download terraform](https://terraform.io/downloads.html), *version 0.6.6 or greater*, unzip, and add to your `PATH`.
3. [Valid AWS credentials file](http://docs.aws.amazon.com/cli/latest/userguide/cli-chap-getting-set-up.html#cli-signup).
4. [Create an AWS keypair](https://console.aws.amazon.com/ec2/v2/home?region=us-east-1#KeyPairs:sort=keyName) named `cockroach` and save the file as `~/.ssh/cockroach.pem`.

## Variables

The following variables can be modified in `variables.tf` if necessary.
* `cockroach_port`: the port for the backends and load balancer
* `aws_region`: region to run in. Affects `aws_availability_zone` and `aws_ami_id`
* `aws_availability_zone`: availability zone for instances and load balancer
* `aws_ami_id`: image ID. depends on the region.
* `key_name`: base name of the AWS key
* `action`: default action. Defaults to `start`. Override is specified in initialization step

## Create the cluster

The following two commands will initialize all needed AWS infrastructure in the region `us-east-1`,
initialize the first cockroach node, then add two more nodes to the cluster.
All dynamic configuration is set through terraform command-line flags but can be set in `variables.tf`.

To see the actions expected to be performed by terraform, use `plan` instead of `apply`.

#### Initialize AWS infrastructure and first node

```
$ terraform apply --var=num_instances=1 --var=action="init"

Outputs:
  elb_address          = elb-1371418843.us-east-1.elb.amazonaws.com:26257
  example_block_writer =
  instances            = ec2-54-152-252-37.compute-1.amazonaws.com
```

The `--var=action="init"` parameter causes the first node to be initialized for a new cluster.
The cluster is now running with a single node and is reachable through the `elb_address` (see `Using the cluster`).

#### Add more nodes to the cluster

```
$ terraform apply --var=num_instances=3

Outputs:
  elb_address          = elb-1371418843.us-east-1.elb.amazonaws.com:26257
  example_block_writer =
  instances            = ec2-54-152-252-37.compute-1.amazonaws.com,ec2-54-175-103-126.compute-1.amazonaws.com,ec2-54-175-166-150.compute-1.amazonaws.com
```

## Use the cluster

#### Connect to the cluster

Use the load balancer address to connect to the cluster. You may need to wait a few minutes after
ELB creation for its DNS name to be resolvable.

```
$ ./cockroach sql --insecure --addr=<elb_address from terraform output>
elb-1289187553.us-east-1.elb.amazonaws.com:26257> show databases;
+----------+
| Database |
+----------+
| system   |
+----------+
```

#### Ssh into individual instances

The DNS names of AWS instances is shown as a comma-separated list in the terraform output.

```
$ ssh -i ~/.ssh/cockroach.pem ubuntu@ec2-54-85-12-159.compute-1.amazonaws.com

ubuntu@ip-172-31-15-87:~$ ps -Af|grep cockroach
ubuntu    1448     1  4 20:03 ?        00:00:39 ./cockroach start --log-dir=logs --logtostderr=false --stores=ssd=data --insecure --gossip=lb=elb-1289187553.us-east-1.elb.amazonaws.com:26257

ubuntu@ip-172-31-15-87:~$ ls logs
cockroach.ERROR
cockroach.INFO
cockroach.ip-172-31-15-87.ubuntu.log.ERROR.2015-11-02T20_03_14Z.1448
cockroach.ip-172-31-15-87.ubuntu.log.INFO.2015-11-02T20_03_09Z.1443
cockroach.ip-172-31-15-87.ubuntu.log.INFO.2015-11-02T20_03_09Z.1448
cockroach.ip-172-31-15-87.ubuntu.log.WARNING.2015-11-02T20_03_09Z.1448
cockroach.STDERR
cockroach.STDOUT
cockroach.WARNING

```

#### Profile servers

Using either the ELB address (will hit a random node), or a specific instance:
```
$ go tool pprof <address:port>/debug/pprof/profile
```

#### Running examples against the cockroach cluster

See `examples.tf` for sample examples and how to run them against the created cluster.
The `block_writer` can be run against the newly-created cluster by running:
```
$ terraform apply --var=num_instances=3 --var=example_block_writer_instances=1

Outputs:
  elb_address          = elb-1371418843.us-east-1.elb.amazonaws.com:26257
  example_block_writer = ec2-54-175-206-76.compute-1.amazonaws.com
  instances            = ec2-54-152-252-37.compute-1.amazonaws.com,ec2-54-175-103-126.compute-1.amazonaws.com,ec2-54-175-166-150.compute-1.amazonaws.com
```

## Destroy the cluster

```
$ terraform destroy --var=num_instances=3
```

The destroy command requires confirmation.
