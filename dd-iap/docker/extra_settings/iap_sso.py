"""
SSO para DefectDojo 3.x (open source) detrás de Google Cloud Identity-Aware Proxy.

Valida el JWT firmado por IAP (header x-goog-iap-jwt-assertion) y crea la sesión de
DefectDojo con el email de la persona. No modifica el código de DefectDojo: se carga
desde local_settings.py y se configura con variables de entorno DD_IAP_*.

Usa solo dependencias que ya trae la imagen de DefectDojo (PyJWT, cryptography, requests).

Fase 3 (opcional): sincroniza superuser/staff según grupos de Google Workspace
consultando la Cloud Identity Groups API con la service account de la VM.
"""

import logging
import os
import re
import time

import jwt
import requests
from django.conf import settings
from django.contrib import auth
from django.contrib.auth import get_user_model
from django.http import HttpResponseRedirect

logger = logging.getLogger("dojo.iap_sso")

IAP_ISSUER = "https://cloud.google.com/iap"
IAP_JWKS_URL = "https://www.gstatic.com/iap/verify/public_key-jwk"
IAP_HEADER = "HTTP_X_GOOG_IAP_JWT_ASSERTION"
IAP_LOGOUT_URL = "/_gcp_iap/clear_login_cookie"
LOGIN_BACKEND = "django.contrib.auth.backends.ModelBackend"


def _env(name, default=""):
    return os.environ.get(name, default).strip()


def _env_list(name, default=""):
    return [x.strip().lower() for x in _env(name, default).split(",") if x.strip()]


def _env_bool(name, default="false"):
    return _env(name, default).lower() in {"1", "true", "yes", "on"}


AUDIENCE = _env("DD_IAP_AUDIENCE")  # /projects/NUMERO/global/backendServices/ID
ALLOWED_DOMAINS = _env_list("DD_IAP_ALLOWED_DOMAINS")  # empresa.com
CREATE_USERS = _env_bool("DD_IAP_CREATE_USERS", "true")
DENY_USERNAMES = set(_env_list("DD_IAP_DENY_USERNAMES", "admin"))
LOGOUT_URL = _env("DD_IAP_LOGOUT_URL", IAP_LOGOUT_URL)

# Fase 3: roles por grupo
GROUP_SYNC = _env_bool("DD_IAP_GROUP_SYNC_ENABLED", "false")
SUPERUSER_GROUP = _env("DD_IAP_SUPERUSER_GROUP").lower()
STAFF_GROUP = _env("DD_IAP_STAFF_GROUP").lower()
GROUPS_REFRESH_SECONDS = int(_env("DD_IAP_GROUPS_REFRESH_SECONDS", "900"))

_prefix = re.escape(getattr(settings, "URL_PREFIX", "") or "")
IGNORED_PATHS = re.compile(rf"^{_prefix}(api/|static/|media/)")
LOGOUT_PATH = re.compile(rf"^{_prefix}logout$")

_jwks_client = jwt.PyJWKClient(IAP_JWKS_URL, cache_keys=True, lifespan=3600)


def verify_iap_jwt(token):
    """Devuelve los claims si el JWT es válido; si no, None."""
    if not AUDIENCE:
        logger.error("DD_IAP_AUDIENCE no está configurado: SSO deshabilitado.")
        return None
    try:
        key = _jwks_client.get_signing_key_from_jwt(token).key
        return jwt.decode(
            token,
            key,
            algorithms=["ES256"],
            audience=AUDIENCE,
            issuer=IAP_ISSUER,
            options={"require": ["exp", "iat", "aud", "iss", "email"]},
            leeway=30,
        )
    except Exception as exc:  # firma, audiencia, expiración, red...
        logger.warning("JWT de IAP inválido: %s", exc)
        return None


