# Service account propia de la VM (mínimo privilegio)

resource "google_service_account" "vm" {
  account_id   = "${var.name}-vm"
  display_name = "DefectDojo VM"
  depends_on   = [google_project_service.apis]
}

resource "google_project_iam_member" "vm" {
  for_each = toset([
    "roles/logging.logWriter", # logs de contenedores (driver gcplogs)
    "roles/monitoring.metricWriter",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.vm.email}"
}

# Quién puede entrar por SSH vía IAP (además del acceso web): solo admins
resource "google_project_iam_member" "admins_iap_tunnel" {
  count   = var.admins_group != "" ? 1 : 0
  project = var.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "group:${var.admins_group}"
}

resource "google_project_iam_member" "admins_os_admin_login" {
  count   = var.admins_group != "" ? 1 : 0
  project = var.project_id
  role    = "roles/compute.osAdminLogin"
  member  = "group:${var.admins_group}"
}
