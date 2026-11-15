# DefectDojo + Identity-Aware Proxy en GCP: infraestructura como código

Terraform que despliega **todo** con un solo `terraform apply`:

- La **red** privada.
- La **VM con DefectDojo 3.5.103** instalado con `docker compose`.
- Los **secretos** en Secret Manager.
- El **HTTPS Load Balancer** con **IAP** y acceso por **grupo de Google Workspace**.
- El **middleware de SSO** (un solo login con el JWT de IAP).
- La **API para CI/CD** protegida con **Cloud Armor**.
- **Snapshots** diarios, **auditoría** y exportación opcional al **SIEM**.

> Validado con `tofu validate` (OpenTofu 1.8, provider google 6.8) y `shellcheck`. El middleware se probó con Django 5.2 contra JWT válidos y manipulados. Se recomienda un primer despliegue en un proyecto de prueba.

---

## 1. Plan

### 1.1 Qué se despliega

```
Usuario (Workspace) ──► HTTPS LB ──► IAP (login Google + grupo) ──► dojo-backend ──► VM (sin IP pública)
                         │                                                           ├─ nginx :8080
CI/CD (IPs fijas) ──────►│ /api/v2/* ──► Cloud Armor ──► dojo-api-backend ───────────┤─ uwsgi + iap_sso.py
                         │                                                           ├─ celery
HTTP :80 ──► 301 HTTPS   │                                                           ├─ PostgreSQL
                                                                                     └─ Valkey
VM ──► Cloud NAT (salida)    Admin ──► SSH vía IAP    Disco ──► snapshot diario    IAP ──► Cloud Logging (──► SIEM)
```

| Archivo | Recursos |
|---|---|
| `apis.tf` | APIs del proyecto |
| `network.tf` | VPC, subred, Cloud Router + NAT, firewall (solo LB → 8080 y SSH vía IAP → 22) |
| `iam.tf` | Service account de la VM (mínimo privilegio), SSH por IAP para el grupo de admins |
| `secrets.tf` | Contraseñas y claves aleatorias en Secret Manager, como secretos **regionales** (BD, `SECRET_KEY`, clave AES, admin) |
| `vm.tf` | Disco, VM Debian 12 con Shielded VM y OS Login, script de arranque |
| `files/startup.sh.tftpl` | Instala Docker, clona DefectDojo, escribe `.env` y el override, copia el middleware y levanta todo |
| `files/iap_sso.py` · `files/local_settings.py` | Middleware de SSO con el JWT de IAP y roles por grupo |
| `lb.tf` | IP global, certificado administrado, health check, backends, Cloud Armor, URL map, HTTPS y redirección HTTP |
| `iap.tf` | Acceso por grupo (con nivel de acceso opcional), audience para el middleware y auditoría de IAP |
| `ops.tf` | Snapshots diarios, log sink + Pub/Sub para el SIEM |
| `outputs.tf` | IP, registro DNS, comandos de SSH, emergencia y verificación |
| `scripts/verify.sh` | Verificación posterior al despliegue |

### 1.2 Fases

| Fase | Qué habilita | Cómo |
|---|---|---|
| **1 · IAP como portero** | Acceso por grupo, VM sin IP pública, HTTPS, auditoría, snapshots | Siempre |
| **2 · Un solo login** | Entra directo a DefectDojo con su cuenta de Google | `enable_sso = true` (default) |
| **3 · Evolución** | Roles por grupo, dispositivos administrados, SIEM | `enable_group_sync`, `access_level`, `enable_siem_export` |

### 1.3 Cronograma sugerido

| Día | Actividad | Responsable |
|---|---|---|
| 1 | Requisitos: proyecto, bucket de estado, grupos de Workspace, DNS | Seguridad + Infra |
| 1 | `terraform apply` en proyecto de prueba, DNS, `verify.sh` | Infra |
| 2 | Pruebas de acceso (grupo, fuera del grupo, cuenta personal, logout, emergencia) | Seguridad |
| 2 | Migración de datos, si ya existe un DefectDojo (sección 6) | Infra |
| 3 | `apply` en producción, comunicación al equipo | Infra + Seguridad |
| +1 semana | Fase 3: rol Groups Reader, `enable_group_sync = true`, SIEM | Workspace + Seguridad |

