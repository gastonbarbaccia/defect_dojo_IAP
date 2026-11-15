# DefectDojo detrás de Identity-Aware Proxy (IAP) en Google Cloud

Guía paso a paso para publicar **DefectDojo 3.x (open source)** con acceso controlado por **cuentas de Google Workspace y grupos**, usando un **HTTPS Load Balancer + Identity-Aware Proxy** delante de la VM donde corre DefectDojo.

> **Por qué:** a partir de la versión 3.x, DefectDojo open source solo incluye login local (usuario y contraseña); el SSO quedó en la edición Pro. IAP agrega por delante la autenticación corporativa y el control por grupo **sin modificar el código de DefectDojo**.

---

## Índice

1. [Arquitectura](#arquitectura)
2. [Requisitos previos](#requisitos-previos)
3. [Paso 0: Variables](#paso-0-variables)
4. [Paso 1: Configurar DefectDojo para estar detrás del LB](#paso-1-configurar-defectdojo-para-estar-detrás-del-lb)
5. [Paso 2: Quitar la IP pública y dar salida por Cloud NAT](#paso-2-quitar-la-ip-pública-y-dar-salida-por-cloud-nat)
6. [Paso 3: Firewall: solo el LB llega a DefectDojo](#paso-3-firewall-solo-el-lb-llega-a-defectdojo)
7. [Paso 4: Grupo de instancias y health check](#paso-4-grupo-de-instancias-y-health-check)
8. [Paso 5: Backend service y Load Balancer HTTPS](#paso-5-backend-service-y-load-balancer-https)
9. [Paso 6: Activar IAP y dar acceso al grupo](#paso-6-activar-iap-y-dar-acceso-al-grupo)
10. [Paso 7: Verificación](#paso-7-verificación)
11. [Paso 8 (opcional): API para CI/CD](#paso-8-opcional-api-para-cicd)
12. [Operación: altas, bajas y auditoría](#operación-altas-bajas-y-auditoría)
13. [Problemas frecuentes](#problemas-frecuentes)
14. [Rollback](#rollback)
15. [Fase 2 · Siguiente: un solo login (SSO con el JWT de IAP)](#fase-2--siguiente-un-solo-login-sso-con-el-jwt-de-iap)
16. [Fase 3 · Después: evolución](#fase-3--después-evolución)
17. [Estructura de archivos](#estructura-de-archivos)

---

## Arquitectura

```
                       ┌──────────────────────── Proyecto GCP ────────────────────────┐
Usuario (Workspace) ──►│ HTTPS Load Balancer ──► IAP ──► Backend service ──► VM        │
                       │   (cert administrado)   (login Google   (dojo-backend)  DefectDojo│
                       │                          + grupo)                     (sin IP   │
                       │                                                        pública) │
CI/CD ────────────────►│ /api/v2/*  ──► Cloud Armor (IPs del CI) ──► dojo-api-backend ─┘ │
                       │                                                                │
                       │ VM ──► Cloud NAT (solo salida)     Admin ──► SSH vía IAP       │
                       └────────────────────────────────────────────────────────────────┘
```

| Componente | Función |
|---|---|
| HTTPS Load Balancer (global, `EXTERNAL_MANAGED`) | Publica `https://dojo.empresa.com` con certificado administrado por Google |
| Identity-Aware Proxy | Login con cuentas de Google Workspace; solo deja pasar a miembros del grupo autorizado |
| VM con DefectDojo | `docker compose` oficial (nginx, uwsgi, celery, PostgreSQL, Valkey/Redis), **sin IP pública** |
| Firewall | El puerto 8080 solo acepta tráfico de los rangos del LB de Google |
| Cloud NAT | Salida a internet para la VM (imágenes, actualizaciones), sin exponerla |
| Cloud Armor (opcional) | Restringe `/api/v2/*` a las IPs del CI/CD |
| SSH por IAP | Administración de la VM sin abrir el puerto 22 a internet |

**Qué resuelve y qué no:**

- ✅ Solo acceden cuentas corporativas que estén en el grupo autorizado (con MFA de Workspace).
- ✅ DefectDojo deja de estar expuesto directamente a internet.
- ✅ No se modifica DefectDojo: las actualizaciones siguen el proceso oficial.
- ⚠️ En la fase 1, después de pasar IAP cada persona **igual inicia sesión en DefectDojo** con su usuario local (doble login). La [fase 2](#fase-2--siguiente-un-solo-login-sso-con-el-jwt-de-iap) lo elimina.

---

## Requisitos previos

- Proyecto de GCP dentro de la organización de Google Workspace, con facturación habilitada.
- DefectDojo corriendo en una VM de Compute Engine con el `docker-compose.yml` oficial, publicando nginx en el puerto **8080**.
- Un dominio (por ejemplo `dojo.empresa.com`) en el que puedas crear un registro DNS **A**.
- Un grupo de Google Workspace para los usuarios (por ejemplo `dojo-users@empresa.com`).
- Permisos para la persona que ejecuta los comandos: `roles/compute.admin`, `roles/iap.admin` y `roles/iam.securityAdmin` (o equivalentes).
- `gcloud` instalado y autenticado (`gcloud auth login`).

---

## Paso 0: Variables

```bash
PROJECT_ID=mi-proyecto
REGION=southamerica-east1
ZONE=southamerica-east1-a
VM=defectdojo-vm
NETWORK=default
DOMAIN=dojo.empresa.com
GROUP=dojo-users@empresa.com

gcloud config set project $PROJECT_ID
gcloud services enable compute.googleapis.com iap.googleapis.com
```

---

## Paso 1: Configurar DefectDojo para estar detrás del LB

En la VM, en el `.env` o en un `docker-compose.override.yml` (servicio `uwsgi`):

```env
DD_SITE_URL=https://dojo.empresa.com
DD_ALLOWED_HOSTS=dojo.empresa.com
DD_CSRF_TRUSTED_ORIGINS=https://dojo.empresa.com
DD_SECURE_PROXY_SSL_HEADER=True
DD_SESSION_COOKIE_SECURE=True
DD_CSRF_COOKIE_SECURE=True
```

Aplicar los cambios:

```bash
docker compose up -d
```

> `DD_SECURE_PROXY_SSL_HEADER=True` hace que Django confíe en el header `X-Forwarded-Proto: https` que envía el LB; sin esto aparecen redirecciones infinitas o errores de CSRF.

---

## Paso 2: Quitar la IP pública y dar salida por Cloud NAT

```bash
# 1) Ver el nombre del access config (suele ser "external-nat" o "External NAT")
gcloud compute instances describe $VM --zone $ZONE \
  --format='value(networkInterfaces[0].accessConfigs[0].name)'

# 2) Quitar la IP pública
gcloud compute instances delete-access-config $VM --zone $ZONE \
  --access-config-name="external-nat"

# 3) Salida a internet mediante Cloud NAT
gcloud compute routers create dojo-router --network $NETWORK --region $REGION
gcloud compute routers nats create dojo-nat --router dojo-router --region $REGION \
  --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges

# 4) SSH de administración vía IAP (no expone el puerto 22)
gcloud compute firewall-rules create allow-iap-ssh --network $NETWORK \
  --allow tcp:22 --source-ranges 35.235.240.0/20 --target-tags dojo
```

A partir de ahora, para entrar a la VM:

```bash
gcloud compute ssh $VM --zone $ZONE --tunnel-through-iap
```

---

## Paso 3: Firewall: solo el LB llega a DefectDojo

```bash
gcloud compute instances add-tags $VM --zone $ZONE --tags dojo

gcloud compute firewall-rules create allow-lb-to-dojo --network $NETWORK \
  --allow tcp:8080 --source-ranges 35.191.0.0/16,130.211.0.0/22 --target-tags dojo
```

Revisar que **no exista otra regla** que abra el 8080, el 80 o el 443 a `0.0.0.0/0`:

```bash
gcloud compute firewall-rules list --filter="network:$NETWORK" \
  --format="table(name,sourceRanges.list(),allowed[].map().firewall_rule().list(),targetTags.list())"
```

---

## Paso 4: Grupo de instancias y health check

```bash
gcloud compute instance-groups unmanaged create dojo-ig --zone $ZONE
gcloud compute instance-groups unmanaged add-instances dojo-ig --zone $ZONE --instances $VM
gcloud compute instance-groups set-named-ports dojo-ig --zone $ZONE --named-ports http:8080

gcloud compute health-checks create http dojo-hc --port 8080 \
  --request-path=/login --host=$DOMAIN
```

> El `--host` es necesario porque `DD_ALLOWED_HOSTS` solo acepta `dojo.empresa.com`; sin él, el health check recibe `400 Bad Request`.

---

## Paso 5: Backend service y Load Balancer HTTPS

```bash
# Backend service (timeout de 10 min para imports grandes de escaneos)
gcloud compute backend-services create dojo-backend --global \
  --load-balancing-scheme=EXTERNAL_MANAGED --protocol=HTTP --port-name=http \
  --health-checks=dojo-hc --timeout=600
gcloud compute backend-services add-backend dojo-backend --global \
  --instance-group=dojo-ig --instance-group-zone=$ZONE

# IP estática global
gcloud compute addresses create dojo-ip --global
gcloud compute addresses describe dojo-ip --global --format='value(address)'
#  → Crear el registro DNS:  dojo.empresa.com  A  <IP>

# Certificado administrado, URL map, proxy HTTPS y forwarding rule
gcloud compute ssl-certificates create dojo-cert --domains=$DOMAIN --global
gcloud compute url-maps create dojo-urlmap --default-service=dojo-backend --global
gcloud compute target-https-proxies create dojo-https-proxy --global \
  --url-map=dojo-urlmap --ssl-certificates=dojo-cert
gcloud compute forwarding-rules create dojo-https --global \
  --load-balancing-scheme=EXTERNAL_MANAGED --address=dojo-ip \
  --target-https-proxy=dojo-https-proxy --ports=443
```

El certificado tarda **entre 15 y 60 minutos** en quedar `ACTIVE` una vez que el DNS apunta a la IP:

```bash
gcloud compute ssl-certificates describe dojo-cert --global \
  --format='value(managed.status, managed.domainStatus)'
```

**Opcional: redirigir HTTP a HTTPS**

```bash
gcloud compute url-maps import dojo-http-redirect --global --source /dev/stdin <<EOF
name: dojo-http-redirect
defaultUrlRedirect:
  httpsRedirect: true
  redirectResponseCode: MOVED_PERMANENTLY_DEFAULT
EOF
gcloud compute target-http-proxies create dojo-http-proxy --global --url-map=dojo-http-redirect
gcloud compute forwarding-rules create dojo-http --global \
  --load-balancing-scheme=EXTERNAL_MANAGED --address=dojo-ip \
  --target-http-proxy=dojo-http-proxy --ports=80
```

---

## Paso 6: Activar IAP y dar acceso al grupo

```bash
gcloud compute backend-services update dojo-backend --global --iap=enabled

gcloud iap web add-iam-policy-binding \
  --resource-type=backend-services --service=dojo-backend \
  --member=group:$GROUP --role=roles/iap.httpsResourceAccessor
```

- Si es la primera vez que se usa IAP en el proyecto, la consola puede pedir configurar la **pantalla de consentimiento OAuth**: elegir tipo **Internal**, así solo pueden entrar cuentas del Workspace.
- Para un grupo adicional (por ejemplo administradores), repetir el `add-iam-policy-binding` con ese grupo.
- **Opcional:** con *Access Context Manager* se pueden exigir condiciones adicionales (red corporativa, país, dispositivo administrado). Algunas condiciones de dispositivo requieren licencia de Chrome Enterprise.

---

## Paso 7: Verificación

| # | Prueba | Resultado esperado |
|---|---|---|
| 1 | Abrir `https://dojo.empresa.com` en una ventana privada | Pide iniciar sesión con Google |
| 2 | Ingresar con un miembro del grupo | Aparece el login de DefectDojo |
| 3 | Ingresar con una cuenta corporativa que **no** esté en el grupo | Error 403 de IAP |
| 4 | Ingresar con una cuenta personal (`@gmail.com`) | Bloqueado (consentimiento *Internal*) |
| 5 | `curl -I http://<IP_INTERNA_VM>:8080` desde fuera de la VPC | Sin respuesta (la VM no tiene IP pública) |
| 6 | Estado del backend: `gcloud compute backend-services get-health dojo-backend --global` | `HEALTHY` |

---

## Paso 8 (opcional): API para CI/CD

IAP también protege `/api/v2`, por lo que los pipelines que suben escaneos quedan bloqueados. La opción más simple es enviar esa ruta a un backend **sin IAP**, restringido por **Cloud Armor** a las IPs del CI. La API sigue requiriendo el token de DefectDojo.

```bash
# Backend para la API (misma VM, sin IAP)
gcloud compute backend-services create dojo-api-backend --global \
  --load-balancing-scheme=EXTERNAL_MANAGED --protocol=HTTP --port-name=http \
  --health-checks=dojo-hc --timeout=600
gcloud compute backend-services add-backend dojo-api-backend --global \
  --instance-group=dojo-ig --instance-group-zone=$ZONE

# Cloud Armor: permitir solo las IPs del CI, denegar el resto
gcloud compute security-policies create dojo-api-policy
gcloud compute security-policies rules create 1000 --security-policy dojo-api-policy \
  --src-ip-ranges="<IP_CI_1>,<IP_CI_2>" --action allow
gcloud compute security-policies rules update 2147483647 \
  --security-policy dojo-api-policy --action deny-403
gcloud compute backend-services update dojo-api-backend --global \
  --security-policy dojo-api-policy

# Ruta /api/v2/* hacia el backend de la API
gcloud compute url-maps add-path-matcher dojo-urlmap --global \
  --path-matcher-name=api --default-service=dojo-backend \
  --path-rules="/api/v2/*=dojo-api-backend" --new-hosts=$DOMAIN
```

Prueba desde el CI:

```bash
curl -s -H "Authorization: Token <TOKEN_DD>" https://dojo.empresa.com/api/v2/users/ | head
```

> Si el CI no tiene IPs fijas (por ejemplo, runners compartidos de GitHub), la alternativa es pasar por IAP con una **service account** con `roles/iap.httpsResourceAccessor`, enviando su ID token en el header `Proxy-Authorization: Bearer ...` y dejando `Authorization: Token ...` para DefectDojo.

> Si se usan **webhooks de Jira**, agregar también su ruta (`/jira/webhook/*`) al path matcher con la misma lógica.

---

## Operación: altas, bajas y auditoría

**Alta de una persona**

1. Agregarla al grupo `dojo-users@empresa.com` en la consola de administración de Workspace.
2. Crear su usuario en DefectDojo (sección de usuarios, como superuser) con el **mismo email** y asignarle los productos o el rol que corresponda.

**Baja**

1. Quitarla del grupo: pierde el acceso en minutos, aunque siga teniendo usuario en DefectDojo.
2. Desactivar su usuario en DefectDojo, para mantener el inventario limpio.

**Auditoría de accesos**

Habilitar los *Data Access audit logs* de IAP (IAM → Audit Logs → *Cloud Identity-Aware Proxy* → *Data Read*) y consultar:

```bash
gcloud logging read 'protoPayload.serviceName="iap.googleapis.com"' --limit 20 \
  --format='table(timestamp, protoPayload.authenticationInfo.principalEmail, protoPayload.authorizationInfo[0].granted)'
```

Estos logs se pueden enviar al SIEM con un *log sink*.

---

## Problemas frecuentes

| Síntoma | Causa probable | Solución |
|---|---|---|
| `502` del LB | Health check fallando | `get-health`; revisar la regla de firewall del paso 3 y el `--host` del health check |
| Health check `UNHEALTHY` con `400` | `DD_ALLOWED_HOSTS` no incluye el host del health check | Usar `--host=$DOMAIN` (paso 4) |
| Certificado en `PROVISIONING` mucho tiempo | DNS no apunta a la IP del LB | Verificar con `dig dojo.empresa.com` |
| Redirecciones infinitas o error CSRF al loguear | Django no sabe que está detrás de HTTPS | `DD_SECURE_PROXY_SSL_HEADER=True` y `DD_CSRF_TRUSTED_ORIGINS` (paso 1) |
| `403` de IAP para alguien del grupo | Membresía recién agregada o grupo anidado | Esperar unos minutos; probar con el usuario directo en el grupo |
| Imports grandes cortados | Timeout del backend | `--timeout=600` o más en el backend service |
| La VM no descarga imágenes | Falta Cloud NAT | Paso 2, punto 3 |

---

## Rollback

Para volver al estado anterior sin perder datos (DefectDojo no se modificó):

```bash
gcloud compute backend-services update dojo-backend --global --iap=disabled
gcloud compute forwarding-rules delete dojo-https --global -q
gcloud compute target-https-proxies delete dojo-https-proxy --global -q
gcloud compute url-maps delete dojo-urlmap --global -q
gcloud compute backend-services delete dojo-backend --global -q
gcloud compute ssl-certificates delete dojo-cert --global -q
gcloud compute addresses delete dojo-ip --global -q
# Si hace falta, devolver la IP pública a la VM:
gcloud compute instances add-access-config $VM --zone $ZONE --access-config-name="external-nat"
```

---


## Fase 2 · Siguiente: un solo login (SSO con el JWT de IAP)

**Objetivo:** que la persona inicie sesión **una sola vez**, con Google, y entre directo a DefectDojo, sin la contraseña local.

### 2.1 Cómo funciona

```
Navegador ──► LB + IAP ──(x-goog-iap-jwt-assertion: JWT firmado por Google)──► nginx ──► uwsgi (DefectDojo)
                                                                                         │
                                                       IAPSSOMiddleware (iap_sso.py) ────┘
                                                       1. Verifica firma ES256 con las claves públicas de IAP
                                                       2. Verifica issuer, audience y expiración
                                                       3. Busca el usuario por email (o lo crea)
                                                       4. Inicia la sesión de Django
```

- La identidad sale **solo del JWT firmado**: un header inventado no sirve, porque la firma no valida (lo probamos con firmas falsas, audiencia incorrecta, token vencido y dominio ajeno).
- Se usa únicamente lo que ya trae la imagen de DefectDojo (`PyJWT`, `cryptography`, `requests`). **No se modifica el código de DefectDojo.**
- `/api/` se ignora: la API sigue usando su token.
- El botón **Logout** cierra la sesión de DefectDojo y la cookie de IAP (`/_gcp_iap/clear_login_cookie`).
- El usuario `admin` está reservado: nadie puede entrar como `admin` vía SSO.

### 2.2 Obtener el *audience* de IAP

```bash
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')
BACKEND_ID=$(gcloud compute backend-services describe dojo-backend --global --format='value(id)')
echo "/projects/$PROJECT_NUMBER/global/backendServices/$BACKEND_ID"
```

### 2.3 Copiar los archivos en la VM

El `docker-compose.yml` oficial ya monta `./docker/extra_settings`; al arrancar, DefectDojo copia su contenido a `dojo/settings/` y carga `local_settings.py`.

```
django-DefectDojo/
└── docker/
    └── extra_settings/
        ├── local_settings.py   # inserta el middleware
        └── iap_sso.py          # valida el JWT de IAP y crea la sesión
```

> Si ya tenés un `local_settings.py`, agregá su contenido al final del tuyo.

### 2.4 Variables de entorno

En `docker-compose.override.yml` (servicios `uwsgi`, `celeryworker` y `celerybeat`):

```yaml
services:
  uwsgi:
    environment:
      DD_IAP_SSO_ENABLED: "true"
      DD_IAP_AUDIENCE: "/projects/123456789012/global/backendServices/1234567890123456789"
      DD_IAP_ALLOWED_DOMAINS: "empresa.com"
      DD_IAP_CREATE_USERS: "true"          # crea el usuario en su primer ingreso
      DD_IAP_DENY_USERNAMES: "admin"
      # Acceso de emergencia por túnel SSH (ver 2.7)
      DD_ALLOWED_HOSTS: "dojo.empresa.com,localhost"
      DD_CSRF_TRUSTED_ORIGINS: "https://dojo.empresa.com,http://localhost:8080"
```

```bash
docker compose up -d
docker compose logs uwsgi | grep -i "extra_settings\|local_settings"
```

### 2.5 Usuarios existentes

El middleware vincula por **email**: los usuarios creados a mano en la fase 1 se reutilizan, con sus productos y permisos. Antes de activar, revisar que no haya emails duplicados (si los hay, el SSO no inicia sesión para ese email y lo deja en el log):

```bash
docker compose exec uwsgi python manage.py shell -c "
from django.contrib.auth import get_user_model
from django.db.models import Count
from django.db.models.functions import Lower
U = get_user_model()
print(list(U.objects.annotate(e=Lower('email')).values('e').annotate(n=Count('id')).filter(n__gt=1)))"
```

Los usuarios nuevos se crean con `username` = email, **sin contraseña** y sin productos: hay que asignarles los productos (o usar la fase 3 para staff/superuser).

### 2.6 Verificación

| # | Prueba | Resultado esperado |
|---|---|---|
| 1 | Entrar a `https://dojo.empresa.com` con un miembro del grupo | Entra directo, sin pantalla de login de DefectDojo |
| 2 | Primer ingreso de alguien sin usuario en DefectDojo | Se crea su usuario con su email |
| 3 | Botón **Logout** | Vuelve a pedir la cuenta de Google |
| 4 | Desde la VM: `curl -s -o /dev/null -w '%{redirect_url}\n' -H 'x-goog-iap-jwt-assertion: falso' http://localhost:8080/` | Redirige a `/login` (no inicia sesión) |
| 5 | API con token | Sigue funcionando igual |
| 6 | `docker compose logs uwsgi \| grep "Login SSO"` | Una línea por cada inicio de sesión |

### 2.7 Acceso de emergencia (break-glass)

Si IAP o Google no están disponibles, un administrador entra con el usuario `admin` local por túnel SSH, sin pasar por el LB (sin header de IAP no hay SSO y funciona el login normal):

```bash
gcloud compute ssh $VM --zone $ZONE --tunnel-through-iap -- -L 8080:localhost:8080
# Abrir http://localhost:8080/login
```

### 2.8 Logs de IAP al SIEM

```bash
# Tópico de Pub/Sub que consume el SIEM
gcloud pubsub topics create iap-dojo-logs

gcloud logging sinks create iap-dojo-to-siem \
  pubsub.googleapis.com/projects/$PROJECT_ID/topics/iap-dojo-logs \
  --log-filter='protoPayload.serviceName="iap.googleapis.com"'

# Dar permiso de publicación a la identidad del sink
SINK_SA=$(gcloud logging sinks describe iap-dojo-to-siem --format='value(writerIdentity)')
gcloud pubsub topics add-iam-policy-binding iap-dojo-logs --member="$SINK_SA" --role=roles/pubsub.publisher
```

Recordar habilitar los *Data Access audit logs* de IAP (ver [Operación](#operación-altas-bajas-y-auditoría)). Los logs de la aplicación (`Login SSO vía IAP`, `JWT de IAP inválido`) se pueden enviar con el Ops Agent de la VM.

### 2.9 Snapshots diarios del disco

```bash
gcloud compute resource-policies create snapshot-schedule dojo-daily \
  --region $REGION --start-time 06:00 --daily-schedule \
  --max-retention-days 14 --on-source-disk-delete keep-auto-snapshots

DISK=$(gcloud compute instances describe $VM --zone $ZONE --format='value(disks[0].source.basename())')
gcloud compute disks add-resource-policies $DISK --zone $ZONE --resource-policies dojo-daily
```

> `--start-time` está en UTC (06:00 UTC = 03:00 en Argentina).

---

## Fase 3 · Después: evolución

### 3.1 Roles por grupo de Workspace (superuser y staff)

El JWT de IAP no incluye los grupos. El middleware puede consultarlos en la **Cloud Identity Groups API** con la service account de la VM y ajustar `is_superuser` / `is_staff`. Lo hace al iniciar sesión y cada 15 minutos (configurable).

1. Habilitar la API:
   ```bash
   gcloud services enable cloudidentity.googleapis.com
   ```
2. Darle a la VM una service account propia con el scope `cloud-platform` (requiere detener la VM):
   ```bash
   gcloud iam service-accounts create dojo-vm --display-name="DefectDojo VM"
   gcloud compute instances stop $VM --zone $ZONE
   gcloud compute instances set-service-account $VM --zone $ZONE \
     --service-account=dojo-vm@$PROJECT_ID.iam.gserviceaccount.com --scopes=cloud-platform
   gcloud compute instances start $VM --zone $ZONE
   ```
3. En la consola de administración de Google Workspace: **Cuenta → Roles de administrador → Lector de grupos (Groups Reader) → Asignar a cuentas de servicio** → `dojo-vm@PROJECT_ID.iam.gserviceaccount.com`.
4. Crear el grupo `dojo-admins@empresa.com` y darle también acceso en IAP (paso 6).
5. Variables de entorno adicionales:
   ```yaml
   DD_IAP_GROUP_SYNC_ENABLED: "true"
   DD_IAP_SUPERUSER_GROUP: "dojo-admins@empresa.com"
   DD_IAP_STAFF_GROUP: "dojo-users@empresa.com"
   DD_IAP_GROUPS_REFRESH_SECONDS: "900"
   ```

**Reglas:**

- Con esto activo, **Workspace es la fuente de verdad** de superuser y staff: un cambio manual en DefectDojo se pisa en la próxima sincronización.
- Se consulta la **membresía directa** (no se consideran grupos anidados).
- Si la API falla, se mantienen los roles actuales y queda un error en el log.
- Los permisos por producto siguen asignándose en DefectDojo.

### 3.2 Acceso solo desde dispositivos administrados

Con **Access Context Manager** se crea un nivel de acceso y se lo exige como condición en el rol de IAP.

```bash
POLICY=$(gcloud access-context-manager policies list --organization=<ORG_ID> --format='value(name)')

cat > dispositivo-corp.yaml <<'EOF'
- devicePolicy:
    requireScreenlock: true
    requireCorpOwned: true
    allowedEncryptionStatuses: [ENCRYPTED]
EOF

gcloud access-context-manager levels create dispositivo_corp \
  --policy=$POLICY --title="Dispositivo corporativo" --basic-level-spec=dispositivo-corp.yaml

# Reemplazar el binding sin condición por uno con condición
gcloud iap web remove-iam-policy-binding --resource-type=backend-services --service=dojo-backend \
  --member=group:$GROUP --role=roles/iap.httpsResourceAccessor
gcloud iap web add-iam-policy-binding --resource-type=backend-services --service=dojo-backend \
  --member=group:$GROUP --role=roles/iap.httpsResourceAccessor \
  --condition="expression=\"accessPolicies/$POLICY/accessLevels/dispositivo_corp\" in request.auth.access_levels,title=dispositivo-corp"
```

- Los equipos necesitan **Endpoint Verification** (extensión de Chrome) para reportar su estado.
- Algunos atributos de dispositivo requieren licencia de **Chrome Enterprise Premium**: validarlo con el equipo de Workspace.
- Probar primero con un grupo piloto antes de aplicarlo a todo el equipo.

### 3.3 Infraestructura como código (Terraform)

Pasar los recursos de las fases 1 a 3 a Terraform para poder recrear el entorno y revisar cambios por pull request. Estructura sugerida:

```
terraform/
├── main.tf          # provider, backend en GCS
├── network.tf       # firewall, Cloud Router, Cloud NAT
├── lb.tf            # IP, certificado, backend services, URL map, proxies, forwarding rules
├── iap.tf           # IAP en el backend y bindings por grupo / nivel de acceso
├── armor.tf         # política de Cloud Armor para /api/v2
├── ops.tf           # snapshots, log sink al SIEM
└── variables.tf
```

Las piezas clave de IAP:

```hcl
resource "google_compute_backend_service" "dojo" {
  name                  = "dojo-backend"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTP"
  port_name             = "http"
  timeout_sec           = 600
  health_checks         = [google_compute_health_check.dojo.id]
  backend { group = google_compute_instance_group.dojo.id }
  iap { enabled = true }
}

resource "google_iap_web_backend_service_iam_member" "dojo_users" {
  web_backend_service = google_compute_backend_service.dojo.name
  role                = "roles/iap.httpsResourceAccessor"
  member              = "group:dojo-users@empresa.com"
}
```

Los recursos ya creados con `gcloud` se incorporan con `terraform import` (o con bloques `import {}`), sin recrearlos.

### 3.4 Base de datos en Cloud SQL

Separa la base de la VM: backups automáticos, restauración a un momento anterior (PITR) y alta disponibilidad opcional.

```bash
# 1) Versión de PostgreSQL actual (usar la misma versión mayor en Cloud SQL)
docker compose exec postgres postgres --version

# 2) Instancia con IP privada en la VPC (requiere Private Service Access configurado)
gcloud sql instances create dojo-sql --region $REGION \
  --database-version=POSTGRES_<VERSION> --tier=db-custom-2-7680 \
  --network=$NETWORK --no-assign-ip \
  --backup-start-time=06:00 --enable-point-in-time-recovery
gcloud sql databases create defectdojo --instance dojo-sql
gcloud sql users create defectdojo --instance dojo-sql --password='<CONTRASEÑA_SEGURA>'

# 3) Ventana de mantenimiento: detener DefectDojo y exportar
docker compose stop uwsgi celeryworker celerybeat nginx
docker compose exec -T postgres pg_dump -U defectdojo -Fc defectdojo > defectdojo.dump

# 4) Importar en Cloud SQL (desde la VM, que llega por IP privada)
SQL_IP=$(gcloud sql instances describe dojo-sql --format='value(ipAddresses[0].ipAddress)')
pg_restore -h $SQL_IP -U defectdojo -d defectdojo --no-owner defectdojo.dump
```

5. En el `.env` de DefectDojo:
   ```env
   DD_DATABASE_HOST=<SQL_IP>
   DD_DATABASE_PORT=5432
   DD_DATABASE_URL=postgresql://defectdojo:<CONTRASEÑA>@<SQL_IP>:5432/defectdojo
   ```
6. `docker compose up -d` y validar. El contenedor `postgres` puede seguir levantado sin uso hasta confirmar la migración; recién después se elimina su volumen.

> La contraseña conviene guardarla en **Secret Manager** e inyectarla al iniciar, en lugar de dejarla en el `.env`.

---

## Estructura de archivos

```
dd-iap/
├── README.md
└── docker/
    └── extra_settings/          # copiar a django-DefectDojo/docker/extra_settings/
        ├── local_settings.py    # fase 2: activa el middleware
        └── iap_sso.py           # fase 2 y 3: SSO con JWT de IAP + roles por grupo
```
