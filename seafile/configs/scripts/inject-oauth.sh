#!/bin/bash
set -euo pipefail
[ -z "${OAUTH_CLIENT_ID:-}" ] && exit 0

CONF=$SERVICE_HOME/shared/seafile/conf

echo "Waiting for $CONF/seahub_settings.py to appear (Seafile creates it on first boot)..."
for i in $(seq 1 60); do
  [ -f "$CONF/seahub_settings.py" ] && break
  ELAPSED=$((i * 10))
  echo "  not yet — retrying in 10s (${ELAPSED}s elapsed)"
  sleep 10
done
[ -f "$CONF/seahub_settings.py" ] || { echo "ERROR: $CONF/seahub_settings.py not found after 600s"; exit 1; }

# OAUTH_ATTRIBUTE_MAP maps OIDC claims -> Seafile user fields. The entry whose
# *target* is "uid" or "email" decides how Seafile derives the account username
# for SSO-provisioned users, and this has a sharp footgun (see service.toml,
# [[choice]] oidc_identity):
#
#   uid (default): {"sub": (False, "uid"), "email": (True, "contact_email")}
#       SSO accounts are named `<sub>@auth.local`; the email is stored only as
#       contact_email. Stable across email changes. BUT Seafile's login form runs
#       the typed login string through convert_login_str_to_username(), which
#       resolves an email to whichever account carries it as contact_email — the
#       SSO account. So if a *native* account already owns that same email (the
#       INIT_SEAFILE_ADMIN_EMAIL admin, or an account made under an earlier
#       `email` mapping), email login silently targets the SSO account and the
#       native one becomes unreachable: "Incorrect email or password" even with
#       the correct password, since the password belongs to the shadowed account.
#
#   email: {"email": (True, "email"), "name": (False, "name")}
#       The SSO account username *is* the IdP email, so it coincides with a native
#       account of the same address — no `@auth.local`, no shadowing. Trade-off:
#       email is mutable; a changed address in the IdP orphans the old account.
case "${OAUTH_IDENTITY_SOURCE:-uid}" in
  email)
    OAUTH_ATTRIBUTE_MAP='{"email": (True, "email"), "name": (False, "name")}'
    ;;
  uid|"")
    OAUTH_ATTRIBUTE_MAP='{"email": (True, "contact_email"), "name": (False, "name"), "sub": (False, "uid")}'
    ;;
  *)
    echo "ERROR: OAUTH_IDENTITY_SOURCE must be 'uid' or 'email', got '${OAUTH_IDENTITY_SOURCE}'"; exit 1
    ;;
esac

cat > "$CONF/seahub_settings_oauth.py" << EOF
ENABLE_OAUTH = True
OAUTH_CREATE_UNKNOWN_USER = True
OAUTH_ACTIVATE_USER_AFTER_CREATION = True
OAUTH_CLIENT_ID = "$OAUTH_CLIENT_ID"
OAUTH_CLIENT_SECRET = "$OAUTH_CLIENT_SECRET"
OAUTH_REDIRECT_URL = "$OAUTH_REDIRECT_URL"
OAUTH_PROVIDER_DOMAIN = "$OAUTH_PROVIDER_DOMAIN"
OAUTH_PROVIDER = "authelia"
OAUTH_AUTHORIZATION_URL = "${OAUTH_PROVIDER_DOMAIN}/api/oidc/authorization"
OAUTH_TOKEN_URL = "${OAUTH_INTERNAL_DOMAIN}/api/oidc/token"
OAUTH_USER_INFO_URL = "${OAUTH_INTERNAL_DOMAIN}/api/oidc/userinfo"
OAUTH_SCOPE = ["openid", "profile", "email"]
OAUTH_ATTRIBUTE_MAP = ${OAUTH_ATTRIBUTE_MAP}
EOF

if ! grep -q seahub_settings_oauth "$CONF/seahub_settings.py"; then
  echo "exec(open('/shared/seafile/conf/seahub_settings_oauth.py').read())" >> "$CONF/seahub_settings.py"
  # Tell restart-seahub.sh that start.py started seahub without these
  # settings loaded — a one-shot restart is required this boot.
  touch "$CONF/.seahub-restart-needed"
fi

echo "OAuth config injected into seahub_settings.py"
