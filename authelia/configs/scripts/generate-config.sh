#!/bin/bash
set -euo pipefail
CONFIG_DIR="$SERVICE_HOME/config"
mkdir -p "$CONFIG_DIR"
CONFIG_FILE="$CONFIG_DIR/configuration.yml"
[ -f "$CONFIG_FILE" ] && exit 0

# Use SMTP notifier when configured, otherwise fall back to filesystem.
if [ -n "${AUTHELIA_NOTIFIER_SMTP_ADDRESS:-}" ]; then
  NOTIFIER_BLOCK="notifier:
  smtp:
    address: '$AUTHELIA_NOTIFIER_SMTP_ADDRESS'"
else
  NOTIFIER_BLOCK="notifier:
  filesystem:
    filename: '/config/notification.txt'"
fi

# The session cookie domain and authelia_url are read from the environment at
# load time via authelia's config template engine (the install sets
# X_AUTHELIA_CONFIG_FILTERS=template, which is also what resolves the JWKS
# `{{ secret ... }}` below). ryra computes AUTH_COOKIE_DOMAIN and AUTH_URL into
# the .env, so a later auth-URL change (e.g. switching to --tailscale) is
# picked up on the next restart. We intentionally do NOT regenerate this file
# when it already exists: register_oidc_client appends OIDC clients into it,
# and regenerating would drop them.
cat > "$CONFIG_FILE" <<YAML
---
server:
  address: 'tcp://0.0.0.0:9091'
log:
  level: 'info'
authentication_backend:
  file:
    path: '/config/users_database.yml'
session:
  cookies:
    - domain: '{{ env "AUTH_COOKIE_DOMAIN" }}'
      authelia_url: '{{ env "AUTH_URL" }}'
storage:
  local:
    path: '/config/db.sqlite3'
$NOTIFIER_BLOCK
access_control:
  default_policy: 'one_factor'
YAML
