# local_settings.py: lo carga DefectDojo después de settings.dist.py.
# Activa el SSO con el JWT de Identity-Aware Proxy (ver iap_sso.py).
import os

if os.environ.get("DD_IAP_SSO_ENABLED", "false").lower() == "true":
    _mw = list(MIDDLEWARE)
    _mw.insert(
        _mw.index("django.contrib.auth.middleware.AuthenticationMiddleware") + 1,
        "dojo.settings.iap_sso.IAPSSOMiddleware",
    )
    MIDDLEWARE = _mw
