#!/bin/bash
# ryra has already stopped the stack and wiped the backed-up paths
# (postgres-data, storage) before this runs. Also wipe the Elasticsearch
# index: it's a derivable artefact of the DB, and a leftover index from
# before the restore would return search hits for deleted records.
# zammad-init reindexes when ES is empty.
set -euo pipefail
podman unshare rm -rf "$SERVICE_HOME/es-data"
mkdir -p "$SERVICE_HOME/es-data"
