#!/bin/bash
# Stop museum + web + minio + postgres so postgres flushes WAL and the
# MinIO object store is quiescent, giving a consistent on-disk copy.
# Chown both data dirs to namespace-root (= ryra on the host) so restic
# can read everything; the next container start re-applies `:U`.
set -euo pipefail

UNITS=(
    ente-web.service
    ente.service
    ente-minio.service
    ente-postgres.service
)
systemctl --user stop "${UNITS[@]}" || true
sleep 3

podman unshare chown -R 0:0 "$SERVICE_HOME/db-data" "$SERVICE_HOME/minio-data"
