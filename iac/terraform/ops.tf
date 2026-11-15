# ── Snapshots diarios del disco ─────────────────────────────────────────────
resource "google_compute_resource_policy" "daily_snapshot" {
  name   = "${var.name}-daily-snapshot"
  region = var.region

  snapshot_schedule_policy {
    schedule {
      daily_schedule {
        days_in_cycle = 1
        start_time    = var.snapshot_start_time_utc
      }
    }
    retention_policy {
      max_retention_days    = var.snapshot_retention_days
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }
    snapshot_properties {
      labels            = var.labels
      storage_locations = [var.region]
      guest_flush       = false
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_compute_disk_resource_policy_attachment" "daily_snapshot" {
  name = google_compute_resource_policy.daily_snapshot.name
  disk = google_compute_disk.boot.name
  zone = var.zone
}

# ── Exportación de accesos de IAP al SIEM (Pub/Sub) ─────────────────────────
resource "google_pubsub_topic" "siem" {
  count  = var.enable_siem_export ? 1 : 0
  name   = "${var.name}-iap-logs"
  labels = var.labels

  depends_on = [google_project_service.apis]
}

resource "google_logging_project_sink" "siem" {
  count                  = var.enable_siem_export ? 1 : 0
  name                   = "${var.name}-iap-to-siem"
  destination            = "pubsub.googleapis.com/${google_pubsub_topic.siem[0].id}"
  filter                 = "protoPayload.serviceName=\"iap.googleapis.com\" OR (resource.type=\"gce_instance\" AND jsonPayload.message:(\"Login SSO\" OR \"JWT de IAP\"))"
  unique_writer_identity = true
}

resource "google_pubsub_topic_iam_member" "siem_sink" {
  count  = var.enable_siem_export ? 1 : 0
  topic  = google_pubsub_topic.siem[0].name
  role   = "roles/pubsub.publisher"
  member = google_logging_project_sink.siem[0].writer_identity
}

resource "google_pubsub_subscription" "siem" {
  count                      = var.enable_siem_export ? 1 : 0
  name                       = "${var.name}-iap-logs-siem"
  topic                      = google_pubsub_topic.siem[0].id
  ack_deadline_seconds       = 60
  message_retention_duration = "604800s"
  labels                     = var.labels
}
