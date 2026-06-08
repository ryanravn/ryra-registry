#!/bin/bash
# Stop the stack, wipe data volumes so restic restores into clean trees.
# mkdir + container `:U` chown round-trips ownership on next start.
set -euo pipefail

UNITS=(
    ente-web.service
    ente.service
    ente-minio.service
    ente-postgres.service
)
systemctl --user stop "${UNITS[@]}" || true
sleep 3

podman unshare rm -rf "$SERVICE_HOME/db-data" "$SERVICE_HOME/minio-data"
mkdir -p "$SERVICE_HOME/db-data" "$SERVICE_HOME/minio-data"
