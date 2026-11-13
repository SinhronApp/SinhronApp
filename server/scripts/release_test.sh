#!/usr/bin/env bash
# Tests for release_preflight.sh / release_postcheck.sh / release_rollback.sh:
# docker, git, gpg, df, curl, openssl and timeout are stubs on PATH that log
# their calls; the "server" is a temp dir with stub backup.sh / restore.sh.
#
#   bash server/scripts/release_test.sh

# shellcheck disable=SC2016 # the stubs' bodies are meant to stay unexpanded
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "${WORK:?}"' EXIT

PASS=0 FAIL=0
check() { # check "name" actual expected
  if [[ $2 == "$3" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n  got:      %q\n  expected: %q\n' "$1" "$2" "$3"
  fi
}
has() { # has "name" haystack needle
  if [[ $2 == *"$3"* ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  no %q in:\n%s\n' "$1" "$3" "$2"; fi
}
hasnt() { if [[ $2 != *"$3"* ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  unexpected %q\n' "$1" "$3"; fi; }

COMMIT=0123456789abcdef0123456789abcdef01234567
BIN=$WORK/bin
export LOG=$WORK/calls.log STUB=$WORK/stub
mkdir -p "$BIN" "$STUB"
stub() { cat >"$BIN/$1" && chmod +x "$BIN/$1"; }
stub docker <<'S'
#!/usr/bin/env bash
echo "docker $*" >>"$LOG"
case "$*" in
  *' build '*) [[ -z ${STUB_BUILD_FAIL:-} ]] || exit 1 ;;
  *'config --services'*) printf 'postgres\nsinhron-server\ncaddy\nntfy\n' ;;
  *'ps -a'*) cat "$STUB/ps" ;;
  *'FROM pg_database'*) printf '%s' "${STUB_OLD_TRIAL:-}" ;;
  *pg_database_size*) echo "${STUB_DBSIZE:-1000000}" ;;
  *'df -Pk'*) printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 100 1 %s 1%% /var/lib/postgresql/data\n' "${STUB_PGFREE:-5000000}" ;;
  *'FROM _sqlx_migrations'*) echo "${STUB_MIG:-2}" ;;
  *'-d sinhron -c SELECT count(*) FROM users'*) echo "${STUB_LIVE_USERS:-3}" ;;
  *'SELECT count'*) echo 3 ;;
  *' images'*) echo 'sinhron-server sinhron/server 0.1.0' ;;
  *' logs '*) cat "$STUB/logs" ;;
  'exec sinhron-coturn cat '*) printf '%s' "${STUB_COTURN_CONF-user-quota=96}" ;;
  *psql*) cat >/dev/null ;;
esac
S
stub git <<S
#!/usr/bin/env bash
echo "git \$*" >>"\$LOG"
case "\$*" in
  *'rev-parse HEAD'*) echo $COMMIT ;;
  *status*) printf '%s' "\${STUB_GIT_DIRTY:-}" ;;
esac
S
stub gpg <<'S'
#!/usr/bin/env bash
echo "gpg" >>"$LOG"
[[ " $* " == *" -o "* ]] || tar czf - -T /dev/null
while (($#)); do
  case $1 in
    --status-file) echo '[GNUPG:] DECRYPTION_OKAY' >"$2"; shift ;;
    -o) printf 'SELECT 1;\n%s\n' "${STUB_DUMP_END--- PostgreSQL database dump complete}" | gzip >"$2"; shift ;;
  esac
  shift
done
S
stub df <<'S'
#!/usr/bin/env bash
printf ' Avail\n  %sG\n' "${STUB_DF:-40}"
S
stub curl <<'S'
#!/usr/bin/env bash
echo "curl $*" >>"$LOG"
case "$*" in
  *http_code*) printf '%s' "${STUB_WS:-101}" ;;
  *_healthz*) echo '{"service":"sinhron-server","status":"ok"}' ;;
esac
S
stub openssl <<'S'
#!/usr/bin/env bash
echo 'Verify return code: 0 (ok)'
S
stub timeout <<'S'
#!/usr/bin/env bash
shift
[[ $1 == bash ]] && exit 0
exec "$@"
S
export PATH=$BIN:$PATH

