#!/bin/bash
# Start ente.service — Requires= cascades postgres + minio — then the
# web frontend (which Requires= ente.service).
set -euo pipefail
systemctl --user start ente.service ente-web.service
