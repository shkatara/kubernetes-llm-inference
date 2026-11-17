data "http" "my_ip" {
  url = "https://ipv4.icanhazip.com"
}

locals {
  my_cidr            = "${chomp(data.http.my_ip.response_body)}/32"
  ssh_source_ranges  = length(var.ssh_source_ranges) > 0 ? var.ssh_source_ranges : [local.my_cidr]
  http_source_ranges = length(var.http_source_ranges) > 0 ? var.http_source_ranges : [local.my_cidr]
  tags               = ["${var.name}-vm"]
  server_cidr        = "10.10.0.0/24"
  worker_cidrs       = ["10.20.0.0/24", "10.30.0.0/24"]
  worker_ips         = ["10.20.0.10", "10.30.0.10"]
  all_cidrs          = concat([local.server_cidr], local.worker_cidrs, ["10.42.0.0/16", "10.43.0.0/16"])
  total_gpus         = var.gpu_count + (length(var.worker_project_ids) * var.worker_gpu_count)
  expected_nodes     = 1 + length(var.worker_project_ids)
  server_priv_ip     = "10.10.0.10"
}

resource "random_password" "rke2_token" {
  length  = 40
  special = false
}

# --------------------------------------------------- Primary project network
resource "google_compute_network" "server" {
  project                 = var.project_id
  name                    = "${var.name}-net"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "server" {
  project       = var.project_id
  name          = "${var.name}-subnet"
  ip_cidr_range = local.server_cidr
  region        = var.region
  network       = google_compute_network.server.id
}

resource "google_compute_firewall" "ssh_api" {
  project = var.project_id
  name    = "${var.name}-allow-ssh-api"
  network = google_compute_network.server.name

  allow {
    protocol = "tcp"
    ports    = ["22", "6443"]
  }

  source_ranges = local.ssh_source_ranges
  target_tags   = local.tags
}

resource "google_compute_firewall" "http" {
  project = var.project_id
  name    = "${var.name}-allow-http"
  network = google_compute_network.server.name

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "3000"]
  }

  source_ranges = local.http_source_ranges
  target_tags   = local.tags
}

resource "google_compute_firewall" "server_internal" {
  project = var.project_id
  name    = "${var.name}-allow-internal"
  network = google_compute_network.server.name

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = local.all_cidrs
  target_tags   = local.tags
}

resource "google_compute_address" "server" {
  project = var.project_id
  name    = "${var.name}-ip"
  region  = var.region
}

