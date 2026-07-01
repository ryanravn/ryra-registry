#!/bin/bash
# Create the MinIO bucket supabase-storage uses for the S3 backend.
# Runs as ExecStartPost after the supabase-minio container starts.
set -euo pipefail

BUCKET="${GLOBAL_S3_BUCKET:-supabase-storage}"

for i in $(seq 1 30); do
    podman exec supabase-minio mc alias set local http://localhost:9000 \
        "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" 2>/dev/null && break
    sleep 2
done

podman exec supabase-minio mc mb -p "local/${BUCKET}" 2>/dev/null || true
echo "MinIO bucket ${BUCKET} ready"