class IAPSSOMiddleware:

    """Va inmediatamente después de AuthenticationMiddleware."""

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        path = request.path_info.lstrip("/")

        if LOGOUT_PATH.match(path):
            # Cerrar DefectDojo y también la cookie de IAP; si no, se vuelve a entrar solo.
            auth.logout(request)
            return HttpResponseRedirect(LOGOUT_URL)

        if not IGNORED_PATHS.match(path):
            self._login_from_iap(request)

        return self.get_response(request)

    def _login_from_iap(self, request):
        token = request.META.get(IAP_HEADER)
        if not token:
            return
        claims = verify_iap_jwt(token)
        if not claims:
            if request.user.is_authenticated:
                auth.logout(request)
            return

        email = claims["email"].lower()
        if ALLOWED_DOMAINS and email.rsplit("@", 1)[-1] not in ALLOWED_DOMAINS:
            logger.warning("Dominio no permitido para SSO: %s", email)
            return

        user = request.user
        if not (user.is_authenticated and (user.email or "").lower() == email):
            user = self._get_or_create_user(email)
            if user is None:
                if request.user.is_authenticated:
                    auth.logout(request)
                return
            auth.login(request, user, backend=LOGIN_BACKEND)  # rota la sesión
            request.session["iap_groups_checked"] = 0
            logger.info("Login SSO vía IAP: %s", email)

        if GROUP_SYNC:
            self._sync_roles(request, user, email)

    @staticmethod
    def _get_or_create_user(email):
        user_model = get_user_model()
        matches = list(user_model.objects.filter(email__iexact=email)[:2])
        if len(matches) > 1:
            logger.error("Hay más de un usuario con el email %s; no se inicia sesión.", email)
            return None
        if matches:
            user = matches[0]
        elif CREATE_USERS:
            username = email
            if username.lower() in DENY_USERNAMES or user_model.objects.filter(username__iexact=username).exists():
                logger.error("No se puede crear el usuario %s: nombre reservado o existente.", username)
                return None
            user = user_model(username=username, email=email)
            user.set_unusable_password()
            user.save()
            logger.info("Usuario creado por SSO: %s", email)
        else:
            logger.warning("Usuario %s no existe en DefectDojo y la creación automática está deshabilitada.", email)
            return None

        if not user.is_active or user.get_username().lower() in DENY_USERNAMES:
            logger.warning("Login SSO rechazado para %s (inactivo o reservado).", email)
            return None
        return user

    @staticmethod
    def _sync_roles(request, user, email):
        last = request.session.get("iap_groups_checked", 0)
        if time.time() - last < GROUPS_REFRESH_SECONDS:
            return
        try:
            changed = False
            if SUPERUSER_GROUP:
                value = groups_client.is_member(SUPERUSER_GROUP, email)
                changed |= user.is_superuser != value
                user.is_superuser = value
            if STAFF_GROUP:
                value = user.is_superuser or groups_client.is_member(STAFF_GROUP, email)
                changed |= user.is_staff != value
                user.is_staff = value
            if changed:
                user.save(update_fields=["is_superuser", "is_staff"])
                logger.info("Roles actualizados para %s: superuser=%s staff=%s", email, user.is_superuser, user.is_staff)
            request.session["iap_groups_checked"] = time.time()
        except Exception as exc:
            # Si la API falla se mantienen los roles actuales y se reintenta en la próxima request.
            logger.error("No se pudieron consultar los grupos de %s: %s", email, exc)


class CloudIdentityGroups:

    """Cliente mínimo de la Cloud Identity Groups API usando la service account de la VM."""

    METADATA_TOKEN_URL = "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"
    API = "https://cloudidentity.googleapis.com/v1"

    def __init__(self):
        self._token = None
        self._token_exp = 0
        self._group_names = {}

    def _headers(self):
        if time.time() > self._token_exp - 60:
            resp = requests.get(self.METADATA_TOKEN_URL, headers={"Metadata-Flavor": "Google"}, timeout=5)
            resp.raise_for_status()
            data = resp.json()
            self._token = data["access_token"]
            self._token_exp = time.time() + int(data.get("expires_in", 300))
        return {"Authorization": f"Bearer {self._token}"}

    def _group_name(self, group_email):
        if group_email not in self._group_names:
            resp = requests.get(
                f"{self.API}/groups:lookup", params={"groupKey.id": group_email}, headers=self._headers(), timeout=10,
            )
            resp.raise_for_status()
            self._group_names[group_email] = resp.json()["name"]  # groups/XXXX
        return self._group_names[group_email]

    def is_member(self, group_email, member_email):
        """Membresía directa (no considera grupos anidados)."""
        resp = requests.get(
            f"{self.API}/{self._group_name(group_email)}/memberships:lookup",
            params={"memberKey.id": member_email},
            headers=self._headers(),
            timeout=10,
        )
        if resp.status_code == 404:
            return False
        resp.raise_for_status()
        return True


groups_client = CloudIdentityGroups()