# ---------------------------------------------------- Worker project networks
resource "google_compute_network" "worker" {
  count                   = 2
  project                 = var.worker_project_ids[count.index]
  name                    = "${var.name}-w${count.index + 1}-net"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "worker" {
  count         = 2
  project       = var.worker_project_ids[count.index]
  name          = "${var.name}-w${count.index + 1}-subnet"
  ip_cidr_range = local.worker_cidrs[count.index]
  region        = var.region
  network       = google_compute_network.worker[count.index].id
}

resource "google_compute_firewall" "worker_ssh" {
  count   = 2
  project = var.worker_project_ids[count.index]
  name    = "${var.name}-w${count.index + 1}-allow-ssh"
  network = google_compute_network.worker[count.index].name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = local.ssh_source_ranges
  target_tags   = local.tags
}

resource "google_compute_firewall" "worker_internal" {
  count   = 2
  project = var.worker_project_ids[count.index]
  name    = "${var.name}-w${count.index + 1}-allow-internal"
  network = google_compute_network.worker[count.index].name

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = local.all_cidrs
  target_tags   = local.tags
}

# --------------------------------------- Full-mesh VPC peering (serialized)
# GCP rejects concurrent peering operations on the same VPC, so chain them via depends_on.
resource "google_compute_network_peering" "server_to_w1" {
  name         = "${var.name}-server-to-w1"
  network      = google_compute_network.server.self_link
  peer_network = google_compute_network.worker[0].self_link
}

resource "google_compute_network_peering" "w1_to_server" {
  name         = "${var.name}-w1-to-server"
  network      = google_compute_network.worker[0].self_link
  peer_network = google_compute_network.server.self_link
  depends_on   = [google_compute_network_peering.server_to_w1]
}

resource "google_compute_network_peering" "server_to_w2" {
  name         = "${var.name}-server-to-w2"
  network      = google_compute_network.server.self_link
  peer_network = google_compute_network.worker[1].self_link
  depends_on   = [google_compute_network_peering.w1_to_server]
}

resource "google_compute_network_peering" "w2_to_server" {
  name         = "${var.name}-w2-to-server"
  network      = google_compute_network.worker[1].self_link
  peer_network = google_compute_network.server.self_link
  depends_on   = [google_compute_network_peering.server_to_w2]
}

resource "google_compute_network_peering" "w1_to_w2" {
  name         = "${var.name}-w1-to-w2"
  network      = google_compute_network.worker[0].self_link
  peer_network = google_compute_network.worker[1].self_link
  depends_on   = [google_compute_network_peering.w2_to_server]
}

resource "google_compute_network_peering" "w2_to_w1" {
  name         = "${var.name}-w2-to-w1"
  network      = google_compute_network.worker[1].self_link
  peer_network = google_compute_network.worker[0].self_link
  depends_on   = [google_compute_network_peering.w1_to_w2]
}

# ------------------------------------------------------- GPU VMs (3 projects)
resource "google_compute_instance" "server" {
  project      = var.project_id
  name         = "${var.name}-node"
  machine_type = var.machine_type
  zone         = var.zone
  tags         = local.tags

  guest_accelerator {
    type  = "nvidia-tesla-t4"
    count = var.gpu_count
  }

  scheduling {
    provisioning_model          = var.spot ? "SPOT" : "STANDARD"
    preemptible                 = var.spot
    automatic_restart           = var.spot ? false : true
    on_host_maintenance         = "TERMINATE"
    instance_termination_action = var.spot ? "STOP" : null
  }

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = var.boot_disk_size_gb
      type  = "pd-ssd"
    }
  }

  network_interface {
    network    = google_compute_network.server.id
    subnetwork = google_compute_subnetwork.server.id
    network_ip = local.server_priv_ip

    access_config {
      nat_ip = google_compute_address.server.address
    }
  }

  metadata = {
    enable-oslogin = "TRUE"
  }

  metadata_startup_script = templatefile("${path.module}/startup.sh", {
    rke2_channel       = var.rke2_channel
    rke2_token         = random_password.rke2_token.result
    server_internal_ip = local.server_priv_ip
    total_gpus         = local.total_gpus
    expected_nodes     = local.expected_nodes
    public_ip          = google_compute_address.server.address
    openrouter_api_key = var.openrouter_api_key != "" ? var.openrouter_api_key : "sk-or-replace-me"
    manifests          = base64encode(join("\n---\n", [for f in sort(fileset("${path.module}/k8s", "*.yaml")) : file("${path.module}/k8s/${f}")]))
  })

  service_account {
    scopes = ["cloud-platform"]
  }

  allow_stopping_for_update = true
  depends_on                = [google_compute_network_peering.w2_to_w1]
}

resource "google_compute_instance" "worker" {
  count        = 2
  project      = var.worker_project_ids[count.index]
  name         = "${var.name}-worker-${count.index + 1}"
  machine_type = var.worker_machine_type
  zone         = var.zone
  tags         = local.tags

  guest_accelerator {
    type  = "nvidia-tesla-t4"
    count = var.worker_gpu_count
  }

  scheduling {
    provisioning_model          = var.spot ? "SPOT" : "STANDARD"
    preemptible                 = var.spot
    automatic_restart           = var.spot ? false : true
    on_host_maintenance         = "TERMINATE"
    instance_termination_action = var.spot ? "STOP" : null
  }

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = var.worker_boot_disk_size_gb
      type  = "pd-ssd"
    }
  }

  network_interface {
    network    = google_compute_network.worker[count.index].id
    subnetwork = google_compute_subnetwork.worker[count.index].id
    network_ip = local.worker_ips[count.index]

    access_config {}
  }

  metadata = {
    enable-oslogin = "TRUE"
  }

  metadata_startup_script = templatefile("${path.module}/worker-startup.sh", {
    rke2_channel       = var.rke2_channel
    rke2_token         = random_password.rke2_token.result
    server_internal_ip = local.server_priv_ip
    worker_internal_ip = local.worker_ips[count.index]
  })

  service_account {
    scopes = ["cloud-platform"]
  }

  allow_stopping_for_update = true
  depends_on                = [google_compute_network_peering.w2_to_w1]
}
