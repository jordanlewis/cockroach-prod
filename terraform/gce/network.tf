resource "google_compute_backend_service" "foobar" {
    name = "blablah"
    description = "Hello World 1234"
    port_name = "http"
    protocol = "HTTP"
    timeout_sec = 10
    region = "us-central1"

    backend {
        group = "${google_compute_instance_group_manager.cockroach.instance_group}"
    }

    health_checks = ["${google_compute_http_health_check.cockroach.self_link}"]
}

resource "google_compute_instance_group_manager" "cockroach" {
    name = "terraform-test"
    instance_template = "${google_compute_instance_template.foobar.self_link}"
    base_instance_name = "foobar"
    zone = "us-central1-f"
    target_size = 1
}

resource "google_compute_instance_template" "cockroach" {
  name = "cockroach"
  machine_type = "n1-standard-1"

  network_interface {
    network = "default"
  }

  disk {
    source_image = "${var.gce_image}"
    auto_delete = true
    boot = true
  }
}
resource "google_compute_http_health_check" "cockroach" {
  name = "cockroach-health-check"
  request_path = "/health"
  port = "${var.cockroach_port}"
  check_interval_sec = 2
  healthy_threshold = 2
  unhealthy_threshold = 2
  timeout_sec = 2
}

resource "google_compute_target_pool" "cockroach" {
  name = "cockroach-target-pool"
  # Note: when there are no instances, aws_instance.cockroach.*.id has an empty
  # element, causing failed elb updates. See: https://github.com/hashicorp/terraform/issues/3581
  instances = ["${compact(split(",", join(",",google_compute_instance.cockroach.*.self_link)))}"]
  health_checks = ["${google_compute_http_health_check.cockroach.name}"]
}

resource "google_compute_forwarding_rule" "cockroach" {
  name = "cockroach-forwarding-rule"
  target = "${google_compute_target_pool.cockroach.self_link}"
  port_range = "${var.cockroach_port}"
}

resource "google_compute_firewall" "cockroach" {
  name = "cockroach-firewall"
  network = "default"

  allow {
    protocol = "tcp"
    ports = ["${var.cockroach_port}"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags = ["cockroach"]
}

