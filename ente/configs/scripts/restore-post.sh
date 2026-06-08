#!/bin/bash
# Sequenced startup: postgres + minio first, wait for postgres ready,
# reset-failed, then museum + web. Avoids museum racing postgres's WAL
# replay on restore and crashlooping past systemd's StartLimitBurst.
set -euo pipefail

systemctl --user start ente-postgres.service ente-minio.service

echo "waiting for ente-postgres..."
for _ in $(seq 1 90); do
    if podman exec ente-postgres pg_isready -U pguser -q >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
podman exec ente-postgres pg_isready -U pguser -q

systemctl --user reset-failed || true

systemctl --user start ente.service ente-web.service
