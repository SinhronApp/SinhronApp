#!/usr/bin/env bash
# Roll the server back to the state release_preflight.sh recorded.
#
#   release_rollback.sh [--dry-run] <version>         e.g. 0.12.0, as root
#
# Best run from the copy in $RELEASE_BACKUP_ROOT/pre-<version>/ (default
# /root/backups). Server tree: SINHRON_SERVER_DIR, else the `server_dir` file
# of the pre dir. Order (each step fixes a defect of the old hand-written
# instruction): check everything → stop sinhron-server → .env back (temp file +
# mv) → git checkout of the old commit → BUILD the old server image (restore.sh
# starts the server at its end; the new image would re-apply the new
# migrations to the restored database) → that tree's scripts/restore.sh → the
# other services with the old compose, except ntfy (its own database was
# upgraded by the new version and cannot go back).
# The whole body is in main(): the checkout may replace this file mid-run.
set -euo pipefail

ok() { printf '[ok] %s\n' "$*"; }
stop() { printf '[СТОП] %s\n       Что делать: %s\n' "$1" "$2" >&2; exit 1; }
compose() { docker compose -f docker-compose.yml "$@"; }

main() {
  local dry=0 version='' a
  for a in "$@"; do
    case $a in
      --dry-run) dry=1 ;;
      *) version=$a ;;
    esac
  done
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Запуск: release_rollback.sh [--dry-run] <версия, например 0.12.0>" >&2; exit 2; }

  local pre conf pass server commit f stamp dumpfile newhead
  pre=${RELEASE_BACKUP_ROOT:-/root/backups}/pre-$version
  conf=${SINHRON_CONF:-/etc/sinhron/sinhron.conf}
  pass=${SINHRON_BACKUP_PASSFILE:-$(dirname "$conf")/backup-pass}

  cat <<MSG
ВНИМАНИЕ. Откат сервера к состоянию до версии $version.
  - Откат годится, только пока НИ ОДИН телефон не открыл новую версию приложения:
    телефон с $version обратно на старую версию не вернуть.
  - Всё, что написано после копии (её дата — ниже), пропадёт.
