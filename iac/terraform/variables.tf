# ── Proyecto ────────────────────────────────────────────────────────────────
variable "project_id" {
  description = "ID del proyecto de GCP."
  type        = string
}

variable "region" {
  description = "Región de la VM, la subred y Cloud NAT."
  type        = string
  default     = "southamerica-east1"
}

variable "zone" {
  description = "Zona de la VM."
  type        = string
  default     = "southamerica-east1-a"
}

variable "name" {
  description = "Prefijo para los nombres de los recursos."
  type        = string
  default     = "dojo"
}

# ── DefectDojo ──────────────────────────────────────────────────────────────
variable "domain" {
  description = "Dominio público de DefectDojo (registro A hacia la IP del LB)."
  type        = string
}

variable "defectdojo_version" {
  description = "Tag de DefectDojo (repositorio e imágenes). Ver https://github.com/DefectDojo/django-DefectDojo/releases"
  type        = string
  default     = "3.5.103"
}

variable "image_registry" {
  description = "Registry de las imágenes: registry.defectdojo.com (default de DefectDojo, registra cada descarga) o docker.io."
  type        = string
  default     = "docker.io"
}

variable "machine_type" {
  description = "Tipo de máquina de la VM."
  type        = string
  default     = "e2-standard-4"
}

variable "boot_disk_size_gb" {
  description = "Tamaño del disco (sistema, imágenes, base de datos y adjuntos)."
  type        = number
  default     = 100
}

variable "subnet_cidr" {
  description = "Rango de la subred de la VM."
  type        = string
  default     = "10.10.0.0/24"
}

# ── Acceso (IAP) ────────────────────────────────────────────────────────────
variable "workspace_domain" {
  description = "Dominio de Google Workspace (ej. empresa.com). Necesario con iap_access_mode = \"domain\". Vacío si los usuarios son cuentas @gmail.com."
  type        = string
  default     = ""
}

variable "sso_allowed_domains" {
  description = "Dominios de email aceptados por el middleware de SSO (ej. [\"empresa.com\"] o [\"gmail.com\"]). Vacío = usa workspace_domain; si ambos están vacíos no se filtra por dominio (IAP ya filtra por grupo)."
  type        = list(string)
  default     = []
}

variable "iap_oauth_client_id" {
  description = "Cliente OAuth propio para IAP (obligatorio si hay usuarios fuera de la organización, como cuentas @gmail.com, o si el proyecto no tiene organización). Vacío = cliente administrado por Google (solo usuarios internos)."
  type        = string
  default     = ""
}

variable "iap_oauth_client_secret" {
  description = "Secreto del cliente OAuth propio para IAP."
  type        = string
  default     = ""
  sensitive   = true
}

variable "users_group" {
  description = "Grupo de Workspace con acceso a DefectDojo (ej. dojo-users@empresa.com)."
  type        = string
}

variable "admins_group" {
  description = "Grupo de Workspace de administradores (acceso por IAP y, con group sync, superuser). Vacío para omitir."
  type        = string
  default     = ""
}

variable "iap_access_mode" {
  description = "Quién pasa IAP: \"group\" (solo miembros de users_group/admins_group) o \"domain\" (cualquier cuenta de workspace_domain)."
  type        = string
  default     = "group"

  validation {
    condition     = contains(["group", "domain"], var.iap_access_mode)
    error_message = "iap_access_mode debe ser \"group\" o \"domain\"."
  }
}

variable "access_level" {
  description = "Nivel de acceso existente de Access Context Manager (accessPolicies/N/accessLevels/NOMBRE) exigido por IAP. Vacío para no exigirlo."
  type        = string
  default     = ""
}

# ── SSO (middleware) ────────────────────────────────────────────────────────
variable "enable_sso" {
  description = "Fase 2: iniciar sesión en DefectDojo con el JWT de IAP (un solo login)."
  type        = bool
  default     = true
}

variable "enable_group_sync" {
  description = "Fase 3: sincronizar superuser/staff desde grupos de Workspace (requiere el rol Groups Reader para la service account, ver README)."
  type        = bool
  default     = false
}

variable "staff_group" {
  description = "Fase 3: grupo de Workspace que recibe is_staff en DefectDojo. En 3.x, staff ve TODOS los productos: usar un grupo acotado. Vacío = nadie recibe staff por grupo."
  type        = string
  default     = ""
}

# ── API para CI/CD ──────────────────────────────────────────────────────────
variable "ci_source_ranges" {
  description = "CIDRs del CI/CD con acceso a /api/v2 sin IAP (protegido por Cloud Armor + token). Vacío: la API queda detrás de IAP."
  type        = list(string)
  default     = []
}

# ── Operación ───────────────────────────────────────────────────────────────
variable "snapshot_retention_days" {
  description = "Días de retención de los snapshots diarios."
  type        = number
  default     = 14
}

variable "snapshot_start_time_utc" {
  description = "Hora de inicio del snapshot diario (UTC, HH:00)."
  type        = string
  default     = "06:00"
}

variable "enable_siem_export" {
  description = "Crear tópico de Pub/Sub y log sink con los accesos de IAP para el SIEM."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Etiquetas para los recursos."
  type        = map(string)
  default = {
    app        = "defectdojo"
    managed-by = "terraform"
  }
}
