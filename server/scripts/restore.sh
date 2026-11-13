#!/usr/bin/env bash
# Restore a Sinhron server from `backup.sh` files — the other half of
# backup.sh (2026-10-16: the move from DigitalOcean to a Russian provider).
#
#   cd server && SINHRON_BACKUP_PASSFILE=… scripts/restore.sh /path/to/backup-dir [YYYY-MM-DD]
#
# Takes `sinhron-<date>.sql.gz.gpg` and `sinhron-media-<date>.tgz.gpg` from
# the dir (the newest date when none is given), opened with
# SINHRON_BACKUP_PASSFILE (backup.sh encrypts since 2026-11-02; an older
# plain dump: by hand, docs/deploy-guide.md §8.2), then:
#   1. stops sinhron-server (nothing writes while the database is replaced);
#   2. replaces the database with the dump (DROP SCHEMA public — everything
#      in this server's database is lost; asks first unless --yes);
#   3. replaces the media volume's files with the archive;
#   4. starts sinhron-server — migrations newer than the dump apply on start.
#
# The .env is NOT restored here: put it back first (`env-<date>.gpg`,
# `gpg -d` with the backup password) — the database password and the keys
# in it must be the ones this data was made with. install.sh keeps an
# existing .env.

set -euo pipefail

YES=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --yes) YES=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
SRC=${ARGS[0]:?usage: scripts/restore.sh <backup-dir> [YYYY-MM-DD] [--yes]}
STAMP=${ARGS[1]:-}

cd "$(dirname "$0")/.."
COMPOSE=(docker compose -f docker-compose.yml)
[ -f .env ] || { echo "[restore] no server/.env — restore it from env-<date>.gpg first" >&2; exit 1; }

# Only the encrypted `.gpg` files count (security review 2026-11,
# deploy-deps:15): a plain dump planted next to them was taken first, and
# a `gpg --store` file (no password) decrypted "fine" — so each file must
# really be encrypted with the backup password (DECRYPTION_OKAY).
PASSFILE=${SINHRON_BACKUP_PASSFILE:?set SINHRON_BACKUP_PASSFILE (the backup password file)}
if [ -z "$STAMP" ]; then
  STAMP=$(find "$SRC" -maxdepth 1 -name 'sinhron-*.sql.gz.gpg' ! -name 'sinhron-media-*' -printf '%f\n' \
    | sed -E 's/^sinhron-(.*)\.sql\.gz\.gpg$/\1/' | sort | tail -1)
fi
[[ $STAMP =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "[restore] no backup or bad date: '$STAMP'" >&2; exit 1; }
TMP=$(umask 077 && mktemp -d)
trap 'rm -rf "$TMP"' EXIT
for f in "sinhron-$STAMP.sql.gz" "sinhron-media-$STAMP.tgz"; do
  [ -f "$SRC/$f.gpg" ] || { echo "[restore] no $SRC/$f.gpg" >&2; exit 1; }
  gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$PASSFILE" --status-file "$TMP/status" \
    -d -o "$TMP/$f" "$SRC/$f.gpg"
  grep -q '^\[GNUPG:\] DECRYPTION_OKAY' "$TMP/status" \
    || { echo "[restore] $f.gpg is not encrypted with the backup password" >&2; exit 1; }
done
DUMP=$TMP/sinhron-$STAMP.sql.gz
MEDIA=$TMP/sinhron-media-$STAMP.tgz
gzip -t "$DUMP" && tar -tzf "$MEDIA" >/dev/null
# A cut or empty dump is still valid gzip, and the database is dropped before
# it is loaded (audit 2026-11b, D-B3). pg_dump ends a whole dump with this
# line (pg 16.15 adds a few lines after it) — checked before anything changes.
gunzip -c "$DUMP" | tail -n 20 | grep -q '^-- PostgreSQL database dump complete' \
  || { echo "[restore] the dump is cut short or empty — nothing changed" >&2; exit 1; }

if ((!YES)); then
  read -r -p "[restore] REPLACE this server's database and media with $STAMP? [y/N] " ans
  [[ $ans == [yY]* ]] || { echo "[restore] cancelled"; exit 1; }
fi

DB_USER=${POSTGRES_USER:-sinhron}
DB_NAME=${POSTGRES_DB:-sinhron}

echo "[restore] stopping sinhron-server"
"${COMPOSE[@]}" stop sinhron-server >/dev/null
"${COMPOSE[@]}" up -d --wait postgres >/dev/null

echo "[restore] database ← $(basename "$DUMP")"
"${COMPOSE[@]}" exec -T postgres psql -q -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" \
  -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;' >/dev/null
gunzip -c "$DUMP" | "${COMPOSE[@]}" exec -T postgres psql -q -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" >/dev/null

# deploy-deps:8 — the server's own role (when set) owns what was restored.
"${COMPOSE[@]}" exec -T postgres sh /docker-entrypoint-initdb.d/10-app-role.sh

echo "[restore] media ← $(basename "$MEDIA")"
VOLUME="$("${COMPOSE[@]}" config --format json 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["volumes"]["sinhron_media"]["name"])' 2>/dev/null \
  || echo server_sinhron_media)"
docker volume create "$VOLUME" >/dev/null
docker run --rm -v "$VOLUME":/m -v "$TMP":/b:ro alpine \
  sh -c 'find /m -mindepth 1 -delete && tar xzf "/b/$1" -C /m' sh "$(basename "$MEDIA")"  # tar as root keeps the files' owners

echo "[restore] starting sinhron-server"
"${COMPOSE[@]}" up -d --wait sinhron-server >/dev/null
echo "[restore] done: $STAMP"