---

## 2. Requisitos

- Proyecto de GCP con facturación. Si los usuarios son de tu organización, el proyecto debe estar dentro de ella. Con cuentas @gmail.com o sin organización, ver la [sección 7 bis](#7-bis-google-groups-gratuitos-googlegroupscom-y-cuentas-gmailcom).
- **Terraform ≥ 1.6** (u OpenTofu ≥ 1.6) y **Google Cloud CLI** (`gcloud`).
- Permisos de quien ejecuta: `Owner` en el proyecto, o `Compute Admin` + `IAP Admin` + `Secret Manager Admin` + `Service Account Admin` + `Project IAM Admin` + `Logging Admin` + `Service Usage Admin` + `Storage Admin`.
- Grupos creados: `dojo-users@…` y, opcionalmente, `dojo-admins@…`.
- Acceso al DNS del dominio para crear un registro **A**.
- Si hay usuarios fuera de la organización, el cliente OAuth propio (sección 7 bis).

### 2.1 Autenticación y proyecto

```bash
PROJECT_ID=<TU_PROYECTO>

gcloud auth login
gcloud config set project $PROJECT_ID
gcloud config list                     # verificar account y project

# Credenciales que usa Terraform (Application Default Credentials), con la MISMA cuenta
gcloud auth application-default login
gcloud auth application-default set-quota-project $PROJECT_ID
```

> Si aparece *"Your active project does not match the quota project in your local Application Default Credentials file"*, las credenciales de Terraform son de otra cuenta o proyecto. Repetir los dos últimos comandos con la cuenta correcta; si no, Terraform falla con permisos denegados.

### 2.2 Bucket para el estado de Terraform

El estado **contiene secretos**: el bucket debe tener acceso restringido y versionado. `gsutil` está en desuso; se usa `gcloud storage`.

```bash
BUCKET=$PROJECT_ID-tfstate

gcloud storage buckets create gs://$BUCKET \
  --project=$PROJECT_ID \
  --location=us-central1 \
  --uniform-bucket-level-access
gcloud storage buckets update gs://$BUCKET --versioning
```

> Si da `403 ... does not have storage.buckets.create access ... projects/_`, falta el `--project` o el proyecto no está configurado en `gcloud` (paso 2.1). En sandboxes con regiones restringidas, usar `us-central1`.

**Alternativa sin bucket (solo pruebas o sandbox):** estado local. Desde `terraform/`, crear el archivo `backend_override.tf` con este contenido y ejecutar `terraform init`:

```hcl
terraform {
  backend "local" {}
}
```

---

## 3. Despliegue

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars      # completar valores
export TF_VAR_iap_oauth_client_secret="GOCSPX-..." # solo con cliente OAuth propio

terraform init -backend-config="bucket=$BUCKET"
terraform plan -out tfplan                        # revisar: "Plan: N to add, 0 to change, 0 to destroy"
terraform apply tfplan
```

> Si el primer `apply` falla con *"API ... has not been used in project"*, las APIs recién habilitadas todavía se están propagando: esperar 1 o 2 minutos y volver a ejecutar `terraform apply`.

### 3.1 Sandbox o entorno de práctica (por ejemplo, playground de A Cloud Guru)

- **Región:** `region = "us-central1"` y `zone = "us-central1-a"`.
- **Cuotas:** si hay errores de cuota o de política con la VM, usar `machine_type = "e2-standard-2"`.
- **Sin organización:** se necesita el cliente OAuth propio (Externo). Ver la sección 7 bis.
- **Duración:** el sandbox expira en pocas horas y se borra todo. Sirve para validar el despliegue, no para uso continuo.

### 3.2 Después del `apply`

Al terminar:

1. **DNS:** crear el registro de `terraform output dns_record`.
2. **Instalación en la VM** (~10 minutos la primera vez): seguir el progreso con el comando de `terraform output startup_log_command`. Termina con `DefectDojo 3.5.103 levantado (SSO=true)`.
3. **Certificado:** queda `ACTIVE` entre 15 y 60 minutos después de crear el DNS.
4. **Verificar:** `./scripts/verify.sh` desde la raíz del repositorio.
5. **Probar** con una cuenta del grupo: tiene que entrar directo a DefectDojo, con el usuario creado a partir de su email.

> Si es la primera vez que se usa IAP en el proyecto y la consola lo pide, configurar la **pantalla de consentimiento OAuth** como **Internal** (solo cuentas del Workspace).

---

## 4. Cómo funciona la configuración de la VM

El script de arranque (`files/startup.sh.tftpl`) se ejecuta **en cada boot** y es idempotente:

1. Instala Docker desde el repositorio oficial. Configura los logs de contenedores hacia **Cloud Logging** (driver `gcplogs`).
2. Clona `django-DefectDojo` en el tag de `defectdojo_version`, o hace checkout del nuevo tag si cambió.
3. Lee los secretos de Secret Manager y escribe `.env` con permisos `600`: contraseña de la BD, `DD_SECRET_KEY`, clave AES y contraseña de `admin`.
4. Copia `iap_sso.py` y `local_settings.py` (que viajan en la metadata de la VM) a `docker/extra_settings/`. DefectDojo los carga sin modificar su código.
5. Lee el **audience de IAP** desde la metadata del proyecto (lo publica Terraform) y escribe `docker-compose.override.yml`. Ese archivo define:
   - el dominio, `CSRF_TRUSTED_ORIGINS`, cookies seguras y el header de HTTPS del proxy;
   - las variables `DD_IAP_*` del middleware;
   - `restart: unless-stopped` en todos los servicios.
6. `docker compose pull && docker compose up -d`.

Para reaplicar la configuración sin reiniciar la VM:

```bash
gcloud compute ssh dojo-vm --zone <ZONA> --tunnel-through-iap -- sudo google_metadata_script_runner startup
```

---

## 5. Operación

### Altas y bajas
- **Alta:** agregar a la persona a `dojo-users@…`. En su primer ingreso se crea su usuario en DefectDojo, sin productos. Los productos se asignan en DefectDojo; superuser (y staff, si se usa `staff_group`), con la fase 3.
- **Baja:** quitarla del grupo. Pierde el acceso en minutos. Opcionalmente, desactivar su usuario en DefectDojo.

### Actualizar DefectDojo
1. Revisar las notas de la versión nueva (migraciones, cambios incompatibles).
2. Cambiar `defectdojo_version` en `terraform.tfvars` y ejecutar `terraform apply` (actualiza la metadata, no recrea la VM).
3. Reaplicar con `google_metadata_script_runner startup` (ver arriba). El snapshot diario sirve de punto de restauración; para más seguridad, tomar uno manual antes.
4. Probar el login: el middleware depende del nombre de `AuthenticationMiddleware` en `MIDDLEWARE` y de la ruta `/logout`.

### Acceso de emergencia
Si IAP o Google no están disponibles, un miembro de `dojo-admins` entra con el usuario `admin` local:

```bash
$(terraform output -raw admin_password_command)      # contraseña
$(terraform output -raw break_glass_command)         # túnel; luego http://localhost:8080/login
```

### Logs útiles
```bash
# Accesos permitidos/denegados por IAP
gcloud logging read 'protoPayload.serviceName="iap.googleapis.com"' --limit 20
# Logins del middleware
gcloud logging read 'resource.type="gce_instance" AND jsonPayload.message:"Login SSO"' --limit 20
```

---

## 6. Migrar datos desde un DefectDojo existente

```bash
# En el servidor actual
docker compose exec -T postgres pg_dump -U defectdojo -Fc defectdojo > defectdojo.dump
# Nombre del volumen de adjuntos en el servidor actual: docker volume ls | grep media
docker run --rm -v <VOLUMEN_MEDIA_ACTUAL>:/m -v "$PWD":/b alpine tar czf /b/media.tgz -C /m .

# Copiar a la VM nueva (vía IAP)
gcloud compute scp defectdojo.dump media.tgz dojo-vm:/tmp/ --zone <ZONA> --tunnel-through-iap

# En la VM nueva
cd /opt/defectdojo
sudo docker compose stop uwsgi celeryworker celerybeat nginx
sudo docker compose exec -T postgres pg_restore -U defectdojo -d defectdojo --clean --if-exists --no-owner < /tmp/defectdojo.dump
sudo docker run --rm -v defectdojo_defectdojo_media:/m -v /tmp:/b alpine tar xzf /b/media.tgz -C /m
sudo docker compose up -d
```

> El `DD_SECRET_KEY` y el `DD_CREDENTIAL_AES_256_KEY` de origen se necesitan si había credenciales cifradas en la BD. En ese caso, cargarlos como nueva versión de los secretos `dojo-secret-key` y `dojo-aes-key` antes de restaurar.

---

## 7. Fase 3

### Roles por grupo (`enable_group_sync = true`)
1. `terraform output vm_service_account` → copiar el email.
2. En la consola de **Google Workspace**: *Cuenta → Roles de administrador → Lector de grupos (Groups Reader) → Asignar a cuentas de servicio* → pegar el email. Este paso no se puede hacer desde Terraform.
3. `enable_group_sync = true` → `terraform apply` → reaplicar el arranque.

`admins_group` pasa a dar superuser y, si lo definís, `staff_group` da staff. **Ojo:** en DefectDojo 3.x, staff y superuser ven **todos** los productos. Por eso `users_group` no da staff: los usuarios comunes ven solo los productos que se les asignan. **Workspace es la fuente de verdad** para esos dos permisos: un cambio manual se pisa en la próxima sincronización, cada 15 minutos. Solo se considera la membresía directa.

### Acceso por dominio en lugar de grupo (`iap_access_mode`)
- `"group"` (default): solo entran los miembros de `users_group` y `admins_group`.
- `"domain"`: entra cualquier cuenta de Google de `workspace_domain`, sin mantener un grupo. En ambos modos el middleware rechaza emails de otros dominios.

### Dispositivos administrados (`access_level`, opcional)
Crear el nivel de acceso en Access Context Manager (requiere permisos de organización; ver la fase 3 de la guía anterior) y cargar su nombre completo:

```hcl
access_level = "accessPolicies/123456789/accessLevels/dispositivo_corp"
```

Los equipos necesitan Endpoint Verification. Algunos atributos requieren Chrome Enterprise Premium. Conviene probarlo primero con un grupo piloto.

### SIEM (`enable_siem_export = true`)
Crea el tópico, el log sink y la suscripción `terraform output siem_subscription`, que consume el SIEM. Incluye los accesos de IAP y los logs del middleware.

---

## 7 bis. Google Groups gratuitos (@googlegroups.com) y cuentas @gmail.com

Si los grupos se crearon en groups.google.com (`…@googlegroups.com`) o los usuarios son cuentas personales de Gmail:

1. **Cliente OAuth propio.** El cliente administrado por Google solo admite usuarios de la organización.
   - En la consola: **Google Auth Platform → Público (Audience)** → tipo **Externo**.
     - En modo *Prueba* hay que cargar los usuarios de prueba (máximo 100).
     - En *Producción* aparece el aviso de "app no verificada" hasta que Google la verifique.
   - **Clientes → Crear cliente → Aplicación web.** Primero crealo y copiá el *Client ID*. Después editalo y agregá esta URI de redirección autorizada: `https://iap.googleapis.com/v1/oauth/clientIds/<CLIENT_ID>:handleRedirect`.
   - Pasá el ID y el secreto en `iap_oauth_client_id` y `iap_oauth_client_secret`. El secreto conviene pasarlo con `export TF_VAR_iap_oauth_client_secret=...`.
2. **Grupos:** usar el email real del grupo (`dojo-users-devcode@googlegroups.com`), no el nombre visible.
3. **Dominio del SSO:**
   - `sso_allowed_domains = ["gmail.com"]` acepta solo cuentas Gmail.
   - `[]` (con `workspace_domain = ""`) no filtra por dominio. IAP sigue filtrando por grupo.
4. **Fase 3 no disponible:** la API de grupos de Cloud Identity no lee grupos `@googlegroups.com`. Dejar `enable_group_sync = false` y asignar superuser a mano.
5. **Políticas de la organización:** si el proyecto tiene la restricción de dominios en IAM (*Domain restricted sharing*), va a rechazar los grupos `@googlegroups.com`.
6. **Membresía:** en la configuración de cada grupo, que solo los propietarios puedan agregar miembros. Cualquiera que entre al grupo pasa IAP.

---

## 8. Seguridad: decisiones y advertencias

- **Estado de Terraform:** contiene las contraseñas generadas. Bucket con acceso restringido y versionado.
- **Usuario `admin`:** está reservado. Nadie puede entrar como `admin` por SSO, y solo se usa por el túnel de emergencia.
- **Registry de imágenes:** `docker.io` por defecto. El registry de DefectDojo (`registry.defectdojo.com`) registra cada descarga. Docker Hub tiene límites de descargas anónimas.
- **`deletion_protection`:** está activo en la VM y el disco tiene `auto_delete = false`. Un `terraform destroy` no borra los datos por accidente.
- **API (`ci_source_ranges`):**
  - Sin IPs, `/api/v2` queda detrás de IAP y el CI tiene que autenticarse en IAP con una service account.
  - Con IPs, la API se publica sin IAP pero solo para esas IPs, y siempre con el token de DefectDojo.

---

## 9. Problemas frecuentes

| Síntoma | Causa | Solución |
|---|---|---|
| `502` | Backend no saludable | Log de arranque; `docker compose ps` en la VM |
| Arranque detenido en "Esperando el audience" | Falta la metadata del proyecto | `terraform apply` completo; luego reaplicar el arranque |
| Entra pero muestra el login de DefectDojo | SSO desactivado o audience incorrecto | `grep SSO /var/log/dojo-startup.log`; buscar `JWT de IAP inválido` en los logs |
| `403` de IAP para alguien del grupo | Membresía nueva o grupo anidado | Esperar unos minutos; agregarlo directo al grupo |
| Certificado en `PROVISIONING` | DNS no apunta a la IP | `dig <dominio>` |
| Roles no cambian (fase 3) | Falta el rol Groups Reader | Buscar `No se pudieron consultar los grupos` en los logs |
| `Group ... does not exist` al aplicar | El email del grupo está mal escrito (por ejemplo, `@dominio` en lugar de `@googlegroups.com`) | Copiar el email exacto desde groups.google.com |
| `constraints/gcp.resourceLocations violated ... [global]` | La organización solo permite ciertas regiones | Los secretos son **regionales** (en `region`); si otro recurso falla, revisar las ubicaciones permitidas con el administrador |

---

## 10. Estructura

```
dojo-iap-iac/
├── README.md
├── .gitignore
├── scripts/
│   └── verify.sh
└── terraform/
    ├── versions.tf  variables.tf  terraform.tfvars.example
    ├── apis.tf  network.tf  iam.tf  secrets.tf
    ├── vm.tf  lb.tf  iap.tf  ops.tf  outputs.tf
    └── files/
        ├── startup.sh.tftpl
        ├── iap_sso.py
        └── local_settings.py
```
