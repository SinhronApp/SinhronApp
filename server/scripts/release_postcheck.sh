#!/usr/bin/env bash
# After a server update: read-only checks that everything came up.
#
#   release_postcheck.sh [--dry-run] [<version>]      as root
#
# Changes nothing. Server tree: SINHRON_SERVER_DIR (default: the tree this
# script sits in, else /opt/sinhron/server). Prints "[ok] …" / "[СТОП] …" per
# check, then "Всё в порядке" or the failed checks (exit 1). Variable NAMES
# only — never values. Messages are for the owner — in Russian.
set -euo pipefail

FAILED=()
ok() { printf '[ok] %s\n' "$*"; }
warn() { printf '[!]  %s\n' "$*"; }
bad() { printf '[СТОП] %s\n       Что делать: %s\n' "$1" "$2"; FAILED+=("$1"); }
compose() { docker compose -f docker-compose.yml "$@"; }
env_get() { sed -n "s/^$1=//p" .env | tail -1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"; }

main() {
  local dry=0 version='' a
  for a in "$@"; do
    case $a in
      --dry-run) dry=1 ;;
      *) version=$a ;;
    esac
  done
  local self server conf since=${RELEASE_LOG_SINCE:-1h}
  self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  server=${SINHRON_SERVER_DIR:-}
  if [[ -z $server ]]; then
    if [[ -f $self/../docker-compose.yml ]]; then server=$(cd "$self/.." && pwd); else server=/opt/sinhron/server; fi
  fi
  conf=${SINHRON_CONF:-/etc/sinhron/sinhron.conf}
  [[ -f $server/docker-compose.yml && -f $server/.env ]] || { bad "В $server нет сервера Sinhron" "укажите папку: SINHRON_SERVER_DIR=/путь/к/server"; exit 1; }
  cd "$server"

  if ((dry)); then
    cat <<MSG
[dry-run] я и так ничего не меняю. Проверил бы:
  контейнеры; миграции (файлы = строки в базе, нет ошибок в журнале); /_healthz и /_readyz
  снаружи и с самого сервера; вход для приложений (/v1/sync); TURN; LiveKit; настройки push; ошибки в журнале.
