# Run the sql logic test suite on AWS.
# Prerequisites:
# - AWS account credentials and key as specified in cockroach-prod/terraform/aws/README.md
# - sqllogic test repo cloned
#
# Run with:
# terraform apply --var=aws_access_key="${AWS_ACCESS_KEY}" \
#                 --var=aws_secret_key="${AWS_SECRET_KEY}"
#
# Tear down AWS resources using:
# terraform destroy --var=aws_access_key="${AWS_ACCESS_KEY}" \
#                   --var=aws_secret_key="${AWS_SECRET_KEY}"
#
# The used logic tests are tarred and gzipped before launching the instance.
# Test are sharded by subdirectory (see variables.tf for details), with one
# instance handling each subdirectory.
# The latest sql.test binary is fetched from S3.
#
# Monitor the output of the tests by running:
# $ ssh -i ~/.ssh/cockroach.pem ubuntu@<instance> tail -F test.STDOUT

provider "aws" {
    access_key = "${var.aws_access_key}"
    secret_key = "${var.aws_secret_key}"
    region = "${var.aws_region}"
}

output "instance" {
  value = "${join(",", aws_instance.sql_logic_test.*.public_dns)}"
}

resource "aws_instance" "sql_logic_test" {
    tags {
      Name = "cockroach-sql-logic-test-${count.index}"
    }
    depends_on = ["null_resource.sql_tarball"]

    ami = "${var.aws_ami_id}"
    availability_zone = "${var.aws_availability_zone}"
    instance_type = "${var.aws_instance_type}"
    security_groups = ["${aws_security_group.default.name}"]
    key_name = "${var.key_name}"
    count = "${length(split(",", var.sql_logic_subdirectories))}"

    connection {
      user = "ubuntu"
      key_file = "~/.ssh/${var.key_name}.pem"
    }

    provisioner "file" {
        source = "launch.sh"
        destination = "/home/ubuntu/launch.sh"
    }

    provisioner "file" {
        source = "tarball${count.index}.tgz"
        destination = "/home/ubuntu/sqltests.tgz"
    }

   provisioner "remote-exec" {
        inline = [
          "chmod 755 launch.sh",
          "tar xfz sqltests.tgz",
          "./launch.sh",
          "sleep 1",
        ]
   }
}

resource "null_resource" "sql_tarball" {
    count = "${length(split(",", var.sql_logic_subdirectories))}"
    provisioner "local-exec" {
        command = "tar cfz tarball${count.index}.tgz -C ${var.sqllogictest_repo} ${element(split(",", var.sql_logic_subdirectories),count.index)}"
    }
}

resource "aws_security_group" "default" {
    name = "sqltest_security_group"

    ingress {
        from_port = 22
        to_port = 22
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
}
