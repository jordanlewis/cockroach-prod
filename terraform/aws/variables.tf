# Number of instances to start.
variable "num_instances" {}

# Port used for the load balancer and backends.
variable "cockroach_port" {
  default = "26257"
}

# AWS region to use. WARNING: changing this will break the AMI ID.
variable "aws_region" {
  default = "us-east-1"
}

# AWS availability zone. Make sure it exists for your account.
variable "aws_availability_zone" {
  default = "us-east-1a"
}

# AWS image ID. The default is valid for region "us-east-1".
# This is an ubuntu image with HVM.
variable "aws_ami_id" {
  default = "ami-1c552a76"
}

# AWS instance type. This may affect valid AMIs.
variable "aws_instance_type" {
  default = "t2.micro"
}

# Name of the ssh key pair for this AWS region. Your .pem file must be:
# ~/.ssh/<key_name>.pem
variable "key_name" {
  default = "cockroach"
}

# Action is one of "init" or "start". init should only be specified when
# running `terraform apply` on the first node.
variable "action" {
  default = "start"
}
