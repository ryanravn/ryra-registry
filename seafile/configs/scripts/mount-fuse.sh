#!/bin/bash
# Mount the seafile libraries as a read-only filesystem at /seaf-fuse
# INSIDE the container, via the seaf-fuse binary the image ships. This is
# what makes the stored files legible to anything besides seafile itself:
# the box agent (and any indexer) reads them with
# `podman exec seafile ls /seaf-fuse/...`; writes keep going through
# seafile proper, where sync and sharing live.
#
# Best-effort by design: a box without /dev/fuse loses search, not file
# sync. Idempotent: an existing mount exits early on re-runs.
set -uo pipefail

echo "Waiting for the seafile server tree (created on first boot)..."
for i in $(seq 1 60); do
  podman exec seafile test -d /opt/seafile/seafile-server-latest 2>/dev/null && break
  sleep 10
done
if ! podman exec seafile test -d /opt/seafile/seafile-server-latest 2>/dev/null; then
  echo "seaf-fuse: server tree never appeared; skipping mount"
  exit 0
fi

if podman exec seafile grep -qs ' /seaf-fuse fuse' /proc/mounts; then
  echo "seaf-fuse already mounted."
  exit 0
fi

if ! podman exec seafile test -e /dev/fuse; then
  echo "seaf-fuse: /dev/fuse not available in the container; skipping mount"
  exit 0
fi

podman exec seafile bash -c \
  'mkdir -p /seaf-fuse && cd /opt/seafile/seafile-server-latest && ./seaf-fuse.sh start /seaf-fuse' \
  || { echo "seaf-fuse: mount failed (see seafile logs); continuing without it"; exit 0; }
echo "seaf-fuse mounted at /seaf-fuse (read-only view of all libraries)."
