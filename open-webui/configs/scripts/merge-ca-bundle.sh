#!/bin/bash
# Make the container trust Caddy's internal CA alongside public CAs, so
# OIDC discovery against an --auth install's https://auth.internal works.
# Runs as ExecStartPost with the container up; $1 is SERVICE_HOME (passed
# by the quadlet, so sandboxed installs stay sandboxed). Best-effort by
# design (leading '-' on the quadlet line): a box without the CA file has
# nothing to trust, and public-CA setups must keep working.
set -u
SERVICE_HOME="$1"
# caddy exports its root CA at the services root, one level above every
# service home (the documented cross-service contract; see the registry
# README).
CADDY_CA="$(dirname "$SERVICE_HOME")/caddy-root-ca.crt"
[ -f "$CADDY_CA" ] || exit 0

# The bundle base comes from the RUNNING container itself: always the
# pinned image's own certifi, never a second floating image pull, and the
# path is asked of python instead of hardcoding a python3.x directory.
LOC=$(podman exec open-webui python -c 'import certifi; print(certifi.where())') || exit 0
MERGED="$SERVICE_HOME/ca-bundle.crt"
podman exec open-webui cat "$LOC" > "$MERGED" || exit 0
cat "$CADDY_CA" >> "$MERGED"
# Rebuilt fresh from the image base every start, so repeated appends can
# never accumulate.
podman cp "$MERGED" "open-webui:$LOC" || exit 0
