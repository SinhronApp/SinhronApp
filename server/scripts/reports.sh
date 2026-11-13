#!/usr/bin/env bash
# Abuse reports for the operator (ADR-037; tech-debt 2.35) — instead of raw
# SQL. Run on the server:
#
#   cd /opt/sinhron/server
#   scripts/reports.sh                 open reports, oldest first
#   scripts/reports.sh all             every report (last 200)
#   scripts/reports.sh show <id>       one report in full
#   scripts/reports.sh done <id>       mark it reviewed
#   scripts/reports.sh ban <key-hex>   delete that account (asks first) and
#                                      block its key for good (ACCT-2) —
#                                      deletes what its own "Delete account" does:
#                                      devices, keys, memberships cascade
#
# Apple expects a reaction to a report within about a day. The message text
# is there only if the person reporting chose to send it.

set -euo pipefail
cd "$(dirname "$0")/.."

psql_() {
  # SINHRON_REPORTS_DB_URL: a database reached directly (tests, PgBouncer).
  if [ -n "${SINHRON_REPORTS_DB_URL:-}" ]; then
    psql "$SINHRON_REPORTS_DB_URL" -v ON_ERROR_STOP=1 "$@"
  else
    docker compose -f docker-compose.yml exec -T postgres \
      psql -U "${POSTGRES_USER:-sinhron}" -d "${POSTGRES_DB:-sinhron}" -v ON_ERROR_STOP=1 "$@"
  fi
}

id_arg() {
  [[ ${1:-} =~ ^[0-9]{1,18}$ ]] || { echo "usage: $0 $2 <report id>" >&2; exit 2; }
}

LIST="SELECT id, to_char(created_at, 'YYYY-MM-DD HH24:MI') AS at, reason,
             left(encode(reported_identity, 'hex'), 16) || '…' AS reported,
             left(encode(reporter_identity, 'hex'), 8) || '…' AS by,
             CASE WHEN message_text IS NULL THEN '' ELSE left(replace(message_text, E'\n', ' '), 60) END AS text,
             CASE WHEN reviewed_at IS NULL THEN 'open' ELSE 'done' END AS state
        FROM abuse_reports"

case "${1:-open}" in
  open)
    psql_ -c "$LIST WHERE reviewed_at IS NULL ORDER BY created_at"
    ;;
  all)
    psql_ -c "$LIST ORDER BY created_at DESC LIMIT 200"
    ;;
  show)
    id_arg "${2:-}" show
    psql_ -x -v id="$2" <<'SQL'
SELECT id, created_at, reviewed_at, reason,
       encode(reported_identity, 'hex') AS reported_identity,
       encode(reporter_identity, 'hex') AS reporter_identity,
       message_text,
       reporter_ip, reported_ip,
       (SELECT count(*) FROM abuse_reports r2 WHERE r2.reported_identity = r.reported_identity) AS reports_on_this_account
  FROM abuse_reports r WHERE id = :'id';
SQL
    ;;
  done)
    id_arg "${2:-}" done
    psql_ -v id="$2" <<'SQL'
UPDATE abuse_reports SET reviewed_at = NOW() WHERE id = :'id' AND reviewed_at IS NULL;
SQL
    ;;
  ban)
    key=${2:-}
    [[ $key =~ ^[0-9a-fA-F]{64}$ ]] || { echo "usage: $0 ban <64-hex identity key>" >&2; exit 2; }
    read -r -p "Delete the account ${key:0:16}… and everything the server keeps for it? [y/N] " ans
    [[ $ans == [yY]* ]] || { echo "cancelled"; exit 1; }
    psql_ -v key="$key" <<'SQL'
BEGIN;
DELETE FROM message_deliveries
 WHERE recipient_user_pk IN (SELECT user_pk FROM users WHERE identity_pubkey = decode(:'key', 'hex'));
DELETE FROM users WHERE identity_pubkey = decode(:'key', 'hex');
-- The key stays blocked: the server refuses to register it again (ACCT-2).
INSERT INTO users (user_pk, identity_pubkey, status) VALUES (gen_random_uuid(), decode(:'key', 'hex'), 'banned');
UPDATE abuse_reports SET reviewed_at = NOW()
 WHERE reported_identity = decode(:'key', 'hex') AND reviewed_at IS NULL;
COMMIT;
SQL
    ;;
  *)
    sed -n '3,14p' "$0" >&2
    exit 2
    ;;
esac
