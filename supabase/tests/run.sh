#!/usr/bin/env bash
# Applies the migrations to a throwaway Postgres (with a minimal stub of Supabase's auth/storage
# schemas) and runs integrity + RLS checks. Lines prefixed "EXPECT ERROR" should be followed by an error.
set -euo pipefail
cd "$(dirname "$0")"
docker rm -f sikka-pg-test >/dev/null 2>&1 || true
docker run -d --name sikka-pg-test -e POSTGRES_PASSWORD=pw postgres:15 >/dev/null
trap 'docker rm -f sikka-pg-test >/dev/null' EXIT
until docker exec sikka-pg-test pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
sleep 2
psql_() { docker exec -i sikka-pg-test psql -q -U postgres "$@"; }
psql_ < 00_supabase_stub.sql
psql_ < 01_grants.sql
for f in ../migrations/*.sql; do psql_ -v ON_ERROR_STOP=1 < "$f"; done
psql_ < 02_checks.sql 2>&1 | grep -v '^CONTEXT\|^PL/pgSQL'