# A fresh fake server + config for each case.
N=0
fresh() {
  N=$((N + 1))
  CASE=$WORK/case$N
  SRV=$CASE/srv
  PRE=$CASE/backups/pre-0.12.0
  mkdir -p "$SRV/scripts" "$SRV/migrations" "$CASE/etc" "$CASE/backups"
  printf 'user-quota=96' >"$SRV/turnserver.conf"
  : >"$LOG"
  export SINHRON_SERVER_DIR=$SRV SINHRON_CONF=$CASE/etc/sinhron.conf RELEASE_BACKUP_ROOT=$CASE/backups
  touch "$SRV/docker-compose.yml" "$SRV/migrations/1_a.sql" "$SRV/migrations/2_b.sql"
  cat >"$SRV/.env" <<E
SINHRON_PUBLIC_HOSTNAME=chat.example.com
SINHRON_TURN_HOSTNAME=turn.chat.example.com
SINHRON_LIVEKIT_HOSTNAME=livekit.chat.example.com
SINHRON_DB_PASSWORD=realsecretvalue
LIVEKIT_KEYS=APIabc: realsecretvalue
TURN_SHARED_SECRET=realsecretvalue
COMPOSE_PROFILES=ntfy
SINHRON_NTFY_HOSTNAME=push.example.com
SINHRON_UNIFIEDPUSH_HOSTS=push.example.com
SINHRON_NTFY_TOKEN=tk_realsecretvalue
APNS_KEY_PATH=/etc/sinhron/apns/key.p8
APNS_KEY_ID=K
APNS_TEAM_ID=T
E
  cat >"$SRV/scripts/backup.sh" <<'S'
#!/usr/bin/env bash
echo "backup.sh $*" >>"$LOG"
for f in sinhron-2026-11-12.sql.gz.gpg sinhron-media-2026-11-12.tgz.gpg env-2026-11-12.gpg; do echo x >"$1/$f"; done
S
  cat >"$SRV/scripts/restore.sh" <<'S'
#!/usr/bin/env bash
echo "restore.sh $*" >>"$LOG"
[[ -z ${STUB_RESTORE_FAIL:-} ]] || exit 1
S
  chmod +x "$SRV/scripts/"*.sh
  echo 'SINHRON_DOMAIN = "chat.example.com"  # домен' >"$CASE/etc/sinhron.conf"
  echo pass >"$CASE/etc/backup-pass"
  printf 'postgres running healthy\nsinhron-server running healthy\ncaddy running \nntfy running \n' >"$STUB/ps"
  echo 'INFO migrations applied at startup' >"$STUB/logs"
}
export RELEASE_WAIT_SECS=0
unset SINHRON_BACKUP_PASSFILE
snapshot() { (cd "$CASE" && find . -type f -exec cksum {} + | sort); }
mode() { stat -c %a "$1"; }

# ── preflight ────────────────────────────────────────────────────────────
fresh
before=$(snapshot)
out=$(bash "$HERE/release_preflight.sh" --dry-run 0.12.0 2>&1); rc=$?
check "preflight dry-run: exit 0" "$rc" 0
check "preflight dry-run: changes nothing" "$(snapshot)" "$before"
check "preflight dry-run: no docker, no backup" "$(grep -cE '^(docker|backup.sh)' "$LOG")" 0

out=$(STUB_DF=9 bash "$HERE/release_preflight.sh" 0.12.0 2>&1); rc=$?
check "preflight low disk: exit 1" "$rc" 1
has "preflight low disk: says so" "$out" "[СТОП] Свободно на диске 9 ГБ"
check "preflight low disk: no backup" "$(grep -c '^backup.sh' "$LOG")" 0

sed -i 's/^SINHRON_DB_PASSWORD=.*/SINHRON_DB_PASSWORD=dev_only/; s/^TURN_SHARED_SECRET=.*/TURN_SHARED_SECRET=GENERATE_ME/' "$SRV/.env"
out=$(bash "$HERE/release_preflight.sh" 0.12.0 2>&1); rc=$?
check "preflight placeholder: exit 1" "$rc" 1
has "preflight placeholder: names" "$out" "SINHRON_DB_PASSWORD TURN_SHARED_SECRET (всего 2)"
hasnt "preflight placeholder: no values" "$out" "dev_only"
check "preflight placeholder: no backup" "$(grep -c '^backup.sh' "$LOG")" 0