MSG
    return 0
  fi

  local dom turn lk
  dom=$(sed -n 's/^SINHRON_DOMAIN[[:space:]]*=[[:space:]]*//p' "$conf" 2>/dev/null | tail -1 | sed -e 's/[[:space:]]*#.*$//' -e 's/^["'\'']//' -e 's/["'\'']$//')
  [[ -n $dom ]] || dom=$(env_get SINHRON_PUBLIC_HOSTNAME)
  turn=$(env_get SINHRON_TURN_HOSTNAME)
  lk=$(env_get SINHRON_LIVEKIT_HOSTNAME)

  # 1. Containers: every service of the compose file (with the profiles of
  # .env) runs; those with a healthcheck are healthy.
  local ps svc state health line n=0
  ps=$(compose ps -a --format '{{.Service}} {{.State}} {{.Health}}' 2>/dev/null || true)
  for svc in $(compose config --services 2>/dev/null || true); do
    n=$((n + 1))
    line=$(grep -m1 "^$svc " <<<"$ps" || true)
    read -r _ state health <<<"$line" || true
    if [[ ${state:-} != running ]]; then
      bad "Контейнер $svc не работает (${state:-нет})" "cd $server && docker compose -f docker-compose.yml logs --tail 30 $svc"
    elif [[ -n ${health:-} && $health != healthy ]]; then
      bad "Контейнер $svc: $health" "подождите минуту и запустите меня снова; не прошло — cd $server && docker compose -f docker-compose.yml logs --tail 30 $svc"
    else
      ok "Контейнер $svc работает${health:+ ($health)}"
    fi
  done
  ((n > 0)) || bad "Не получил список сервисов (docker compose config)" "проверьте, что docker работает: docker compose ps"

  # 2. Migrations: files in the tree == successful rows in the database.
  local files rows
  files=$(find migrations -maxdepth 1 -name '*.sql' | wc -l | tr -d ' ')
  rows=$(compose exec -T postgres psql -At -U sinhron -d sinhron -c 'SELECT count(*) FROM _sqlx_migrations WHERE success' 2>/dev/null || true)
  if [[ $rows =~ ^[0-9]+$ && $rows == "$files" ]]; then
    ok "Миграции применены: $rows из $files"
  else
    bad "Миграции: в коде $files, в базе '${rows:-нет ответа}'" "docker logs sinhron-server 2>&1 | grep -i migrat | tail — покажите помощнику; при сомнении — откат"
  fi
  if [[ -n $version && -s ${RELEASE_BACKUP_ROOT:-/root/backups}/pre-$version/migrations-before.txt ]]; then
    echo "     (до обновления было: $(<"${RELEASE_BACKUP_ROOT:-/root/backups}/pre-$version/migrations-before.txt"))"
  fi
  local logs
  local logs_read=1
  logs=$(compose logs --no-color --since "$since" sinhron-server 2>&1) || logs_read=0
  # src/lib.rs: warn!("startup migration failed — /_readyz will report not-ready"); src/db.rs: "migration failed: {e}"
  if ((!logs_read)); then
    warn "Журнал сервера прочитать не удалось — ошибки миграций по журналу не проверены"
  elif grep 'migration failed' <<<"$logs" | grep -qiE 'password authentication failed|pool timed out|connection refused|failed to lookup address|error communicating with database'; then
    # The same line is logged when the server never got INTO the database
    # (wrong password in .env, Postgres not up yet): nothing was migrated.
    bad "Сервер не вошёл в базу (в журнале: пароль не подошёл или база не ответила) — это НЕ ошибка миграции" \
      "базу НЕ восстанавливать и не откатывать. Сравните пароли: diff <(grep -E '^(SINHRON_DB|POSTGRES)' .env | sort) <(grep -E '^(SINHRON_DB|POSTGRES)' ${RELEASE_BACKUP_ROOT:-/root/backups}/pre-${version:-<версия>}/env | sort) — пусто значит одинаковые; затем docker compose -f docker-compose.yml up -d --wait и проверку снова"
  elif grep -q 'migration failed' <<<"$logs"; then
    bad "В журнале сервера: migration failed" "docker logs sinhron-server 2>&1 | grep 'migration failed' — покажите помощнику; при сомнении — откат"
  else
    ok "В журнале сервера нет ошибок миграций (за $since)"
  fi

  # 3. Health: from outside by name, and from this machine (through Caddy on 127.0.0.1).
  local body
  if body=$(curl -fsS --max-time 10 "https://$dom/_healthz" 2>/dev/null) && grep -q '"sinhron-server"' <<<"$body"; then
    ok "Сервер отвечает: https://$dom/_healthz  $body"
  else
    bad "https://$dom/_healthz не отвечает" "docker compose ps; docker logs --tail 20 sinhron-caddy"
  fi
  if curl -fsS --max-time 10 -o /dev/null "https://$dom/_readyz" 2>/dev/null; then
    ok "Сервер видит базу: https://$dom/_readyz"
  else
    bad "https://$dom/_readyz — сервер не готов (нет связи с базой или не прошли миграции)" "docker logs --tail 30 sinhron-server"
  fi
  if curl -fsS --max-time 10 -o /dev/null --resolve "$dom:443:127.0.0.1" "https://$dom/_healthz" 2>/dev/null; then
    ok "С самого сервера тоже отвечает (127.0.0.1:443)"
  else
    bad "С самого сервера https://$dom/_healthz (127.0.0.1:443) не отвечает" "docker logs --tail 20 sinhron-caddy"
  fi

  # 4. WebSocket (/v1/sync, src/ws.rs): our server agrees to open the channel
  # (HTTP 101). Login itself happens inside the channel and is NOT checked.
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --http1.1 --max-time 5 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Sec-WebSocket-Protocol: sinhron.v1' \
    "https://$dom/v1/sync" 2>/dev/null || true)
  if [[ $code == 101 ]]; then
    ok "Канал для приложений открывается (/v1/sync ответил 101; сам вход проверяется только с телефона)"
  else
    bad "Канал для приложений /v1/sync ответил '$code' вместо 101" "docker logs --tail 30 sinhron-server (503 — нет базы; 502 — сервер не запущен)"
  fi

  # 5. TURN: TLS on 443 under the TURN name (Caddy → coturn, deploy-guide §6.5)
  # and coturn's own TCP port on this machine. No real relay is tried.
  if [[ -z $turn ]]; then
    warn "TURN: в .env нет SINHRON_TURN_HOSTNAME — звонки через TURN по 443 не настроены (если так было и до обновления, это нормально)"
  elif timeout 15 openssl s_client -connect "$turn:443" -servername "$turn" -verify_hostname "$turn" </dev/null 2>/dev/null \
    | grep -q 'Verify return code: 0 (ok)'; then
    ok "TURN: сертификат на $turn:443 в порядке"
  else
    bad "TURN: $turn:443 не отвечает по TLS или сертификат не тот" "docker logs --tail 20 sinhron-caddy"
  fi
  if timeout 5 bash -c '</dev/tcp/127.0.0.1/3478' 2>/dev/null; then
    ok "TURN: coturn слушает порт 3478 (сам звонок через TURN проверяется только с телефона)"
  else
    bad "TURN: coturn не слушает порт 3478" "docker compose restart coturn; docker logs --tail 20 sinhron-coturn"
  fi

  # coturn really runs on the turnserver.conf that is on disk (a container
  # keeps its old copy of a mounted file until it is recreated).
  local inside
  if inside=$(docker exec sinhron-coturn cat /etc/coturn/turnserver.conf 2>/dev/null) && [[ -n $inside ]]; then
    if [[ $inside == "$(cat turnserver.conf 2>/dev/null)" ]]; then
      ok "TURN: coturn работает с текущим файлом настроек"
    else
      bad "TURN: coturn работает со СТАРЫМ файлом настроек" "cd $server && docker compose -f docker-compose.yml up -d --wait --force-recreate coturn — и проверку снова"
    fi
  else
    warn "TURN: не удалось прочитать настройки внутри контейнера coturn — не проверено"
  fi

  # 6. LiveKit through Caddy (the same GET / its own healthcheck does).
  if [[ -z $lk ]]; then
    warn "LiveKit: в .env нет SINHRON_LIVEKIT_HOSTNAME — групповые звонки не настроены (если так было и до обновления, это нормально)"
  elif curl -fsS --max-time 10 -o /dev/null "https://$lk/" 2>/dev/null; then
    ok "LiveKit отвечает: https://$lk/"
  else
    bad "LiveKit https://$lk/ не отвечает" "docker logs --tail 20 sinhron-livekit"
  fi

  # 7. Push settings — names only.
  local k missing=()
  for k in APNS_KEY_PATH APNS_KEY_ID APNS_TEAM_ID; do [[ -n $(env_get "$k") ]] || missing+=("$k"); done
  # APNs is optional (install.sh never writes APNS_*): all three empty is "not
  # set up", not a failure; only a half-filled set is.
  if ((${#missing[@]} == 0)); then
    ok "Push iPhone (APNs): настройки на месте"
  elif ((${#missing[@]} == 3)); then
    warn "Уведомления iPhone (APNs) не настроены: в .env нет APNS_KEY_PATH, APNS_KEY_ID, APNS_TEAM_ID — если так было и до обновления, это нормально"
  else
    bad "Push iPhone (APNs): в .env пусто: ${missing[*]}" "сравните с копией .env до обновления"
  fi
  if [[ ",$(env_get COMPOSE_PROFILES)," == *,ntfy,* ]]; then
    missing=()
    for k in SINHRON_NTFY_HOSTNAME SINHRON_UNIFIEDPUSH_HOSTS SINHRON_NTFY_TOKEN; do [[ -n $(env_get "$k") ]] || missing+=("$k"); done
    if ((${#missing[@]} == 0)); then ok "Push Android (ntfy): настройки на месте"; else bad "Push Android (ntfy): в .env пусто: ${missing[*]}" "запустите установщик ещё раз: он дописывает эти строки"; fi
  else
    warn "Push Android (ntfy) выключен (в COMPOSE_PROFILES нет ntfy)"
  fi
  k=$(env_get SINHRON_FCM_SERVICE_ACCOUNT)
  if [[ -r ${k:-/etc/sinhron/fcm/service-account.json} ]]; then ok "Push Android (FCM): файл ключа на месте"; else warn "Push Android (FCM) не настроен (нет файла ключа) — если его и не было, это нормально"; fi

  # 8. Warn only.
  n=$(grep -cE 'ERROR|panic' <<<"$logs" || true)
  if ((n > 0)); then
    warn "В журнале сервера за $since строк с ERROR/panic: $n — посмотрите: docker logs sinhron-server 2>&1 | grep -E 'ERROR|panic' | tail"
  else
    ok "В журнале сервера нет ERROR/panic (за $since)"
  fi

  echo
  if ((${#FAILED[@]} == 0)); then
    echo "Всё в порядке"
  else
    echo "НЕ в порядке (${#FAILED[@]}):"
    printf '  - %s\n' "${FAILED[@]}"
    exit 1
  fi
}

main "$@"
