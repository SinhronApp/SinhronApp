#!/usr/bin/env bash
# Before a server update: checks, a fresh encrypted backup, a trial restore of
# it into a temporary database, and a record of the state to roll back to.
#
#   release_preflight.sh [--dry-run] <version>        e.g. 0.12.0, as root
#
# Runs against the server tree as it is BEFORE the new code is checked out
# (SINHRON_SERVER_DIR; default: the tree this script sits in, else
# /opt/sinhron/server) and uses that tree's scripts/backup.sh. Writes
# $RELEASE_BACKUP_ROOT/pre-<version>/ (default /root/backups): the backup
# files, commit, images.txt, migrations-before.txt, env (600), server_dir and
# a copy of release_rollback.sh (taken from next to this script).
# Never touches the live database. Messages are for the owner — in Russian.
set -euo pipefail

TMP='' TDB=''
ok() { printf '[ok] %s\n' "$*"; }
stop() { printf '[СТОП] %s\n       Что делать: %s\n' "$1" "$2" >&2; exit 1; }
compose() { docker compose -f docker-compose.yml "$@"; }
env_get() { sed -n "s/^$1=//p" .env | tail -1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"; }
db() { compose exec -T postgres psql -At -v ON_ERROR_STOP=1 -U sinhron -d "$1" -c "$2"; }
cleanup() {
  [[ -n $TMP ]] && rm -rf "$TMP"
  if [[ -n $TDB ]]; then compose exec -T postgres dropdb --if-exists -U sinhron "$TDB" >/dev/null 2>&1 || true; fi
}

main() {
  local dry=0 version='' a
  for a in "$@"; do
    case $a in
      --dry-run) dry=1 ;;
      *) version=$a ;;
    esac
  done
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Запуск: release_preflight.sh [--dry-run] <версия, например 0.12.0>" >&2; exit 2; }

  local self server pre conf pass
  self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  server=${SINHRON_SERVER_DIR:-}
  if [[ -z $server ]]; then
    if [[ -f $self/../docker-compose.yml ]]; then server=$(cd "$self/.." && pwd); else server=/opt/sinhron/server; fi
  fi
  pre=${RELEASE_BACKUP_ROOT:-/root/backups}/pre-$version
  conf=${SINHRON_CONF:-/etc/sinhron/sinhron.conf}
  pass=${SINHRON_BACKUP_PASSFILE:-$(dirname "$conf")/backup-pass}

  [[ -f $server/docker-compose.yml && -x $server/scripts/backup.sh ]] \
    || stop "В $server нет сервера Sinhron (docker-compose.yml, scripts/backup.sh)" "укажите папку: SINHRON_SERVER_DIR=/путь/к/server"
  [[ -f $self/release_rollback.sh ]] || stop "Рядом со мной нет release_rollback.sh" "положите его в $self и запустите снова"
  cd "$server"
  ((dry)) && echo "[dry-run] ничего не меняю, только проверяю и показываю план"

  # 1. Disk — the same 15 GB install.sh asks for (it dies below that).
  local gb
  gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  ((${gb:-0} >= 15)) || stop "Свободно на диске ${gb:-?} ГБ — нужно хотя бы 15 ГБ" "освободите место (docker image prune -f, старые копии) и запустите снова"
  ok "Свободно на диске $gb ГБ"

  # 2. Placeholders install.sh would silently replace (render_env): a new
  # random database password in .env that the database does not know.
  [[ -f .env ]] || stop "Нет файла $server/.env" "это не рабочий сервер или не та папка — ничего не обновляйте"
  local bad=() v
  v=$(env_get SINHRON_DB_PASSWORD)
  [[ -z $v || $v == dev_only || $v == change-me-before-prod || $v == GENERATE_* ]] && bad+=(SINHRON_DB_PASSWORD)
  v=$(env_get LIVEKIT_KEYS)
  [[ -z $v || $v == devkey:* || $v == GENERATE_* ]] && bad+=(LIVEKIT_KEYS)
  v=$(env_get TURN_SHARED_SECRET)
  [[ -z $v || $v == devturnsecret* || $v == GENERATE_* ]] && bad+=(TURN_SHARED_SECRET)
  ((${#bad[@]} == 0)) || stop "В .env пустые или учебные значения: ${bad[*]} (всего ${#bad[@]})" \
    "НЕ обновляйте: установщик запишет новый пароль в .env, а в базе останется старый — сервер не войдёт в базу. Покажите это сообщение помощнику"
  ok "В .env нет учебных паролей"

  # 3. Backup password.
  [[ -r $pass && -s $pass ]] || stop "Нет файла с паролем копий: $pass" "укажите его: SINHRON_BACKUP_PASSFILE=/путь/к/файлу и запустите снова"
  ok "Пароль копий на месте ($pass)"

  if ((dry)); then
    echo "[dry-run] сделал бы: копию базы, медиа и .env в $pre (scripts/backup.sh)"
    echo "[dry-run] сделал бы: пробное восстановление копии во временную базу и её удаление"
    echo "[dry-run] сделал бы: записал в $pre файлы commit, images.txt, migrations-before.txt, env, server_dir, release_rollback.sh"
    echo "Готово (dry-run). Ничего не изменено."
    return 0
  fi

  # Run once: a second run after the update would overwrite the rollback
  # point (dump, commit, env) with the already updated state. `commit` is
  # written last, so a first run that broke midway can be repeated.
  [[ ! -s $pre/commit ]] || stop "Точка отката $pre уже записана (коммит $(cut -c1-12 "$pre/commit"))" \
    "второй раз эту проверку не запускают. Обновление уже сделано — папку НЕ трогайте. Обновление ещё не делали и нужна свежая копия — mv $pre $pre.old и запустите снова"

  [[ -z $(ls -A "$pre" 2>/dev/null) ]] || stop "В $pre остались файлы от неудавшегося запуска" \
    "mv $pre $pre.bad и запустите снова"

  # 4. Fresh backup.
  install -d -m 700 "$pre"
  if ! SINHRON_BACKUP_PASSFILE=$pass "$server/scripts/backup.sh" "$pre"; then
    rm -f "$pre"/*.part "$pre"/*.gpg # the dir was empty before; half-written files must not fill the disk
    stop "Копия не сделалась" "посмотрите ошибку выше; сервер не тронут, обновлять нельзя"
  fi
  local dump media
  dump=$(find "$pre" -maxdepth 1 -name 'sinhron-*.sql.gz.gpg' ! -name 'sinhron-media-*' | sort | tail -1)
  media=$(find "$pre" -maxdepth 1 -name 'sinhron-media-*.tgz.gpg' | sort | tail -1)
  [[ -s $dump && -s $media ]] || stop "В $pre нет зашифрованных файлов копии (база и медиа)" "обновлять нельзя; покажите вывод выше помощнику"
  ok "Копия сделана: $(basename "$dump"), $(basename "$media")"

  # 5. Trial restore into a temporary database (dropped on any exit).
  trap cleanup EXIT
  TMP=$(umask 077 && mktemp -d)
  gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$pass" --status-file "$TMP/status" \
    -d -o "$TMP/dump.sql.gz" "$dump" || stop "Копия не расшифровывается паролем из $pass" "обновлять нельзя: из такой копии не откатиться"
  grep -q '^\[GNUPG:\] DECRYPTION_OKAY' "$TMP/status" || stop "Копия не зашифрована паролем копий" "обновлять нельзя; покажите это помощнику"
  gzip -t "$TMP/dump.sql.gz" || stop "Файл копии повреждён" "запустите меня ещё раз"
  # The backup was made by the OLD backup.sh, which gives a failed or cut
  # pg_dump the name of a good copy. pg_dump ends a whole dump with this line.
  gunzip -c "$TMP/dump.sql.gz" | tail -n 20 | grep -q '^-- PostgreSQL database dump complete' \
    || stop "Копия базы неполная (pg_dump не дошёл до конца)" "обновлять нельзя; проверьте docker compose ps (postgres должен работать) и запустите меня ещё раз"
  # The media archive too: a broken one would otherwise show up in restore.sh, with the server already stopped.
  gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$pass" --status-file "$TMP/status-media" -d "$media" \
    | tar -tzf - >/dev/null || stop "Архив файлов (медиа) в копии повреждён или не расшифровывается" "обновлять нельзя; покажите это помощнику"
  grep -q '^\[GNUPG:\] DECRYPTION_OKAY' "$TMP/status-media" || stop "Архив файлов (медиа) не зашифрован паролем копий" "обновлять нельзя; покажите это помощнику"
  ok "Архив файлов (медиа) читается"
  # Trial databases left by a run that was killed (the EXIT trap never fired).
  local old
  for old in $(db postgres "SELECT datname FROM pg_database WHERE datname ~ '^sinhron_trial_[0-9]+\$'" 2>/dev/null || true); do
    [[ $old =~ ^sinhron_trial_[0-9]+$ ]] || continue
    compose exec -T postgres dropdb --if-exists -U sinhron "$old" >/dev/null 2>&1 || true
    ok "Убрал забытую временную базу $old"
  done
  # The trial copy lives in the same Postgres volume as the live database:
  # a full volume would stop the live one. Asked only when both numbers come back.
  local dbsize pgfree
  dbsize=$(db sinhron 'SELECT pg_database_size(current_database())' 2>/dev/null || true)
  pgfree=$(compose exec -T postgres df -Pk /var/lib/postgresql/data 2>/dev/null | awk 'NR==2 {print $4}' || true)
  if [[ $dbsize =~ ^[0-9]+$ && $pgfree =~ ^[0-9]+$ ]] && ((pgfree * 1024 < dbsize * 2)); then
    stop "В томе базы свободно $((pgfree / 1024)) МБ, а для пробного восстановления нужно около $((dbsize * 2 / 1048576)) МБ" \
      "освободите место на диске и запустите снова; рабочая база не тронута, обновлять пока нельзя"
  fi
  TDB=sinhron_trial_$$
  compose exec -T postgres createdb -U sinhron "$TDB" || stop "Не создалась временная база" "проверьте: docker compose ps (postgres должен работать)"
  gunzip -c "$TMP/dump.sql.gz" | compose exec -T postgres psql -q -v ON_ERROR_STOP=1 -U sinhron -d "$TDB" >/dev/null \
    || stop "Копия не загружается в базу (пробное восстановление не прошло)" "обновлять нельзя; покажите ошибку выше помощнику"
  local mig live users devices live_users live_devices
  { mig=$(db "$TDB" 'SELECT count(*) FROM _sqlx_migrations WHERE success') && users=$(db "$TDB" 'SELECT count(*) FROM users') \
    && devices=$(db "$TDB" 'SELECT count(*) FROM devices') && live=$(db sinhron 'SELECT count(*) FROM _sqlx_migrations WHERE success'); } \
    || stop "В восстановленной копии нет нужных таблиц (ошибка выше)" "обновлять нельзя; покажите ошибку помощнику"
  [[ $mig =~ ^[0-9]+$ && $mig -gt 0 && $mig == "$live" ]] \
    || stop "В копии миграций: '$mig', на сервере: '$live' — копия неполная" "обновлять нельзя; запустите меня ещё раз"
  # The same people and devices as the live database has right now.
  live_users=$(db sinhron 'SELECT count(*) FROM users' 2>/dev/null || true)
  live_devices=$(db sinhron 'SELECT count(*) FROM devices' 2>/dev/null || true)
  [[ $users == "$live_users" && $devices == "$live_devices" ]] \
    || stop "В копии людей $users и устройств $devices, а на сервере сейчас $live_users и $live_devices" \
      "если кто-то зарегистрировался в эту минуту — запустите меня ещё раз; повторилось — обновлять нельзя, покажите помощнику"
  ok "Пробное восстановление прошло: миграций $mig, людей $users, устройств $devices — как на сервере"
  cleanup
  TDB='' TMP=''
  trap - EXIT
  ok "Временная база удалена, рабочая не тронута"

  # 6. What to roll back to.
  git -C "$server" rev-parse HEAD >"$pre/commit" || stop "Не узнал текущий коммит кода" "проверьте, что $server — папка git"
  compose images >"$pre/images.txt"
  echo "$mig" >"$pre/migrations-before.txt"
  basename "$dump" | sed -E 's/^sinhron-(.*)\.sql\.gz\.gpg$/\1/' >"$pre/stamp" # the dump that was trial-restored
  install -m 600 .env "$pre/env"
  echo "$server" >"$pre/server_dir"
  install -m 700 "$self/release_rollback.sh" "$pre/release_rollback.sh"
  ok "Записано: коммит $(cut -c1-12 "$pre/commit"), образы, настройки, скрипт отката"

  # The backup and the trial restore took room: the installer needs 15 GB too.
  gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  ((${gb:-0} >= 15)) || stop "После копии на диске осталось ${gb:-?} ГБ — установщику нужно 15 ГБ" \
    "точка отката записана и цела; освободите место (docker image prune -f) и переходите к обновлению — меня заново не запускайте"
  echo "Готово. Откат возможен из $pre"
}

main "$@"