fresh
rm "$CASE/etc/backup-pass"
out=$(bash "$HERE/release_preflight.sh" 0.12.0 2>&1); rc=$?
check "preflight no passfile: exit 1" "$rc" 1
has "preflight no passfile: says so" "$out" "[СТОП] Нет файла с паролем копий"
check "preflight no passfile: no backup" "$(grep -c '^backup.sh' "$LOG")" 0

fresh
out=$(bash "$HERE/release_preflight.sh" 0.12.0 2>&1); rc=$?
check "preflight: exit 0" "$rc" 0
has "preflight: last line" "$(tail -1 <<<"$out")" "Готово. Откат возможен из $PRE"
hasnt "preflight: no secret in output" "$out" realsecretvalue
check "preflight: commit" "$(cat "$PRE/commit" 2>/dev/null)" "$COMMIT"
check "preflight: env copy" "$(cmp -s "$PRE/env" "$SRV/.env" && echo same)" same
check "preflight: env mode" "$(mode "$PRE/env")" 600
check "preflight: dir mode" "$(mode "$PRE")" 700
check "preflight: server_dir" "$(cat "$PRE/server_dir")" "$SRV"
check "preflight: migrations-before" "$(cat "$PRE/migrations-before.txt")" 2
check "preflight: rollback copy" "$(cmp -s "$PRE/release_rollback.sh" "$HERE/release_rollback.sh" && echo same)" same
check "preflight: images.txt" "$([[ -s $PRE/images.txt ]] && echo yes)" yes
has "preflight: temp db created" "$(cat "$LOG")" "createdb -U sinhron sinhron_trial_"
has "preflight: temp db dropped" "$(cat "$LOG")" "dropdb --if-exists -U sinhron sinhron_trial_"
check "preflight: live db only read" "$(grep -E 'docker .*-d sinhron( |$)' "$LOG" | grep -Evc 'SELECT (count|pg_database_size)')" 0

# A second run must not overwrite the rollback point.
before=$(cd "$PRE" && find . -type f -exec cksum {} + | sort); : >"$LOG"
out=$(bash "$HERE/release_preflight.sh" 0.12.0 2>&1); rc=$?
check "preflight twice: exit 1" "$rc" 1
has "preflight twice: says so" "$out" "уже записана"
check "preflight twice: pre dir untouched" "$(cd "$PRE" && find . -type f -exec cksum {} + | sort)" "$before"
check "preflight twice: no backup" "$(grep -c '^backup.sh' "$LOG")" 0

# A trial database left by a killed run is dropped; too little room in the
# Postgres volume → STOP before the trial copy is loaded next to the live data.
fresh
out=$(STUB_OLD_TRIAL=sinhron_trial_4242 bash "$HERE/release_preflight.sh" 0.12.0 2>&1); rc=$?
check "preflight old trial db: exit 0" "$rc" 0
has "preflight old trial db: dropped" "$(cat "$LOG")" "dropdb --if-exists -U sinhron sinhron_trial_4242"
fresh
out=$(STUB_DBSIZE=4000000000 STUB_PGFREE=1000000 bash "$HERE/release_preflight.sh" 0.12.0 2>&1); rc=$?
check "preflight full pg volume: exit 1" "$rc" 1
has "preflight full pg volume: says so" "$out" "В томе базы свободно"
check "preflight full pg volume: no trial db made" "$(grep -c 'createdb' "$LOG")" 0
check "preflight full pg volume: no commit file" "$([[ -e $PRE/commit ]] && echo yes || echo no)" no

# The old backup.sh can hand over a cut dump (valid gzip, no end line) → STOP before the trial restore.
fresh
out=$(STUB_DUMP_END='' bash "$HERE/release_preflight.sh" 0.12.0 2>&1); rc=$?
check "preflight cut dump: exit 1" "$rc" 1
has "preflight cut dump: says so" "$out" "Копия базы неполная"
check "preflight cut dump: no commit file" "$([[ -e $PRE/commit ]] && echo yes || echo no)" no
# Fewer people in the copy than on the server → STOP, nothing recorded.
fresh
out=$(STUB_LIVE_USERS=4 bash "$HERE/release_preflight.sh" 0.12.0 2>&1); rc=$?
check "preflight row counts differ: exit 1" "$rc" 1
has "preflight row counts differ: says so" "$out" "а на сервере сейчас 4"
check "preflight row counts differ: no commit file" "$([[ -e $PRE/commit ]] && echo yes || echo no)" no

