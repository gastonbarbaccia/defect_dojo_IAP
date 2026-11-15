# HTTPS Load Balancer global con IAP delante de la VM.
# /api/v2/* puede ir a un backend sin IAP, restringido por Cloud Armor (ci_source_ranges).

locals {
  api_backend_enabled = length(var.ci_source_ranges) > 0
}

resource "google_compute_global_address" "lb" {
  name       = "${var.name}-lb-ip"
  depends_on = [google_project_service.apis]
}

resource "google_compute_managed_ssl_certificate" "cert" {
  name = "${var.name}-cert"

  managed {
    domains = [var.domain]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_instance_group" "dojo" {
  name      = "${var.name}-ig"
  zone      = var.zone
  instances = [google_compute_instance.dojo.self_link]

  named_port {
    name = "http"
    port = 8080
  }
}

resource "google_compute_health_check" "dojo" {
  name                = "${var.name}-hc"
  check_interval_sec  = 15
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 4

  http_health_check {
    port         = 8080
    request_path = "/login"
    host         = var.domain # DD_ALLOWED_HOSTS no acepta la IP
  }
}

# ── Backend principal: con IAP ──────────────────────────────────────────────
resource "google_compute_backend_service" "dojo" {
  name                  = "${var.name}-backend"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTP"
  port_name             = "http"
  timeout_sec           = 600 # imports grandes de escaneos
  health_checks         = [google_compute_health_check.dojo.id]

  backend {
    group           = google_compute_instance_group.dojo.self_link
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }

  iap {
    enabled = true
    # Vacío = cliente administrado por Google (solo usuarios de la organización).
    # Con cliente propio (audiencia External) pueden entrar cuentas @gmail.com del grupo.
    oauth2_client_id     = var.iap_oauth_client_id != "" ? var.iap_oauth_client_id : null
    oauth2_client_secret = var.iap_oauth_client_id != "" ? var.iap_oauth_client_secret : null
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }

  depends_on = [google_project_service.apis]
}

# ── Backend de la API para CI/CD: sin IAP, con Cloud Armor ──────────────────
resource "google_compute_security_policy" "api" {
  count       = local.api_backend_enabled ? 1 : 0
  name        = "${var.name}-api-policy"
  description = "Solo las IPs del CI/CD pueden usar /api/v2"

  rule {
    action   = "allow"
    priority = 1000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = var.ci_source_ranges
      }
    }
    description = "CI/CD"
  }

  rule {
    action   = "deny(403)"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default: denegar"
  }
}

resource "google_compute_backend_service" "api" {
  count                 = local.api_backend_enabled ? 1 : 0
  name                  = "${var.name}-api-backend"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTP"
  port_name             = "http"
  timeout_sec           = 600
  health_checks         = [google_compute_health_check.dojo.id]
  security_policy       = google_compute_security_policy.api[0].id

  backend {
    group           = google_compute_instance_group.dojo.self_link
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

# ── URL map, HTTPS y redirección HTTP → HTTPS ───────────────────────────────
resource "google_compute_url_map" "https" {
  name            = "${var.name}-urlmap"
  default_service = google_compute_backend_service.dojo.id

  dynamic "host_rule" {
    for_each = local.api_backend_enabled ? [1] : []
    content {
      hosts        = [var.domain]
      path_matcher = "api"
    }
  }

  dynamic "path_matcher" {
    for_each = local.api_backend_enabled ? [1] : []
    content {
      name            = "api"
      default_service = google_compute_backend_service.dojo.id

      path_rule {
        paths   = ["/api/v2/*"]
        service = google_compute_backend_service.api[0].id
      }
    }
  }
}

resource "google_compute_target_https_proxy" "https" {
  name             = "${var.name}-https-proxy"
  url_map          = google_compute_url_map.https.id
  ssl_certificates = [google_compute_managed_ssl_certificate.cert.id]
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "${var.name}-https"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.lb.id
  target                = google_compute_target_https_proxy.https.id
  port_range            = "443"
}

resource "google_compute_url_map" "http_redirect" {
  name = "${var.name}-http-redirect"

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "http" {
  name    = "${var.name}-http-proxy"
  url_map = google_compute_url_map.http_redirect.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "${var.name}-http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.lb.id
  target                = google_compute_target_http_proxy.http.id
  port_range            = "80"
}
