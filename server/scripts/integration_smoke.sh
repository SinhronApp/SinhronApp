#!/usr/bin/env bash
# Sinhron server — full end-to-end integration smoke test (WU A12).
#
# Exercises every Stage A endpoint + WS flow against a clean Postgres
# instance. Used as the canonical CI gate before merging server changes.
#
# Preconditions:
#   • PostgreSQL 16 running at $SMOKE_DB_URL (default = brew install
#     postgresql@16 + the dev superuser).
#   • Cargo + protoc installed (cargo will install protobuf-compiler via
#     a friendly error if missing).
#
# Layout:
#   • Each test prefixed with `>>>` for grep-ability.
#   • `assert_status N url` / `assert_contains needle text` helpers.
#   • Exit code 0 only when every assertion passes.

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SERVER_DIR"

DB_NAME="${SMOKE_DB_NAME:-sinhron_smoke}"
PSQL="${PSQL:-/opt/homebrew/opt/postgresql@16/bin/psql}"
CREATEDB="${CREATEDB:-/opt/homebrew/opt/postgresql@16/bin/createdb}"
DROPDB="${DROPDB:-/opt/homebrew/opt/postgresql@16/bin/dropdb}"
DB_URL="${SMOKE_DB_URL:-postgres://$USER@localhost/$DB_NAME}"
SERVER_LOG="/tmp/sinhron_smoke_$$.log"
SERVER_PID=""

# Fixed test fixtures (deterministic — see examples/gen_proof.rs). Proofs
# name the server "localhost" (ADR-086) — the server here has no
# SINHRON_PUBLIC_HOSTNAME, so it takes loopback names.
ALICE_SEED="4242424242424242424242424242424242424242424242424242424242424242"
ALICE_ID="2152f8d19b791d24453242e15f2eab6cb7cffa7b6a5ed30097960e069881db12"
ALICE_REG="59c56fabd8fda461df87fde60dc460c0267c421b6504419ed816101e6a3b3b465082e2bb8277b4f841eff2ccb7b0f735dc5749856e38b87fd09ffb891c156f08"
ALICE_DEV="$ALICE_ID"  # the first device is the identity key (server-http:2)
ALICE_DEV_SEED="$ALICE_SEED"

BOB_ID="31debe55d37c722768b137131caa6087080b2e0b60b94bd785d14575cfa498bc"
BOB_REG="c8bfffc1ce19e69e35b16459c3bc1305d8afeeaca6398bc4f63406a11e1d911bbd122e3e03c236026d8e62e52f7cf858b819e63de67e83599dd18add8a10a80b"
BOB_DEV="$BOB_ID"

# ─── Helpers ─────────────────────────────────────────────────────────
section() { echo; echo ">>> $1"; }
fail() { echo "✗ FAIL: $*" >&2; cleanup; exit 1; }
assert_eq() {
    if [[ "$1" != "$2" ]]; then fail "$3 — expected '$2', got '$1'"; fi
}
assert_contains() {
    if ! grep -q "$2" <<<"$1"; then fail "$3 — expected substring '$2'"; fi
}

cleanup() {
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -TERM "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    "$DROPDB" "$DB_NAME" 2>/dev/null || true
    rm -f "$SERVER_LOG"
}
trap cleanup EXIT INT TERM

# ─── 1. Bring up a clean DB + server ─────────────────────────────────
section "Boot: clean DB + sinhron-server"
"$DROPDB" "$DB_NAME" 2>/dev/null || true
"$CREATEDB" "$DB_NAME"

SINHRON_DB_URL="$DB_URL" RUST_LOG=info cargo run --quiet >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
# Wait for the listener (up to 30s, polling).
for i in {1..30}; do
    if curl -fsS http://localhost:8080/_healthz >/dev/null 2>&1; then break; fi
    sleep 1
done
curl -fsS http://localhost:8080/_healthz >/dev/null || fail "server did not start within 30s"
echo "✓ server up"

