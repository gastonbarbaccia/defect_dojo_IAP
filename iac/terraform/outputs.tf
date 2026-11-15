output "lb_ip" {
  description = "IP del Load Balancer: crear el registro DNS A del dominio hacia esta IP."
  value       = google_compute_global_address.lb.address
}

output "url" {
  value = "https://${var.domain}"
}

output "dns_record" {
  description = "Registro DNS a crear."
  value       = "${var.domain}.  300  IN  A  ${google_compute_global_address.lb.address}"
}

output "iap_audience" {
  description = "Audience del JWT de IAP (lo usa el middleware de SSO)."
  value       = google_compute_project_metadata_item.iap_audience.value
}

output "vm_service_account" {
  description = "Service account de la VM (para el rol Groups Reader de Workspace en la fase 3)."
  value       = google_service_account.vm.email
}

output "ssh_command" {
  description = "SSH a la VM vía IAP."
  value       = "gcloud compute ssh ${google_compute_instance.dojo.name} --zone ${var.zone} --project ${var.project_id} --tunnel-through-iap"
}

output "break_glass_command" {
  description = "Acceso de emergencia (usuario admin local) por túnel SSH: luego abrir http://localhost:8080/login"
  value       = "gcloud compute ssh ${google_compute_instance.dojo.name} --zone ${var.zone} --project ${var.project_id} --tunnel-through-iap -- -L 8080:localhost:8080"
}

output "admin_password_command" {
  description = "Contraseña del usuario admin local (solo para emergencias)."
  value       = "gcloud secrets versions access latest --secret=${google_secret_manager_regional_secret.dojo["admin-password"].secret_id} --location=${var.region} --project ${var.project_id}"
}

output "startup_log_command" {
  description = "Ver el progreso de la instalación en la VM."
  value       = "gcloud compute ssh ${google_compute_instance.dojo.name} --zone ${var.zone} --project ${var.project_id} --tunnel-through-iap -- sudo tail -f /var/log/dojo-startup.log"
}

output "certificate_status_command" {
  value = "gcloud compute ssl-certificates describe ${google_compute_managed_ssl_certificate.cert.name} --global --project ${var.project_id} --format='value(managed.status,managed.domainStatus)'"
}

output "siem_subscription" {
  description = "Suscripción de Pub/Sub para el SIEM (si enable_siem_export)."
  value       = var.enable_siem_export ? google_pubsub_subscription.siem[0].id : null
}
