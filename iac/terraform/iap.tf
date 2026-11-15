# Acceso web por IAP: solo los grupos de Workspace indicados.
# Con access_level, además se exige el nivel de acceso (por ejemplo, dispositivo administrado).

locals {
  iap_members = compact([
    var.iap_access_mode == "domain" ? "domain:${var.workspace_domain}" : "group:${var.users_group}",
    var.admins_group != "" ? "group:${var.admins_group}" : "",
  ])
}

resource "google_iap_web_backend_service_iam_member" "access" {
  for_each            = toset(local.iap_members)
  project             = var.project_id
  web_backend_service = google_compute_backend_service.dojo.name
  role                = "roles/iap.httpsResourceAccessor"
  member              = each.value

  lifecycle {
    precondition {
      condition     = var.iap_access_mode == "group" || var.workspace_domain != ""
      error_message = "iap_access_mode = \"domain\" requiere workspace_domain."
    }
  }

  dynamic "condition" {
    for_each = var.access_level != "" ? [1] : []
    content {
      title       = "nivel-de-acceso"
      description = "Exige el nivel de acceso ${var.access_level}"
      expression  = "\"${var.access_level}\" in request.auth.access_levels"
    }
  }
}

# Audience del JWT de IAP para el middleware de SSO.
# Se publica como metadata del proyecto (la VM lo lee al arrancar) para evitar
# una dependencia circular entre la VM y el backend service.
resource "google_compute_project_metadata_item" "iap_audience" {
  key   = local.audience_metadata_key
  value = "/projects/${data.google_project.this.number}/global/backendServices/${google_compute_backend_service.dojo.generated_id}"
}

# Auditoría: registrar cada acceso permitido o denegado por IAP
resource "google_project_iam_audit_config" "iap" {
  project = var.project_id
  service = "iap.googleapis.com"

  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "ADMIN_READ"
  }
}
