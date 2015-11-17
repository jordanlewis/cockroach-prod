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

  connection {
    user = "ubuntu"
    key_file = "~/.ssh/${var.key_name}.pem"
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
      "./launch.sh ${var.action} ${var.gossip}",
      "sleep 1",
    ]
  }
}