# ─── 2. Health probes ────────────────────────────────────────────────
section "Probes: /_healthz + /_readyz"
HEALTH=$(curl -sS http://localhost:8080/_healthz)
assert_contains "$HEALTH" '"status":"ok"' "healthz"
READY=$(curl -sS http://localhost:8080/_readyz)
assert_contains "$READY" '"status":"ready"' "readyz"
assert_contains "$READY" '"db":"ok"' "readyz db ping"
echo "✓ probes ok"

# ─── 3. Identity registration + idempotent replay ────────────────────
section "Identity: register Alice + replay-idempotency"
REG_A=$(curl -sS -X POST http://localhost:8080/v1/identity \
    -H 'Content-Type: application/json' \
    -d "{\"identity_pubkey_hex\":\"$ALICE_ID\",\"registration_proof_hex\":\"$ALICE_REG\",\"primary_device\":{\"device_pk_hex\":\"$ALICE_DEV\",\"device_credential_hex\":\"$ALICE_DEV\"}}")
assert_contains "$REG_A" '"already_existed":false' "alice first register"
ALICE_USER_PK=$(echo "$REG_A" | grep -oE '"user_pk":"[^"]+"' | cut -d'"' -f4)

REG_A2=$(curl -sS -X POST http://localhost:8080/v1/identity \
    -H 'Content-Type: application/json' \
    -d "{\"identity_pubkey_hex\":\"$ALICE_ID\",\"registration_proof_hex\":\"$ALICE_REG\"}")
assert_contains "$REG_A2" '"already_existed":true' "alice replay"
ALICE_USER_PK2=$(echo "$REG_A2" | grep -oE '"user_pk":"[^"]+"' | cut -d'"' -f4)
assert_eq "$ALICE_USER_PK2" "$ALICE_USER_PK" "user_pk stable across replay"
echo "✓ identity ok"

# ─── 4. Register Bob + create group ──────────────────────────────────
section "Identity + Groups: Bob + deadbeef"
curl -sS -X POST http://localhost:8080/v1/identity \
    -H 'Content-Type: application/json' \
    -d "{\"identity_pubkey_hex\":\"$BOB_ID\",\"registration_proof_hex\":\"$BOB_REG\",\"primary_device\":{\"device_pk_hex\":\"$BOB_DEV\",\"device_credential_hex\":\"$BOB_DEV\"}}" >/dev/null

TS=$(date +%s)
# ADR-083 — signed by the announcing device: body = group id || be8(epoch)
# (ADR-090) || member keys.
G_PROOF=$(cargo run --quiet --example gen_proof -- action "$ALICE_DEV_SEED" sinhron-group-announce-v1: "deadbeef0000000000000001$ALICE_DEV$BOB_DEV" "$TS" 2>/dev/null | grep ^proof_hex | cut -d= -f2)
GROUP=$(curl -sS -X POST http://localhost:8080/v1/groups \
    -H 'Content-Type: application/json' \
    -d "{\"group_id_hex\":\"deadbeef\",\"creator_device_pk_hex\":\"$ALICE_DEV\",\"member_device_pks_hex\":[\"$ALICE_DEV\",\"$BOB_DEV\"],\"epoch\":1,\"proof_ts\":$TS,\"proof_hex\":\"$G_PROOF\"}")
assert_contains "$GROUP" '"member_count":2' "group has 2 members"
echo "✓ bob + group ok"

# ─── 5. KeyPackage upload + atomic consume ───────────────────────────
section "KeyPackages: upload + consume + exhausted"
KP_B64=$(printf 'fake_kp_smoke_v1' | base64)
TS=$(date +%s)
UP_PROOF=$(cargo run --quiet --example gen_proof -- upload-kp "$ALICE_DEV_SEED" "$KP_B64" "$TS" 2>/dev/null | grep ^upload_proof_hex | cut -d= -f2)

UPLOAD=$(curl -sS -X POST http://localhost:8080/v1/keypackages \
    -H 'Content-Type: application/json' \
    -d "{\"device_pk_hex\":\"$ALICE_DEV\",\"kp_bytes_b64\":\"$KP_B64\",\"upload_proof_ts\":$TS,\"upload_proof_hex\":\"$UP_PROOF\"}")
assert_contains "$UPLOAD" '"keypackage_id":' "kp upload"

# server-http:5 — taking KeyPackages is signed by a registered device.
C_PROOF=$(cargo run --quiet --example gen_proof -- action "$ALICE_SEED" sinhron-kp-consume-v1: "$ALICE_ID" "$TS" 2>/dev/null | grep ^proof_hex | cut -d= -f2)
C_SIGNED="signer_pk_hex=$ALICE_ID&proof_ts=$TS&proof_hex=$C_PROOF"
CONSUME=$(curl -sS "http://localhost:8080/v1/keypackages/consume?identity_pubkey_hex=$ALICE_ID&count=1&$C_SIGNED")
assert_contains "$CONSUME" "$KP_B64" "consume returns uploaded kp"

CONSUME_EMPTY=$(curl -sS "http://localhost:8080/v1/keypackages/consume?identity_pubkey_hex=$ALICE_ID&count=1&$C_SIGNED")
assert_eq "$CONSUME_EMPTY" "[]" "pool exhausted"
echo "✓ keypackages ok"

# (6 — state_backup — is gone: the server no longer has PUT/GET /v1/state-backup.)

# ─── 7. WS fanout (Alice → Bob live) ─────────────────────────────────
section "WebSocket: live fanout via ws_fanout example"
FANOUT_OUT=$(cargo run --quiet --example ws_fanout 2>&1)
assert_contains "$FANOUT_OUT" "✓ fanout end-to-end" "fanout end-to-end"
echo "✓ ws fanout ok"

# ─── 8. WS resume (offline replay) — wipe deliveries first ──────────
section "WebSocket: Resume replays offline messages"
"$PSQL" -d "$DB_NAME" -c "TRUNCATE message_deliveries, messages CASCADE;" >/dev/null
RESUME_OUT=$(cargo run --quiet --example ws_resume 2>&1)
assert_contains "$RESUME_OUT" "2 messages replayed in order" "resume replay"
echo "✓ ws resume ok"

# ─── 9. Retention sweep ──────────────────────────────────────────────
section "Retention: backdate rows + sweep"
"$PSQL" -d "$DB_NAME" -c "
  UPDATE messages SET ts = NOW() - INTERVAL '60 days';
  UPDATE message_deliveries SET delivered_at = NOW() - INTERVAL '60 days';
" >/dev/null
SWEEP=$(SINHRON_DB_URL="$DB_URL" cargo run --quiet --example sweep_now 14 2>&1)
assert_contains "$SWEEP" "messages=2" "sweep deletes messages"
assert_contains "$SWEEP" "deliveries=2" "sweep deletes deliveries"

POST_SWEEP=$("$PSQL" -d "$DB_NAME" -tA -c "SELECT COUNT(*) FROM messages;")
assert_eq "$POST_SWEEP" "0" "messages empty post-sweep"
echo "✓ retention ok"

# ─── 10. Final sanity ────────────────────────────────────────────────
section "DONE — every Stage A endpoint + WS flow verified end-to-end ✓"
echo
echo "Summary:"
echo "  ✓ /_healthz + /_readyz"
echo "  ✓ POST /v1/identity (new + idempotent replay)"
echo "  ✓ POST /v1/groups"
echo "  ✓ POST /v1/keypackages (upload)"
echo "  ✓ GET  /v1/keypackages/consume (atomic + exhausted)"
echo "  ✓ WS   /v1/sync — Hello + Auth + Heartbeat + Submit + Push (live fanout)"
echo "  ✓ WS   /v1/sync — Resume (offline replay)"
echo "  ✓ Retention worker (backdate + sweep)"