# A dump that does not carry the migrations → STOP, temp db dropped, nothing recorded.
fresh
out=$(STUB_MIG=0 bash "$HERE/release_preflight.sh" 0.12.0 2>&1); rc=$?
check "preflight bad dump: exit 1" "$rc" 1
has "preflight bad dump: temp db dropped" "$(cat "$LOG")" "dropdb --if-exists"
check "preflight bad dump: no commit file" "$([[ -e $PRE/commit ]] && echo yes || echo no)" no

# ── rollback ─────────────────────────────────────────────────────────────
fresh
bash "$HERE/release_preflight.sh" 0.12.0 >/dev/null 2>&1
echo 'SINHRON_DB_PASSWORD=after-update' >>"$SRV/.env"
ROLL=$PRE/release_rollback.sh
unset SINHRON_SERVER_DIR # the copy finds the server by the server_dir file
: >"$LOG"
before=$(snapshot)
out=$(bash "$ROLL" --dry-run 0.12.0 2>&1 </dev/null); rc=$?
check "rollback dry-run: exit 0" "$rc" 0
check "rollback dry-run: changes nothing" "$(snapshot)" "$before"
check "rollback dry-run: no docker" "$(grep -c '^docker' "$LOG")" 0

out=$(echo yes | bash "$ROLL" 0.12.0 2>&1); rc=$?
check "rollback wrong word: exit 1" "$rc" 1
has "rollback wrong word: cancelled" "$out" "Отменено"
check "rollback wrong word: changes nothing" "$(snapshot)" "$before"
check "rollback wrong word: no docker" "$(grep -c '^docker' "$LOG")" 0

out=$(echo ОТКАТ | STUB_GIT_DIRTY=' M server/x' bash "$ROLL" 0.12.0 2>&1); rc=$?
check "rollback dirty tree: exit 1" "$rc" 1
check "rollback dirty tree: changes nothing" "$(snapshot)" "$before"

mv "$PRE/env" "$PRE/env.gone"
envsum=$(cksum "$SRV/.env")
out=$(echo ОТКАТ | bash "$ROLL" 0.12.0 2>&1); rc=$?
check "rollback no env copy: exit 1" "$rc" 1
check "rollback no env copy: .env untouched" "$(cksum "$SRV/.env")" "$envsum"
check "rollback no env copy: .env not empty" "$([[ -s $SRV/.env ]] && echo yes)" yes
check "rollback no env copy: no docker" "$(grep -c '^docker' "$LOG")" 0
mv "$PRE/env.gone" "$PRE/env"

: >"$LOG"
out=$(echo ОТКАТ | bash "$ROLL" 0.12.0 2>&1); rc=$?
check "rollback: exit 0" "$rc" 0
order=$(grep -E 'compose .* stop sinhron-server|git .*checkout|compose .* build sinhron-server|^restore.sh|compose .* up -d' "$LOG" \
  | sed -E 's/^docker compose -f docker-compose.yml //; s/^git .*checkout.*/git checkout/; s/^restore.sh .*/restore.sh/' | tr '\n' '|')
check "rollback: order" "$order" "git checkout|build sinhron-server|stop sinhron-server|restore.sh|up -d --build postgres sinhron-server caddy|up -d --force-recreate --no-deps caddy|"
has "rollback: checkout of the recorded commit" "$(cat "$LOG")" "checkout --quiet --detach $COMMIT"
has "rollback: restore.sh args" "$(cat "$LOG")" "restore.sh $PRE $(cat "$PRE/stamp") --yes"
hasnt "rollback: ntfy never touched" "$(grep -E 'up -d|build|stop' "$LOG")" ntfy
check "rollback: .env restored" "$(cmp -s "$PRE/env" "$SRV/.env" && echo same)" same
check "rollback: .env mode" "$(mode "$SRV/.env")" 600
has "rollback: previous .env kept" "$(cat "$SRV/.env.before-rollback-0.12.0")" "after-update"
check "rollback: previous .env mode" "$(mode "$SRV/.env.before-rollback-0.12.0")" 600
hasnt "rollback: no secret in output" "$out" realsecretvalue
out=$(echo ROLLBACK | bash "$ROLL" 0.12.0 2>&1); rc=$?
check "rollback: ROLLBACK accepted too" "$rc" 0

