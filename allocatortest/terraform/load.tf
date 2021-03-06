# Load generators that can be used to fill the CockroachDB cluster with data.

variable "block_writer_instances" {
  default = 1
}
output "block_writer_ips" {
  value = "${join(",", google_compute_instance.block_writer.*.network_interface.0.access_config.0.assigned_nat_ip)}"
}
output "block_writer_instances" {
  value = "${join(",", google_compute_instance.block_writer.*.name)}"
}

resource "google_compute_instance" "block_writer" {
  count = "${var.block_writer_instances}"

  name = "${var.name_prefix}-block-writer-${count.index + 1}"
  machine_type = "${var.gce_machine_type}"
  zone = "${var.gce_zone}"
  tags = ["cockroach"]

  disk {
    image = "${var.gce_image}"
  }

  network_interface {
    network = "default"
    access_config {
        # Ephemeral
    }
  }

  metadata {
    sshKeys = "ubuntu:${file("~/.ssh/${var.key_name}.pub")}"
  }

  connection {
    user = "ubuntu"
    key_file = "~/.ssh/${var.key_name}"
  }

  service_account {
    scopes = ["https://www.googleapis.com/auth/compute.readonly"]
  }

  provisioner "file" {
    source = "./download_binary.sh"
    destination = "/home/ubuntu/download_binary.sh"
  }

  # This writes the filled-in supervisor template. It would be nice if we could
  # use rendered templates in the file provisioner.
  provisioner "remote-exec" {
    inline = <<FILE
echo '${template_file.supervisor.0.rendered}' > supervisor.conf
FILE
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt-get -y update",
      "sudo apt-get -y install supervisor",
      "sudo service supervisor stop",
      "bash download_binary.sh examples-go/block_writer ${var.block_writer_sha}",
      "mkdir -p logs",
      "if [ ! -e supervisor.pid ]; then supervisord -c supervisor.conf; fi",
    ]
  }
}
