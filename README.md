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
15. [Próximos pasos](#próximos-pasos)

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
- ⚠️ Después de pasar IAP, cada persona **igual inicia sesión en DefectDojo** con su usuario local (doble login). Para eliminarlo, ver [Próximos pasos](#próximos-pasos).

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

## Próximos pasos

1. **Un solo login (SSO real):** un middleware de Django, cargado desde `docker/extra_settings/local_settings.py`, que valide el JWT firmado por IAP (`x-goog-iap-jwt-assertion`) y cree la sesión de DefectDojo con el email del usuario. La imagen de DefectDojo ya incluye `PyJWT` y `cryptography`, así que no requiere dependencias nuevas.
2. **Roles por grupo:** mapear grupos de Workspace (por ejemplo `dojo-admins`) a superuser o staff consultando la Cloud Identity Groups API.
3. **Acceso solo desde dispositivos administrados**, con Access Context Manager.
4. **Infraestructura como código:** pasar estos pasos a Terraform para recrear el entorno de forma reproducible.
5. **Backups:** snapshots programados del disco de la VM, o migrar PostgreSQL a Cloud SQL.