# The old image does not build → the running server is never stopped, .env stays, code goes back.
: >"$LOG"; envsum=$(cksum "$SRV/.env")
out=$(echo ОТКАТ | STUB_BUILD_FAIL=1 bash "$ROLL" 0.12.0 2>&1); rc=$?
check "rollback build fails: exit 1" "$rc" 1
has "rollback build fails: says the server still runs" "$out" "сервер РАБОТАЕТ по-прежнему"
check "rollback build fails: server not stopped" "$(grep -c 'stop sinhron-server' "$LOG")" 0
check "rollback build fails: no restore" "$(grep -c '^restore.sh' "$LOG")" 0
check "rollback build fails: .env untouched" "$(cksum "$SRV/.env")" "$envsum"
check "rollback build fails: code put back" "$(grep -c 'checkout --quiet --detach' "$LOG")" 2

# Too little room → STOP before the code, the server or .env are touched.
: >"$LOG"; envsum=$(cksum "$SRV/.env")
out=$(echo ОТКАТ | STUB_DF=3 bash "$ROLL" 0.12.0 2>&1); rc=$?
check "rollback low disk: exit 1" "$rc" 1
has "rollback low disk: says so" "$out" "для отката нужно около"
check "rollback low disk: nothing stopped, built or checked out" "$(grep -cE 'stop sinhron-server| build |checkout' "$LOG")" 0
check "rollback low disk: .env untouched" "$(cksum "$SRV/.env")" "$envsum"
# Caddy keeps the new version's settings file unless it is recreated (the stub compose has no livekit / coturn).
: >"$LOG"
out=$(echo ОТКАТ | bash "$ROLL" 0.12.0 2>&1); rc=$?
check "rollback: exit 0 with the settings restart" "$rc" 0
has "rollback: caddy recreated with the old settings file" "$(cat "$LOG")" "up -d --force-recreate --no-deps caddy"

# restore.sh fails (dropped database, cut connection) → STOP that says to run
# the rollback again; the rerun goes through and keeps the first saved .env.
: >"$LOG"
out=$(echo ОТКАТ | STUB_RESTORE_FAIL=1 bash "$ROLL" 0.12.0 2>&1); rc=$?
check "rollback restore fails: exit 1" "$rc" 1
has "rollback restore fails: says to run it again" "$out" "запустите этот же откат ещё раз"
check "rollback restore fails: the other services are not started" "$(grep -c ' up -d' "$LOG")" 0
saved=$(cksum <"$SRV/.env.before-rollback-0.12.0")
out=$(echo ОТКАТ | bash "$ROLL" 0.12.0 2>&1); rc=$?
check "rollback rerun after a failed restore: exit 0" "$rc" 0
check "rollback rerun: the first saved .env is kept" "$(cksum <"$SRV/.env.before-rollback-0.12.0")" "$saved"

# A newer dump lying in the pre dir is not taken: restore.sh gets the trial-restored date.
: >"$LOG"; cp "$PRE/sinhron-$(cat "$PRE/stamp").sql.gz.gpg" "$PRE/sinhron-2099-01-01.sql.gz.gpg"
out=$(echo ОТКАТ | bash "$ROLL" 0.12.0 2>&1); rc=$?
has "rollback two dumps: the recorded date" "$(cat "$LOG")" "restore.sh $PRE $(cat "$PRE/stamp") --yes"
rm -f "$PRE/sinhron-2099-01-01.sql.gz.gpg"

# No stamp → nothing starts.
: >"$LOG"; mv "$PRE/stamp" "$PRE/stamp.gone"
out=$(echo ОТКАТ | bash "$ROLL" 0.12.0 2>&1); rc=$?
check "rollback no stamp: exit 1" "$rc" 1
check "rollback no stamp: no docker" "$(grep -c '^docker' "$LOG")" 0
mv "$PRE/stamp.gone" "$PRE/stamp"

# ── postcheck ────────────────────────────────────────────────────────────
fresh
out=$(bash "$HERE/release_postcheck.sh" --dry-run 2>&1); rc=$?
check "postcheck dry-run: exit 0" "$rc" 0
check "postcheck dry-run: no calls" "$(wc -l <"$LOG" | tr -d ' ')" 0

