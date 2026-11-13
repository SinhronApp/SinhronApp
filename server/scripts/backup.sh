#!/usr/bin/env bash
# Nightly backup for a Sinhron server (docs/deploy-guide.md §8): Postgres dump,
# media blobs (ciphertext, ADR-017) and the .env — all three encrypted with GPG
# (AES256, passphrase from a file) so the backup folder can leave the VM. The
# dump and media used to be plain (security review 2026-11-02): the dump holds
# every account's keys, groups, push tokens and reports with IPs.
#
# Usage (from server/):
#   SINHRON_BACKUP_PASSFILE=~/.sinhron-backup-pass scripts/backup.sh [backup_dir]
# Cron:
#   0 3 * * * cd ~/sinhron/server && SINHRON_BACKUP_PASSFILE=~/.sinhron-backup-pass scripts/backup.sh ~/backups >> ~/backups/backup.log 2>&1
#
# Keeps the last SINHRON_BACKUP_KEEP_DAYS days (default 14). Restore: §8.2.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
DEST="${1:-$HOME/backups}"
KEEP_DAYS="${SINHRON_BACKUP_KEEP_DAYS:-14}"
PASSFILE="${SINHRON_BACKUP_PASSFILE:-}"
STAMP="$(date +%F)"
COMPOSE=(docker compose -f docker-compose.yml)

mkdir -p "$DEST"
chmod 700 "$DEST"
umask 077

echo "[backup] $STAMP → $DEST"

# No passphrase → nothing is saved (security review 2026-11, deploy-deps:15):
# the plain fallback put every key and push token in the clear next to the
# encrypted copies, and restore.sh now takes only the encrypted ones.
if [ -z "$PASSFILE" ] || [ ! -r "$PASSFILE" ] || [ ! -s "$PASSFILE" ]; then
  echo "[backup] ERROR: SINHRON_BACKUP_PASSFILE not set/readable/empty — nothing saved" >&2
  exit 1
fi
# stdin → $1.gpg.part; keep() renames it to $1.gpg — called only after the
# whole pipeline worked (pipefail + set -e stop the script first), so a failed
# or cut pg_dump / tar never gets a good backup's name (audit 2026-11b:
# save() used to rename inside the pipeline, whatever pg_dump returned).
save() {
  gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-file "$PASSFILE" \
    --symmetric --cipher-algo AES256 -o "$1.gpg.part"
}
keep() { mv "$1.gpg.part" "$1.gpg"; }

# 1. Postgres. No owners in the dump (deploy-deps:8): it restores on a server
# with or without the app's own role; restore.sh hands everything to it.
"${COMPOSE[@]}" exec -T postgres pg_dump --no-owner -U "${POSTGRES_USER:-sinhron}" "${POSTGRES_DB:-sinhron}" \
  | gzip | save "$DEST/sinhron-$STAMP.sql.gz"
keep "$DEST/sinhron-$STAMP.sql.gz"

# 2. Media blobs — same day as the dump: media rows point at these files.
VOLUME="$("${COMPOSE[@]}" config --format json 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["volumes"]["sinhron_media"]["name"])' 2>/dev/null \
  || echo server_sinhron_media)"
docker run --rm -v "$VOLUME":/m:ro alpine tar czf - -C /m . | save "$DEST/sinhron-media-$STAMP.tgz"
keep "$DEST/sinhron-media-$STAMP.tgz"

# 3. .env — encrypted, never in plain text in the backup folder.
if [ -f .env ]; then
  save "$DEST/env-$STAMP" <.env
  keep "$DEST/env-$STAMP"
fi

# 4. Retention
find "$DEST" -maxdepth 1 -type f \( -name 'sinhron-*.sql.gz' -o -name 'sinhron-media-*.tgz' -o -name 'sinhron-*.gpg' -o -name 'env-*.gpg' -o -name '*.gpg.part' \) \
  -mtime +"$KEEP_DAYS" -delete

echo "[backup] done: $(ls -1 "$DEST" | grep -c "$STAMP") files for $STAMP"
