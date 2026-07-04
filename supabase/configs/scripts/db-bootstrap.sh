#!/bin/bash
# Apply supabase's init SQL against an EXTERNAL supabase/postgres instance.
# The bundled supabase-db.container gets these via /docker-entrypoint-initdb.d;
# in external mode this one-shot replays them over the network instead.
#
# Requires a supabase/postgres-flavored server: roles.sql only ALTERs roles
# (authenticator, supabase_auth_admin, …) the image pre-creates, and
# webhooks.sql needs pg_net. A stock Postgres will fail here, loudly.
set -euo pipefail

: "${POSTGRES_HOST:?POSTGRES_HOST required for external database}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD required for external database}"
PORT="${POSTGRES_PORT:-5432}"
USER="${POSTGRES_USER:-supabase_admin}"
DB="${POSTGRES_DB:-postgres}"
export PGPASSWORD="$POSTGRES_PASSWORD"
PSQL=(psql -v ON_ERROR_STOP=1 -h "$POSTGRES_HOST" -p "$PORT" -U "$USER")

echo "Waiting for Postgres at ${POSTGRES_HOST}:${PORT} ..."
ready=0
for i in $(seq 1 60); do
    if pg_isready -h "$POSTGRES_HOST" -p "$PORT" -U "$USER" >/dev/null 2>&1; then
        ready=1
        break
    fi
    echo "  attempt ${i}/60: not ready, retrying in 2s"
    sleep 2
done
if [ "$ready" -ne 1 ]; then
    echo "ERROR: Postgres at ${POSTGRES_HOST}:${PORT} never became ready" >&2
    exit 1
fi
echo "Connected. Applying supabase init SQL..."

# _supabase database — create once (CREATE DATABASE is not idempotent).
if ! "${PSQL[@]}" -d "$DB" -tAc \
    "SELECT 1 FROM pg_database WHERE datname='_supabase'" | grep -q 1; then
    "${PSQL[@]}" -d "$DB" -f /configs/db/_supabase.sql
fi

# Role passwords and JWT cluster settings — idempotent ALTERs.
"${PSQL[@]}" -d "$DB" -f /configs/db/roles.sql
"${PSQL[@]}" -d "$DB" -f /configs/db/jwt.sql

# Schemas — CREATE ... IF NOT EXISTS, safe to re-run.
"${PSQL[@]}" -d "$DB" -f /configs/db/realtime.sql
"${PSQL[@]}" -d "$DB" -f /configs/db/logs.sql
"${PSQL[@]}" -d "$DB" -f /configs/db/pooler.sql

# Webhooks (supabase_functions schema + pg_net) — create once.
if ! "${PSQL[@]}" -d "$DB" -tAc \
    "SELECT 1 FROM information_schema.schemata WHERE schema_name='supabase_functions'" | grep -q 1; then
    "${PSQL[@]}" -d "$DB" -f /configs/db/webhooks.sql
fi

echo "Supabase external DB bootstrap complete."
