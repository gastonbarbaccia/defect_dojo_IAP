# Red dedicada: la VM no tiene IP pública. Solo entra el LB (8080) y SSH vía IAP (22).

resource "google_compute_network" "vpc" {
  name                    = "${var.name}-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "subnet" {
  name                     = "${var.name}-subnet"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true
}

# Salida a internet (imágenes, actualizaciones, claves de IAP) sin IP pública
resource "google_compute_router" "router" {
  name    = "${var.name}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Solo el Load Balancer de Google (y sus health checks) llega a nginx
resource "google_compute_firewall" "allow_lb" {
  name          = "${var.name}-allow-lb"
  network       = google_compute_network.vpc.id
  direction     = "INGRESS"
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["${var.name}-vm"]

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }
}

# SSH de administración únicamente a través de IAP TCP forwarding
resource "google_compute_firewall" "allow_iap_ssh" {
  name          = "${var.name}-allow-iap-ssh"
  network       = google_compute_network.vpc.id
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["${var.name}-vm"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
