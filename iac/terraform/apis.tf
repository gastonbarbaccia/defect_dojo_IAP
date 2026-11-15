locals {
  apis = concat(
    [
      "compute.googleapis.com",
      "iap.googleapis.com",
      "secretmanager.googleapis.com",
      "logging.googleapis.com",
      "monitoring.googleapis.com",
      "cloudresourcemanager.googleapis.com",
    ],
    var.enable_group_sync ? ["cloudidentity.googleapis.com"] : [],
    var.enable_siem_export ? ["pubsub.googleapis.com"] : [],
  )
}

resource "google_project_service" "apis" {
  for_each           = toset(local.apis)
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
