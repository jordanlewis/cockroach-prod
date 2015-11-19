provider "aws" {
  region = "${var.aws_region}"
}

resource "aws_instance" "cockroach" {
  tags {
    Name = "${format("cockroach-%d", "${count.index}")}"
  }
  ami = "${var.aws_ami_id}"
  availability_zone = "${var.aws_availability_zone}"
  instance_type = "${var.aws_instance_type}"
  security_groups = ["${aws_security_group.default.name}"]
  key_name = "${var.key_name}"
  count = "${var.num_instances}"
}

# We use a null_resource to break the dependency cycle
# between aws_elb and aws_instance.
# This can be rolled back into aws_instance when https://github.com/hashicorp/terraform/issues/3999
# is addressed.
resource "null_resource" "cockroach-provisioner" {
  count = "${var.num_instances}"
  connection {
    user = "ubuntu"
    key_file = "~/.ssh/${var.key_name}.pem"
    host = "${element(aws_instance.cockroach.*.public_ip, count.index)}"
  }

  provisioner "file" {
    source = "launch.sh"
    destination = "/home/ubuntu/launch.sh"
  }

  provisioner "file" {
    source = "download_binary.sh"
    destination = "/home/ubuntu/download_binary.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "bash download_binary.sh cockroach",
      "chmod 755 launch.sh",
      "rm -rf logs",
      "mkdir -p logs",
      "ln -s -f /var/log/syslog logs/syslog",
      "nohup ./launch.sh ${var.action} ${aws_elb.elb.dns_name}:${var.cockroach_port} > logs/nohup.out < /dev/null &",
      "sleep 5",
    ]
  }
}