MSG

  # 1. Everything needed is there — before anything changes.
  [[ -d $pre ]] || stop "Нет папки $pre" "откат без неё невозможен; проверьте номер версии"
  for f in commit env; do
    [[ -s $pre/$f ]] || stop "В $pre нет файла $f" "откат не начат, сервер не тронут; покажите это помощнику"
  done
  # Exactly the dump preflight trial-restored — restore.sh alone would take the newest file in the dir.
  stamp=$(cat "$pre/stamp" 2>/dev/null || true)
  [[ $stamp =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || stop "В $pre нет файла stamp (дата проверенной копии)" "откат не начат, сервер не тронут; покажите это помощнику"
  dumpfile=$pre/sinhron-$stamp.sql.gz.gpg
  [[ -s $dumpfile && -s $pre/sinhron-media-$stamp.tgz.gpg ]] \
    || stop "В $pre нет файлов копии за $stamp (sinhron-$stamp.sql.gz.gpg, sinhron-media-$stamp.tgz.gpg)" "откат не начат, сервер не тронут"
  if [[ -n $(find "$dumpfile" -mtime +1) && ${RELEASE_ROLLBACK_OLD:-0} != 1 ]]; then
    stop "Копия старше двух суток ($(date -r "$dumpfile" '+%F %H:%M')) — откат сотрёт всё, что написано после неё" \
      "проверьте номер версии. Если это действительно нужно — покажите помощнику (RELEASE_ROLLBACK_OLD=1)"
  fi
  [[ -r $pass && -s $pass ]] || stop "Нет файла с паролем копий: $pass" "укажите его: SINHRON_BACKUP_PASSFILE=/путь/к/файлу"
  # Room for the restore (the media archive is unpacked twice: decrypted, then
  # into the volume) and the image build — checked while the server still runs.
  local gb need
  gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  need=$(($(du -k "$pre/sinhron-media-$stamp.tgz.gpg" | cut -f1) * 2 / 1048576 + 6))
  ((${gb:-0} >= need)) || stop "Свободно на диске ${gb:-?} ГБ, для отката нужно около $need ГБ" \
    "откат не начат, сервер работает как работал; освободите место (docker image prune -f) и запустите снова"
  server=${SINHRON_SERVER_DIR:-}
  [[ -z $server && -s $pre/server_dir ]] && server=$(<"$pre/server_dir")
  [[ -n $server && -f $server/docker-compose.yml && -f $server/.env ]] \
    || stop "Не нашёл папку сервера ('$server')" "укажите её: SINHRON_SERVER_DIR=/путь/к/server"
  commit=$(<"$pre/commit")
  [[ $commit =~ ^[0-9a-f]{40}$ ]] || stop "В $pre/commit не id коммита" "откат не начат; покажите это помощнику"
  git -C "$server" cat-file -e "$commit^{commit}" || stop "В git нет старого коммита $commit" "откат не начат; покажите это помощнику"
  [[ -z $(git -C "$server" status --porcelain --untracked-files=no) ]] \
    || stop "В папке кода есть несохранённые правки (git status)" "сохраните их: git -C $server stash — и запустите снова"
  cd "$server"
  ok "Для отката всё есть: настройки, пароль, коммит ${commit:0:12}"
  echo "     Копия от $(date -r "$dumpfile" '+%F %H:%M'). Всё, что написано ПОСЛЕ неё, пропадёт."

  if ((dry)); then
    cat <<MSG
[dry-run] ничего не меняю. Сделал бы по порядку:
  1. git checkout --detach $commit
  2. собрал старый образ: docker compose build sinhron-server (сервер в это время ещё работает)
  3. остановил sinhron-server
  4. вернул .env из $pre/env (текущий сохранил как .env.before-rollback-$version)
  5. scripts/restore.sh $pre $stamp --yes (база и медиа из копии, запуск сервера)
  6. поднял остальные сервисы старой версией, кроме ntfy; caddy / livekit / coturn пересоздал со старыми файлами настроек
  7. проверил, что сервер отвечает
MSG
    return 0
  fi

  local word=''
  printf 'Чтобы начать откат, напишите слово ОТКАТ и нажмите Enter: '
  read -r word || true
  [[ $word == ОТКАТ || $word == ROLLBACK ]] || { echo "Отменено. Ничего не изменено."; exit 1; }

  # 2. Old code and old image FIRST, while the server still runs: the build
  # takes minutes and needs the network — a failure here must not leave the
  # family without a server. (restore.sh starts sinhron-server at its end,
  # so the image must be the old one by then.)
  newhead=$(git -C "$server" rev-parse HEAD)
  git -C "$server" checkout --quiet --detach "$commit" \
    || stop "git checkout не прошёл" "сервер РАБОТАЕТ по-прежнему (новая версия), база не тронута; покажите ошибку помощнику"
  ok "Код: коммит ${commit:0:12}"
  if ! compose build sinhron-server; then
    git -C "$server" checkout --quiet --detach "$newhead" || true
    stop "Старый образ сервера не собрался" "сервер РАБОТАЕТ по-прежнему (новая версия), база не тронута, код возвращён; покажите ошибку выше помощнику"
  fi
  ok "Старый образ сервера собран"

  # 3. Nothing writes to the database from here on.
  compose stop sinhron-server || stop "Не остановился sinhron-server" "база и настройки не тронуты, но код и образ уже прежние: ничего не перезапускайте, запустите этот же откат ещё раз"
  ok "sinhron-server остановлен"

  # 4. .env — never written in place.
  [[ -e .env.before-rollback-$version ]] || install -m 600 .env ".env.before-rollback-$version" # a rerun keeps the first one
  install -m 600 "$pre/env" .env.rollback.tmp
  mv .env.rollback.tmp .env
  ok ".env возвращён (прежний — .env.before-rollback-$version)"

  # 5. Database + media (the old tree's restore.sh; it starts sinhron-server).
  echo "     (postgres вернётся на версию из старого docker-compose, 16.x; на живом сервере это не проверялось)"
  SINHRON_BACKUP_PASSFILE=$pass "$server/scripts/restore.sh" "$pre" "$stamp" --yes \
    || stop "Восстановление из копии не прошло" "запустите этот же откат ещё раз — это безопасно. НЕ запускайте сервер вручную. Не помогло — покажите ошибку выше помощнику"
  ok "База и медиа восстановлены, sinhron-server запущен"

  # 7. The rest on the old compose — not ntfy.
  local svcs
  svcs=$(compose config --services | grep -vx ntfy | tr '\n' ' ')
  [[ -n ${svcs// /} ]] || stop "Не получил список сервисов (docker compose config)" "покажите это помощнику"
  # shellcheck disable=SC2086 # a word list on purpose
  compose up -d --build $svcs || stop "Не все сервисы поднялись" "посмотрите: docker compose ps"
  ok "Остальные сервисы подняты (ntfy не трогал — он остаётся новым)"
  # A running container keeps its copy of a mounted settings file: without
  # this Caddy / LiveKit / coturn would go on with the NEW version's files.
  local cfg='' s
  for s in caddy livekit coturn; do [[ " $svcs " == *" $s "* ]] && cfg+="$s "; done
  if [[ -n $cfg ]]; then
    # shellcheck disable=SC2086 # a word list on purpose
    if compose up -d --force-recreate --no-deps $cfg; then
      ok "Перезапущены со старыми файлами настроек: $cfg"
    else
      echo "[!] Не удалось перезапустить $cfg со старыми настройками — сделайте вручную: cd $server && docker compose -f docker-compose.yml up -d --force-recreate $cfg"
    fi
  fi

  # 8. Answers?
  local dom deadline=$((SECONDS + ${RELEASE_WAIT_SECS:-180}))
  dom=$(sed -n 's/^SINHRON_PUBLIC_HOSTNAME=//p' .env | tail -1 | tr -d "\"'")
  if [[ -z $dom ]]; then
    echo "[!] В .env нет SINHRON_PUBLIC_HOSTNAME — ответ сервера не проверен; проверьте телефоном"
  else
  until curl -fsS --max-time 8 "https://$dom/_healthz" 2>/dev/null | grep -q '"sinhron-server"'; do
    ((SECONDS < deadline)) || stop "https://$dom/_healthz не отвечает" "посмотрите: docker compose ps и docker logs --tail 30 sinhron-server"
    sleep 5
  done
  ok "Сервер отвечает: https://$dom/_healthz"
  fi

  cat <<MSG
Откат сделан. Проверьте:
  - на телефоне со СТАРОЙ версией приложения: вход, сообщение туда и обратно, звонок;
  - новую версию приложения никому не выпускать (TestFlight / APK);
  - push на Android может не приходить до следующего обновления (ntfy остался новым).
MSG
}

main "$@"
