#!/usr/bin/env bash
# SessionStart hook for Claude Code cloud sessions (claude.ai/code, mobile).
# Installs what the cloud image lacks: protoc (server build.rs), Flutter
# 3.41.5 (client), and starts the preinstalled PostgreSQL 16 for
# `sqlx::test` (role gets CREATEDB only, localhost, test data only).
# Does nothing on a local Mac.
#
# Idempotent; every step is best-effort so a failed download never
# blocks the session from starting. Log: /tmp/cloud_setup.log

if [ "$CLAUDE_CODE_REMOTE" != "true" ]; then
  exit 0
fi

FLUTTER_VERSION="3.41.5"
FLUTTER_HOME="$HOME/flutter"
DB_URL="postgres://sinhron:dev_only@localhost:5432/sinhron"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
LOG=/tmp/cloud_setup.log

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
# As root `$SUDO -u postgres …` became `-u postgres …` (no such command): the
# role was never made after a container restart. runuser works as root.
if [ "$(id -u)" -eq 0 ]; then AS_PG="runuser -u postgres --"; else AS_PG="sudo -u postgres"; fi

log() { echo "[cloud_setup] $*" | tee -a "$LOG" >&2; }

# Persist env vars for every Bash command Claude runs in this session.
persist() {
  if [ -n "$CLAUDE_ENV_FILE" ]; then
    echo "export $1" >> "$CLAUDE_ENV_FILE"
  fi
}

# ─── protoc (prost-build in server/build.rs) ─────────────────────────
if ! command -v protoc >/dev/null 2>&1; then
  log "installing protobuf-compiler"
  { $SUDO apt-get update -qq && $SUDO apt-get install -y -qq protobuf-compiler; } >>"$LOG" 2>&1 \
    || log "WARN: protoc install failed — server build will fail"
fi

# ─── PostgreSQL (preinstalled, not running) ─────────────────────────
log "starting postgresql"
$SUDO service postgresql start >>"$LOG" 2>&1 || log "WARN: postgresql start failed"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  $AS_PG pg_isready -q 2>/dev/null && break
  sleep 1
done
$AS_PG psql -qtAc "SELECT 1 FROM pg_roles WHERE rolname='sinhron'" 2>/dev/null | grep -q 1 \
  || $AS_PG psql -qc "CREATE ROLE sinhron LOGIN CREATEDB PASSWORD 'dev_only'" >>"$LOG" 2>&1
$AS_PG psql -qtAc "SELECT 1 FROM pg_database WHERE datname='sinhron'" 2>/dev/null | grep -q 1 \
  || $AS_PG createdb -O sinhron sinhron >>"$LOG" 2>&1
persist "DATABASE_URL=$DB_URL"
persist "SINHRON_DB_URL=$DB_URL"

# ─── Flutter ─────────────────────────────────────────────────────────
if [ ! -x "$FLUTTER_HOME/bin/flutter" ]; then
  log "cloning flutter $FLUTTER_VERSION"
  git clone -q --depth 1 --branch "$FLUTTER_VERSION" \
    https://github.com/flutter/flutter.git "$FLUTTER_HOME" >>"$LOG" 2>&1 \
    || log "WARN: flutter clone failed"
fi
if [ -x "$FLUTTER_HOME/bin/flutter" ]; then
  export PATH="$FLUTTER_HOME/bin:$PATH"
  persist "PATH=\"$FLUTTER_HOME/bin:\$PATH\""
  git config --global --add safe.directory "$FLUTTER_HOME" 2>/dev/null
  flutter config --no-analytics >>"$LOG" 2>&1
  log "flutter: $(flutter --version 2>/dev/null | head -1)"
  (cd "$PROJECT_DIR/client_flutter" && flutter pub get >>"$LOG" 2>&1) \
    || log "WARN: flutter pub get failed"
fi

log "done (details in $LOG)"
exit 0
