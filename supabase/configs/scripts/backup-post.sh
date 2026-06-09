#!/bin/bash
# Bring the stack back after the snapshot. backup-pre.sh stopped all
# ten units and chowned db-data/storage-data to namespace-root, so a
# bare `systemctl start supabase.service` races: every dependency
# fires at once, supabase-auth beats postgres to ready and crashloops,
# and the stop+start churn (on top of any restarts from initial boot)
# blows past systemd's StartLimitBurst → start-limit-hit, which surfaces
# as "A dependency job for supabase.service failed".
#
# Mirror restore-post.sh: bring postgres up first, wait for it to accept
# connections, reset the start-limit counters the stop/start cycle just
# consumed, then start the rest of the stack.
set -euo pipefail

systemctl --user start supabase-db.service

echo "waiting for supabase-db..."
for _ in $(seq 1 90); do
    if podman exec supabase-db pg_isready -U postgres -q >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
podman exec supabase-db pg_isready -U postgres -q

systemctl --user reset-failed || true
systemctl --user start supabase.service
