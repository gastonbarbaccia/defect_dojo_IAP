# Secretos de DefectDojo generados por Terraform y guardados en Secret Manager.
# La VM los lee al arrancar; no quedan en la metadata de la instancia.
# Nota: también quedan en el estado de Terraform → proteger el bucket del estado.

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "random_password" "secret_key" {
  length  = 64
  special = false
}

resource "random_password" "aes_key" {
  length  = 32
  special = false
}

resource "random_password" "admin" {
  length           = 24
  special          = true
  override_special = "!#%*-_=+"
}

locals {
  secrets = {
    "db-password"    = random_password.db.result
    "secret-key"     = random_password.secret_key.result
    "aes-key"        = random_password.aes_key.result
    "admin-password" = random_password.admin.result
  }
}

# Secretos REGIONALES: viven solo en var.region (cumplen gcp.resourceLocations;
# los secretos "globales" quedan bloqueados por esa política aunque se repliquen en una región).
resource "google_secret_manager_regional_secret" "dojo" {
  for_each  = local.secrets
  secret_id = "${var.name}-${each.key}"
  location  = var.region
  labels    = var.labels

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_regional_secret_version" "dojo" {
  for_each    = local.secrets
  secret      = google_secret_manager_regional_secret.dojo[each.key].id
  secret_data = each.value
}

resource "google_secret_manager_regional_secret_iam_member" "vm" {
  for_each  = local.secrets
  secret_id = google_secret_manager_regional_secret.dojo[each.key].secret_id
  location  = var.region
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm.email}"
}