before=$(snapshot)
out=$(bash "$HERE/release_postcheck.sh" 0.12.0 2>&1); rc=$?
check "postcheck: exit 0" "$rc" 0
has "postcheck: summary" "$(tail -1 <<<"$out")" "Всё в порядке"
has "postcheck: migrations counted" "$out" "Миграции применены: 2 из 2"
has "postcheck: domain from sinhron.conf" "$(cat "$LOG")" "https://chat.example.com/_healthz"
check "postcheck: read-only" "$(snapshot)" "$before"
hasnt "postcheck: no secret in output" "$out" realsecretvalue

touch "$SRV/migrations/3_c.sql"
out=$(bash "$HERE/release_postcheck.sh" 2>&1); rc=$?
check "postcheck migrations differ: exit 1" "$rc" 1
has "postcheck migrations differ: says so" "$out" "[СТОП] Миграции: в коде 3, в базе '2'"
rm "$SRV/migrations/3_c.sql"

printf 'postgres running healthy\nsinhron-server running unhealthy\ncaddy running \nntfy running \n' >"$STUB/ps"
out=$(bash "$HERE/release_postcheck.sh" 2>&1); rc=$?
check "postcheck unhealthy: exit 1" "$rc" 1
has "postcheck unhealthy: says so" "$out" "[СТОП] Контейнер sinhron-server: unhealthy"

printf 'postgres running healthy\nsinhron-server running healthy\ncaddy running \n' >"$STUB/ps"
out=$(bash "$HERE/release_postcheck.sh" 2>&1); rc=$?
check "postcheck ntfy missing: exit 1" "$rc" 1
has "postcheck ntfy missing: says so" "$out" "[СТОП] Контейнер ntfy не работает"

fresh
echo 'WARN startup migration failed — /_readyz will report not-ready error=migration failed: x' >"$STUB/logs"
out=$(bash "$HERE/release_postcheck.sh" 2>&1); rc=$?
check "postcheck migration failed in log: exit 1" "$rc" 1
has "postcheck migration failed in log: a migration error" "$out" "[СТОП] В журнале сервера: migration failed"
# The same log line when the server never got into the database: not a rollback case.
echo 'Error: startup migration failed: migration failed: error returned from database: password authentication failed for user "sinhron"' >"$STUB/logs"
out=$(bash "$HERE/release_postcheck.sh" 0.12.0 2>&1); rc=$?
check "postcheck db login failed: exit 1" "$rc" 1
has "postcheck db login failed: not called a migration error" "$out" "это НЕ ошибка миграции"
has "postcheck db login failed: no restore" "$out" "базу НЕ восстанавливать"
hasnt "postcheck db login failed: no rollback advice" "$out" "при сомнении — откат"
: >"$STUB/logs"
out=$(STUB_COTURN_CONF=user-quota=24 bash "$HERE/release_postcheck.sh" 2>&1); rc=$?
check "postcheck coturn on the old file: exit 1" "$rc" 1
has "postcheck coturn on the old file: says so" "$out" "coturn работает со СТАРЫМ файлом настроек"
out=$(STUB_COTURN_CONF='' bash "$HERE/release_postcheck.sh" 2>&1); rc=$?
check "postcheck coturn unreadable: only a warning" "$rc" 0
# Optional settings left empty are a note, not a failure.
cp "$SRV/.env" "$SRV/.env.keep"
sed -i -e '/^APNS_/d' -e '/^SINHRON_TURN_HOSTNAME=/d' -e '/^SINHRON_LIVEKIT_HOSTNAME=/d' "$SRV/.env"
out=$(bash "$HERE/release_postcheck.sh" 2>&1); rc=$?
check "postcheck optional settings empty: exit 0" "$rc" 0
has "postcheck optional settings empty: APNs note" "$out" "Уведомления iPhone (APNs) не настроены"
has "postcheck optional settings empty: TURN note" "$out" "нет SINHRON_TURN_HOSTNAME"
has "postcheck optional settings empty: LiveKit note" "$out" "нет SINHRON_LIVEKIT_HOSTNAME"
mv "$SRV/.env.keep" "$SRV/.env"
out=$(STUB_WS=502 bash "$HERE/release_postcheck.sh" 2>&1); rc=$?
has "postcheck ws 502" "$out" "/v1/sync ответил '502'"
sed -i '/^APNS_KEY_ID=/d' "$SRV/.env"
out=$(bash "$HERE/release_postcheck.sh" 2>&1); rc=$?
has "postcheck apns missing: name" "$out" "в .env пусто: APNS_KEY_ID"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
