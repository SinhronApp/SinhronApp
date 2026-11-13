#!/bin/sh
# deploy-deps:8 (docs/security-review-2026-11.md) — the server's own database
# role. The server logged in as the bootstrap superuser `sinhron`: any SQL
# foothold in it became a shell in the postgres container. With
# SINHRON_DB_APP_USER set (a new install: sinhron_app), this makes that role
# (no superuser) the owner of the database, the schema and every table, so
# migrations and the retention worker's partition DDL keep working.
#
# Runs inside the postgres container, as the superuser over the local socket:
#   • by the image on first start of an empty database (/docker-entrypoint-initdb.d);
#   • by the installer before each start (idempotent);
#   • by restore.sh after a restore;
#   • by hand when switching a live install (deploy-guide §9.1, step 3):
#       docker compose exec -T postgres sh /docker-entrypoint-initdb.d/10-app-role.sh
# Nothing to do while SINHRON_DB_APP_USER is empty or is the superuser.
# (No `exit`: the image may source this file.)
if [ -n "${SINHRON_DB_APP_USER:-}" ] && [ "$SINHRON_DB_APP_USER" != "${POSTGRES_USER:-sinhron}" ]; then
  if [ -z "${SINHRON_DB_APP_PASSWORD:-}" ]; then
    echo "10-app-role: SINHRON_DB_APP_PASSWORD is empty" >&2
    false
  else
    psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-sinhron}" -d "${POSTGRES_DB:-sinhron}" \
      -v app="$SINHRON_DB_APP_USER" <<'SQL'
\getenv pw SINHRON_DB_APP_PASSWORD
SELECT format('CREATE ROLE %I LOGIN', :'app') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app') \gexec
ALTER ROLE :"app" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'pw';
SELECT format('ALTER DATABASE %I OWNER TO %I', current_database(), :'app') \gexec
ALTER SCHEMA public OWNER TO :"app";
SELECT format('ALTER TABLE public.%I OWNER TO %I', c.relname, :'app')
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
   AND pg_get_userbyid(c.relowner) <> :'app' \gexec
SQL
  fi
fi
