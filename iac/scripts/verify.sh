#!/usr/bin/env bash
# Verificación posterior al despliegue. Uso: ./scripts/verify.sh  (desde la raíz del repo)
set -uo pipefail

cd "$(dirname "$0")/../terraform" || exit 1
TF=${TF:-terraform}

URL=$($TF output -raw url)
CERT_CMD=$($TF output -raw certificate_status_command)
PROJECT=$(sed -n 's/^project_id *= *"\(.*\)"/\1/p' terraform.tfvars)
NAME=$(sed -n 's/^name *= *"\(.*\)"/\1/p' terraform.tfvars); NAME=${NAME:-dojo}

ok()   { printf '  \033[32m✔\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✘\033[0m %s\n' "$1"; FAILED=1; }
FAILED=0

echo "1. Certificado administrado"
STATUS=$(eval "$CERT_CMD" 2>/dev/null | awk '{print $1}')
[ "$STATUS" = "ACTIVE" ] && ok "Certificado ACTIVE" || fail "Certificado en estado '$STATUS' (puede tardar hasta 60 min tras crear el DNS)"

echo "2. Salud del backend"
HEALTH=$(gcloud compute backend-services get-health "$NAME-backend" --global --project "$PROJECT" \
  --format='value(status.healthStatus[0].healthState)' 2>/dev/null)
[ "$HEALTH" = "HEALTHY" ] && ok "Backend HEALTHY" || fail "Backend '$HEALTH' (ver el log de arranque: terraform output startup_log_command)"

echo "3. IAP protege el sitio"
LOCATION=$(curl -s -o /dev/null -w '%{redirect_url}' "$URL/")
case "$LOCATION" in
  *accounts.google.com*) ok "Sin sesión redirige al login de Google" ;;
  *) fail "Se esperaba redirección a accounts.google.com y se obtuvo: '$LOCATION'" ;;
esac

echo "4. HTTP redirige a HTTPS"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://${URL#https://}/")
[ "$CODE" = "301" ] && ok "HTTP → HTTPS (301)" || fail "HTTP devolvió $CODE"

echo "5. La API sin IAP solo responde al CI/CD"
API_CODE=$(curl -s -o /dev/null -w '%{http_code}' "$URL/api/v2/")
case "$API_CODE" in
  403) ok "/api/v2 bloqueada desde esta IP (Cloud Armor)" ;;
  302) ok "/api/v2 detrás de IAP (ci_source_ranges vacío)" ;;
  401) ok "/api/v2 accesible desde esta IP: pide token de DefectDojo (¿esta IP está en ci_source_ranges?)" ;;
  *)   fail "/api/v2 devolvió $API_CODE" ;;
esac

echo
[ $FAILED -eq 0 ] && echo "Todo OK. Probá ahora el ingreso con una cuenta del grupo." || { echo "Hay verificaciones fallidas."; exit 1; }
