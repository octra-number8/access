#!/usr/bin/env bash
# Applies supabase/migrations to a fresh database and runs the pgTAP suite.
#
# Fallback for when `supabase db reset && supabase test db` is unavailable. Uses a
# standalone container of the Supabase Postgres image, so the roles (anon,
# authenticated, service_role), the auth schema and pgTAP match the platform.
#
#   scripts/db-test.sh            migrations + all tests
#   scripts/db-test.sh --no-tests migrations only
#
# Each run clones the image's pristine `postgres` database into `octra_test`, so
# runs never depend on each other.
set -euo pipefail

CONTAINER="${OCTRA_DB_CONTAINER:-octra-access-phase1-db}"
IMAGE="${OCTRA_DB_IMAGE:-public.ecr.aws/supabase/postgres:17.11.0.002}"
PORT="${OCTRA_DB_PORT:-55432}"
DB=octra_test
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  docker run -d --name "$CONTAINER" -e POSTGRES_PASSWORD=postgres \
    -p "127.0.0.1:${PORT}:5432" "$IMAGE" >/dev/null
fi
docker start "$CONTAINER" >/dev/null
for _ in $(seq 1 60); do
  docker exec "$CONTAINER" pg_isready -U postgres -h localhost >/dev/null 2>&1 && break
  sleep 1
done

psql_admin() { docker exec -i "$CONTAINER" psql -U supabase_admin -h localhost -d postgres -v ON_ERROR_STOP=1 -q "$@"; }
psql_db()    { docker exec -i "$CONTAINER" psql -U postgres -h localhost -d "$DB" -v ON_ERROR_STOP=1 -q "$@"; }

psql_admin <<SQL
select pg_terminate_backend(pid) from pg_stat_activity
 where datname in ('postgres', '$DB') and pid <> pg_backend_pid();
drop database if exists $DB;
create database $DB template postgres owner postgres;
SQL

for f in "$ROOT"/supabase/migrations/*.sql; do
  echo "migrate $(basename "$f")"
  psql_db < "$f" >/dev/null
done

# Mutation testing: OCTRA_EXTRA_SQL=path deliberately weakens a control after the
# migrations, to prove the suite notices. Never used for a real run.
if [[ -n "${OCTRA_EXTRA_SQL:-}" ]]; then
  echo "applying deliberate mutation $(basename "$OCTRA_EXTRA_SQL")"
  psql_db < "$OCTRA_EXTRA_SQL" >/dev/null
fi

[[ "${1:-}" == "--no-tests" ]] && exit 0

psql_admin -d "$DB" -c "create extension if not exists pgtap with schema extensions;"
docker exec "$CONTAINER" rm -rf /tmp/octra-tests
docker cp "$ROOT/supabase/tests" "$CONTAINER:/tmp/octra-tests"

failed=0
total_ok=0
total_not_ok=0
for f in "$ROOT"/supabase/tests/*.test.sql; do
  name="$(basename "$f")"
  out="$(docker exec -w /tmp/octra-tests "$CONTAINER" \
          psql -U postgres -h localhost -d "$DB" -X -q -t -A -v ON_ERROR_STOP=1 -f "$name" 2>&1)" || true
  ok=$(grep -cE '^ok [0-9]+' <<<"$out" || true)
  not_ok=$(grep -cE '^not ok [0-9]+' <<<"$out" || true)
  plan=$(grep -oE '^1\.\.[0-9]+' <<<"$out" | head -1 | cut -d. -f3 || true)
  errors=$(grep -E 'ERROR|psql:' <<<"$out" || true)
  total_ok=$((total_ok + ok)); total_not_ok=$((total_not_ok + not_ok))
  if [[ "$not_ok" -gt 0 || -n "$errors" || "$plan" != "$((ok + not_ok))" ]]; then
    failed=1
    echo "FAIL $name  (ok $ok, not ok $not_ok, planned ${plan:-?})"
    grep -E '^not ok|^#|ERROR|psql:' <<<"$out" | sed 's/^/    /'
  else
    echo "pass $name  ($ok tests)"
  fi
done
echo "total: $total_ok passed, $total_not_ok failed"
exit $failed
