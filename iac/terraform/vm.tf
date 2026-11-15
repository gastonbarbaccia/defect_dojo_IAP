# VM con DefectDojo (docker compose oficial), sin IP pública.
# El script de arranque instala Docker, clona DefectDojo, escribe .env, override y
# el middleware de SSO, y levanta los contenedores. Se ejecuta en cada arranque.

locals {
  audience_metadata_key = "${var.name}-iap-audience"

  startup_script = templatefile("${path.module}/files/startup.sh.tftpl", {
    name                  = var.name
    project_id            = var.project_id
    region                = var.region
    domain                = var.domain
    dd_version            = var.defectdojo_version
    image_registry        = var.image_registry
    sso_allowed_domains   = join(",", length(var.sso_allowed_domains) > 0 ? var.sso_allowed_domains : compact([var.workspace_domain]))
    enable_sso            = var.enable_sso
    enable_group_sync     = var.enable_group_sync
    staff_group           = var.staff_group
    admins_group          = var.admins_group
    audience_metadata_key = local.audience_metadata_key
  })
}

data "google_compute_image" "debian" {
  family  = "debian-12"
  project = "debian-cloud"
}

resource "google_compute_disk" "boot" {
  name   = "${var.name}-vm-boot"
  zone   = var.zone
  type   = "pd-balanced"
  size   = var.boot_disk_size_gb
  image  = data.google_compute_image.debian.self_link
  labels = var.labels

  lifecycle {
    # Una imagen nueva de Debian no debe recrear el disco (perdería los datos)
    ignore_changes = [image]
  }
}

resource "google_compute_instance" "dojo" {
  name                      = "${var.name}-vm"
  zone                      = var.zone
  machine_type              = var.machine_type
  tags                      = ["${var.name}-vm"]
  labels                    = var.labels
  allow_stopping_for_update = true
  deletion_protection       = true

  boot_disk {
    source      = google_compute_disk.boot.id
    auto_delete = false
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    # Sin access_config: no tiene IP pública
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
    startup-script         = local.startup_script
    # Archivos del middleware (fases 2 y 3), copiados a docker/extra_settings
    dojo-iap-sso-py        = file("${path.module}/files/iap_sso.py")
    dojo-local-settings-py = file("${path.module}/files/local_settings.py")
  }

  # El arranque necesita internet (Cloud NAT) y poder leer los secretos
  depends_on = [
    google_compute_router_nat.nat,
    google_secret_manager_regional_secret_iam_member.vm,
    google_secret_manager_regional_secret_version.dojo,
  ]
}
