#!/usr/bin/env bash
# Sinhron server installer — a clean Ubuntu 22.04 / 24.04 to a running server
# in one command (ADR-032, docs/deploy-guide.md §0.5).
#
#   sudo ./install.sh                 ask: answer questions now, or write a config to edit
#   sudo ./install.sh --interactive   answer questions now (they are saved to the config)
#   sudo ./install.sh --write-config  only write the config template, then edit and rerun
#   sudo ./install.sh --yes           use the config as is, ask nothing (automation)
#   sudo ./install.sh --yes --commit <40-hex id>   update to exactly that commit
#   sudo ./install.sh --dry-run       show what would be done, change nothing
#
# Safe to run again: every step checks what is already there. Rerunning is
# also how you update: with --commit the code moves to that commit (and only
# then — deploy-deps:5), images are rebuilt. Secrets are
# generated once and kept in server/.env; the config holds no secrets.
#
# Everything is logged to /var/log/sinhron-install.log.

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# ── Constants ────────────────────────────────────────────────────────────

readonly INSTALLER_VERSION=1
readonly CONFIG_DIR_DEFAULT=/etc/sinhron
readonly LOG_FILE_DEFAULT=/var/log/sinhron-install.log
readonly LOCK_FILE=/run/sinhron-install.lock
readonly DEFAULT_REPO_URL=https://github.com/SinhronApp/SihnronApp.git
readonly DEFAULT_BRANCH=main
readonly DEFAULT_INSTALL_DIR=/opt/sinhron
readonly QR_PREFIX=sinhron-server:
# Other sites on this server (status 203): Caddy imports
# <CADDY_SITES_DIR>/*.caddy and joins the shared Docker network EDGE_NETWORK.
# Fixed paths — docker-compose.yml mounts exactly this folder.
readonly CADDY_SITES_DIR=/etc/sinhron/caddy-sites
readonly EDGE_NETWORK=edge
# Ports the server needs (ADR-016): web + TURN/TLS, coturn, LiveKit media.
readonly -a FIREWALL_RULES=(80/tcp 443/tcp 3478/tcp 3478/udp 7881/tcp 7882/udp 49152:49999/udp)
readonly -a BASE_PACKAGES=(ca-certificates curl git gnupg ufw jq qrencode openssl fail2ban
  unattended-upgrades iproute2 dnsutils cron gzip)

CONFIG_DIR=${SINHRON_CONFIG_DIR:-$CONFIG_DIR_DEFAULT}
CONFIG_FILE=${SINHRON_CONFIG:-$CONFIG_DIR/sinhron.conf}
LOG_FILE=${SINHRON_LOG_FILE:-$LOG_FILE_DEFAULT}
DRY_RUN=0
PIN_COMMIT=''        # --commit: the only commit an update may move the code to
MODE=auto            # auto | interactive | write-config | yes
SKIP_DNS_CHECK=0
SKIP_UPGRADE=0
REBOOT_NEEDED=0
MEMINFO=${SINHRON_MEMINFO:-/proc/meminfo}
SWAPFILE=${SINHRON_SWAPFILE:-/swapfile}

# Config values (filled by load_config / ask_config).
declare -A CFG=()

# ── Output ───────────────────────────────────────────────────────────────

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m' C_GREEN=$'\e[32m'
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
fi

STEP_NO=0
readonly STEP_TOTAL=10

# shellcheck disable=SC2015 # logging must never fail the install
log() { [[ -w ${LOG_FILE%/*} || -w $LOG_FILE ]] && printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true; }
say() { printf '%s\n' "$*"; log "$*"; }
step() {
  STEP_NO=$((STEP_NO + 1))
  printf '\n%s[%d/%d] %s%s\n' "$C_BOLD$C_BLUE" "$STEP_NO" "$STEP_TOTAL" "$*" "$C_RESET"
  log "== [$STEP_NO/$STEP_TOTAL] $*"
}
ok() { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; log "ok: $*"; }
skip() { printf '  %s•%s %s\n' "$C_DIM" "$C_RESET" "$*"; log "skip: $*"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; log "warn: $*"; }
die() {
  printf '\n%s✗ %s%s\n' "$C_RED$C_BOLD" "$*" "$C_RESET" >&2
  log "fatal: $*"
  [[ -f $LOG_FILE ]] && printf '%sПодробности: %s%s\n' "$C_DIM" "$LOG_FILE" "$C_RESET" >&2
  exit 1
}

on_error() {
  local code=$? line=${1:-?} cmd=${2:-?}
  # Inside $(…) just pass the failure up — the main shell reports it once.
  ((BASH_SUBSHELL > 0)) && exit "$code"
  printf '\n%s✗ Ошибка (код %d) в строке %s: %s%s\n' "$C_RED$C_BOLD" "$code" "$line" "$cmd" "$C_RESET" >&2
  log "error: code=$code line=$line cmd=$cmd"
  if [[ -f $LOG_FILE ]]; then
    printf '%sПоследние строки журнала (%s):%s\n' "$C_DIM" "$LOG_FILE" "$C_RESET" >&2
    tail -n 20 "$LOG_FILE" >&2 || true
  fi
  printf '\nИсправьте причину и запустите скрипт ещё раз — сделанное он пропустит.\n' >&2
  exit "$code"
}

# Run a command that changes the system: logged, quiet on success, shown
# on failure; only printed under --dry-run.
run() {
  if ((DRY_RUN)); then
    printf '  %s[dry-run]%s %s\n' "$C_CYAN" "$C_RESET" "$*"
    return 0
  fi
  log "run: $*"
  if ! "$@" >>"$LOG_FILE" 2>&1; then
    warn "Команда не удалась: $*"
    tail -n 15 "$LOG_FILE" >&2 || true
    return 1
  fi
}

# Write a file atomically with given mode (content from stdin).
write_file() {
  local path=$1 mode=$2 tmp
  if ((DRY_RUN)); then
    printf '  %s[dry-run]%s write %s (%s)\n' "$C_CYAN" "$C_RESET" "$path" "$mode"
    cat >/dev/null
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  tmp=$(mktemp "${path}.XXXXXX")
  cat >"$tmp"
  # Nothing we write is empty: empty means the producer on the other side of
  # the pipe failed — the file that is there stays (it may hold the secrets).
  [[ -s $tmp ]] || { rm -f "$tmp"; die "Не удалось подготовить $path — файл не тронут"; }
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$path"
  log "wrote $path ($mode)"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ── Questions (always from the terminal, so `curl … | sudo bash` works) ──

TTY_IN=${SINHRON_TTY_IN:-/dev/tty}   # tests feed answers from a file
TTY=${SINHRON_TTY_OUT:-/dev/tty}     # where questions are printed
has_tty() { [[ -r $TTY_IN && -w $TTY ]] && { : <"$TTY_IN"; } 2>/dev/null; }

# One reader for all questions (a file of answers is read line by line too).
tty_read() {
  if [[ -z ${TTY_FD_OPEN:-} ]]; then
    exec 3<"$TTY_IN"
    TTY_FD_OPEN=1
  fi
  IFS= read -r "$1" <&3
}

# ask VAR "Question" "default" validator
ask() {
  local __var=$1 question=$2 default=${3:-} validator=${4:-} answer
  while true; do
    if [[ -n $default ]]; then
      printf '  %s?%s %s %s[%s]%s: ' "$C_CYAN" "$C_RESET" "$question" "$C_DIM" "$default" "$C_RESET" >"$TTY"
    else
      printf '  %s?%s %s: ' "$C_CYAN" "$C_RESET" "$question" >"$TTY"
    fi
    tty_read answer || die "Нет ввода с терминала"
    answer=$(trim "$answer")
    [[ -z $answer ]] && answer=$default
    if [[ -z $validator ]] || "$validator" "$answer"; then
      printf -v "$__var" '%s' "$answer"
      return 0
    fi
  done
}

# ask_yes_no "Question" default(y|n) → 0 for yes
ask_yes_no() {
  local question=$1 default=${2:-y} answer hint='[Д/н]'
  [[ $default == n ]] && hint='[д/Н]'
  while true; do
    printf '  %s?%s %s %s%s%s: ' "$C_CYAN" "$C_RESET" "$question" "$C_DIM" "$hint" "$C_RESET" >"$TTY"
    tty_read answer || die "Нет ввода с терминала"
    answer=$(trim "${answer,,}")
    [[ -z $answer ]] && answer=$default
    case $answer in
      y | yes | д | да) return 0 ;;
      n | no | н | нет) return 1 ;;
      *) printf '    Ответьте «д» или «н».\n' >"$TTY" ;;
    esac
  done
}

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# ── Validators ───────────────────────────────────────────────────────────

valid_domain() {
  local d=${1,,}
  [[ ${#d} -le 253 && $d == *.* ]] || { [[ -n ${1:-} ]] && printf '    Нужно доменное имя, например chat.example.com\n' >&2; return 1; }
  [[ $d =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]] && return 0
  printf '    «%s» — не доменное имя (латиница, цифры, точки, дефисы)\n' "$1" >&2
  return 1
}

valid_ipv4() {
  local ip=$1 IFS=. part
  [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  for part in $ip; do ((10#$part <= 255)) || return 1; done
}

valid_ip_or_auto() {
  [[ $1 == auto ]] || valid_ipv4 "$1" && return 0
  printf '    Нужен IPv4-адрес или «auto»\n' >&2
  return 1
}

valid_port() {
  [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)) && return 0
  printf '    Порт — число от 1 до 65535\n' >&2
  return 1
}

valid_days() {
  [[ $1 =~ ^[0-9]{1,4}$ ]] && ((10#$1 >= 1 && 10#$1 <= 3650)) && return 0
  printf '    Число дней от 1 до 3650\n' >&2
  return 1
}

# ADR-077 — administrators' addresses: 64 hex chars each, separated by commas.
valid_admin_keys() {
  local k
  [[ -z $1 ]] && return 0
  for k in ${1//,/ }; do
    [[ $k =~ ^[0-9a-fA-F]{64}$ ]] || { printf '    Адрес — 64 знака 0-9 a-f (Sinhron → профиль → «Скопировать адрес»)\n' >&2; return 1; }
  done
}

valid_yes_no() {
  [[ ${1,,} == yes || ${1,,} == no ]] && return 0
  printf '    Ожидается yes или no\n' >&2
  return 1
}

valid_abs_path() {
  [[ $1 == /* && $1 != *[[:space:]]* && $1 != *..* ]] && return 0
  printf '    Нужен абсолютный путь без пробелов\n' >&2
  return 1
}

valid_repo_url() {
  [[ $1 =~ ^(https://|git@)[^[:space:]]+$ ]] && return 0
  printf '    Нужен адрес git-репозитория (https://… или git@…)\n' >&2
  return 1
}

valid_commit() {
  [[ $1 =~ ^[0-9a-f]{40}$ ]] && return 0
  printf '    Нужен полный id коммита (40 знаков 0-9a-f)\n' >&2
  return 1
}

valid_branch() {
  [[ $1 =~ ^[A-Za-z0-9._/-]+$ ]] && return 0
  printf '    Недопустимое имя ветки\n' >&2
  return 1
}

# ── Config ───────────────────────────────────────────────────────────────

config_defaults() {
  CFG=(
    [SINHRON_DOMAIN]=''
    [LIVEKIT_DOMAIN]=''
    [TURN_DOMAIN]=''
    [PUBLIC_IP]=auto
    [SSH_PORT]=auto
    [MESSAGE_RETENTION_DAYS]=365
    [DAILY_BACKUP]=yes
    [BACKUP_DIR]=/var/backups/sinhron
    [AUTO_SECURITY_UPDATES]=yes
    [ENABLE_PGBOUNCER]=no
    [ENABLE_NTFY]=yes
    [NTFY_DOMAIN]=''
    [ADMIN_KEYS]=''
    [INSTALL_DIR]=$DEFAULT_INSTALL_DIR
    [REPO_URL]=$DEFAULT_REPO_URL
    [REPO_BRANCH]=$DEFAULT_BRANCH
  )
}

# Parse KEY=value lines (no shell evaluation — the file is data).
load_config() {
  local file=$1 line key value n=0
  [[ -f $file ]] || die "Нет файла настроек $file"
  config_defaults
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=$(trim "${line%%$'\r'}")
    [[ -z $line || $line == \#* ]] && continue
    [[ $line =~ ^([A-Z_][A-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]] || die "$file:$n: ожидалось КЛЮЧ=значение, а тут: $line"
    key=${BASH_REMATCH[1]}
    value=$(trim "${BASH_REMATCH[2]}")
    # "quoted" or 'quoted' (a # inside is kept), then an optional comment.
    if [[ $value =~ ^\"([^\"]*)\"[[:space:]]*(#.*)?$ || $value =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
      value=${BASH_REMATCH[1]}
    elif [[ $value == \#* ]]; then
      value=''
    else
      value=$(trim "${value%%[[:space:]]#*}")
    fi
    if [[ -z ${CFG[$key]+x} ]]; then
      warn "$file:$n: неизвестный ключ $key — пропускаю"
      continue
    fi
    CFG[$key]=$value
  done <"$file"
  apply_derived_defaults
}

apply_derived_defaults() {
  CFG[SINHRON_DOMAIN]=${CFG[SINHRON_DOMAIN],,}
  [[ -z ${CFG[LIVEKIT_DOMAIN]} && -n ${CFG[SINHRON_DOMAIN]} ]] && CFG[LIVEKIT_DOMAIN]=livekit.${CFG[SINHRON_DOMAIN]}
  [[ -z ${CFG[TURN_DOMAIN]} && -n ${CFG[SINHRON_DOMAIN]} ]] && CFG[TURN_DOMAIN]=turn.${CFG[SINHRON_DOMAIN]}
  CFG[LIVEKIT_DOMAIN]=${CFG[LIVEKIT_DOMAIN],,}
  CFG[TURN_DOMAIN]=${CFG[TURN_DOMAIN],,}
  local k
  for k in DAILY_BACKUP AUTO_SECURITY_UPDATES ENABLE_PGBOUNCER ENABLE_NTFY; do CFG[$k]=${CFG[$k],,}; done
  # NTFY_DOMAIN stays empty = "find it" (resolve_ntfy, once the IP is known).
  CFG[NTFY_DOMAIN]=${CFG[NTFY_DOMAIN],,}
  # Spaces → commas, lower case: "AB.., cd.." → "ab..,cd..".
  local keys=${CFG[ADMIN_KEYS],,}
  keys=${keys//,/ }
  keys=$(trim "$(tr -s ' ' <<<"$keys")")
  CFG[ADMIN_KEYS]=${keys// /,}
  return 0
}

# All problems at once, not one per run.
validate_config() {
  local errors=() k
  [[ -n ${CFG[SINHRON_DOMAIN]} ]] || errors+=("SINHRON_DOMAIN не задан — укажите домен сервера")
  for k in SINHRON_DOMAIN LIVEKIT_DOMAIN TURN_DOMAIN NTFY_DOMAIN; do
    [[ -z ${CFG[$k]} ]] || valid_domain "${CFG[$k]}" 2>/dev/null || errors+=("$k=${CFG[$k]} — не доменное имя")
  done
  if [[ ${CFG[ENABLE_NTFY]} == yes && -n ${CFG[NTFY_DOMAIN]} ]]; then
    case ${CFG[NTFY_DOMAIN]} in
    "${CFG[SINHRON_DOMAIN]}" | "${CFG[LIVEKIT_DOMAIN]}" | "${CFG[TURN_DOMAIN]}") errors+=("NTFY_DOMAIN должен отличаться от остальных имён") ;;
    esac
  fi
  if [[ -n ${CFG[SINHRON_DOMAIN]} && -n ${CFG[LIVEKIT_DOMAIN]} && -n ${CFG[TURN_DOMAIN]} ]]; then
    [[ ${CFG[LIVEKIT_DOMAIN]} != "${CFG[SINHRON_DOMAIN]}" && ${CFG[TURN_DOMAIN]} != "${CFG[SINHRON_DOMAIN]}" &&
      ${CFG[LIVEKIT_DOMAIN]} != "${CFG[TURN_DOMAIN]}" ]] || errors+=("три имени (сервер, LiveKit, TURN) должны быть разными")
  fi
  valid_ip_or_auto "${CFG[PUBLIC_IP]}" 2>/dev/null || errors+=("PUBLIC_IP=${CFG[PUBLIC_IP]} — нужен IPv4 или auto")
  [[ ${CFG[SSH_PORT]} == auto ]] || valid_port "${CFG[SSH_PORT]}" 2>/dev/null || errors+=("SSH_PORT=${CFG[SSH_PORT]} — нужен порт или auto")
  valid_days "${CFG[MESSAGE_RETENTION_DAYS]}" 2>/dev/null || errors+=("MESSAGE_RETENTION_DAYS=${CFG[MESSAGE_RETENTION_DAYS]} — число дней 1…3650")
  for k in DAILY_BACKUP AUTO_SECURITY_UPDATES ENABLE_PGBOUNCER ENABLE_NTFY; do
    valid_yes_no "${CFG[$k]}" 2>/dev/null || errors+=("$k=${CFG[$k]} — yes или no")
  done
  for k in BACKUP_DIR INSTALL_DIR; do
    valid_abs_path "${CFG[$k]}" 2>/dev/null || errors+=("$k=${CFG[$k]} — нужен абсолютный путь")
  done
  valid_admin_keys "${CFG[ADMIN_KEYS]}" 2>/dev/null || errors+=("ADMIN_KEYS — адреса по 64 знака 0-9 a-f через запятую")
  valid_repo_url "${CFG[REPO_URL]}" 2>/dev/null || errors+=("REPO_URL=${CFG[REPO_URL]} — не адрес репозитория")
  valid_branch "${CFG[REPO_BRANCH]}" 2>/dev/null || errors+=("REPO_BRANCH=${CFG[REPO_BRANCH]} — недопустимое имя")
  if ((${#errors[@]})); then
    printf '\n%sВ настройках %s есть ошибки:%s\n' "$C_RED$C_BOLD" "$CONFIG_FILE" "$C_RESET" >&2
    printf '  • %s\n' "${errors[@]}" >&2
    printf '\nИсправьте файл и запустите скрипт ещё раз.\n' >&2
    log "config errors: ${errors[*]}"
    return 1
  fi
}

# The config file: same format whether written as a template or from answers.
render_config() {
  cat <<EOF
# Sinhron — настройки установки (installer v$INSTALLER_VERSION).
# Отредактируйте и запустите установщик снова: sudo $(script_self) --yes
# Секретов здесь нет: пароли и ключи скрипт создаёт сам и хранит в server/.env.

# ── Обязательно ─────────────────────────────────────────────────────────
# Домен сервера. Его вводят в приложении (или сканируют QR, который покажет
# установщик). Нужна DNS-запись A этого имени на IP сервера.
SINHRON_DOMAIN=${CFG[SINHRON_DOMAIN]}

# ── Звонки ──────────────────────────────────────────────────────────────
# Ещё два имени для звонков; пусто = livekit.<домен> и turn.<домен>.
# Для каждого тоже нужна запись A на IP сервера.
LIVEKIT_DOMAIN=${CFG[LIVEKIT_DOMAIN]}
TURN_DOMAIN=${CFG[TURN_DOMAIN]}

# Публичный IPv4 сервера; auto = определить самому.
PUBLIC_IP=${CFG[PUBLIC_IP]}

# ── Сообщения и копии ───────────────────────────────────────────────────
# Сколько дней сервер хранит недоставленные зашифрованные сообщения.
MESSAGE_RETENTION_DAYS=${CFG[MESSAGE_RETENTION_DAYS]}
# Ежедневная резервная копия в 03:00 (yes/no) и куда её класть.
DAILY_BACKUP=${CFG[DAILY_BACKUP]}
BACKUP_DIR=${CFG[BACKUP_DIR]}

# ── Система ─────────────────────────────────────────────────────────────
# Автоматические обновления безопасности Ubuntu (yes/no).
AUTO_SECURITY_UPDATES=${CFG[AUTO_SECURITY_UPDATES]}
# Порт SSH, который останется открытым в firewall; auto = текущий порт sshd.
SSH_PORT=${CFG[SSH_PORT]}
# Пул соединений PgBouncer — нужен только при большой нагрузке (yes/no).
ENABLE_PGBOUNCER=${CFG[ENABLE_PGBOUNCER]}

# ── Push для Android (UnifiedPush, без Google) ──────────────────────────
# Свой сервер ntfy: телефоны Android получают через него уведомления о
# сообщениях и звонках (yes/no). Нужна ещё одна запись A. NTFY_DOMAIN пусто —
# установщик найдёт сам: push.<домен> или push.<домен уровнем выше> — то имя,
# что указывает на этот сервер; нет такой записи — push пока выключен.
ENABLE_NTFY=${CFG[ENABLE_NTFY]}
NTFY_DOMAIN=${CFG[NTFY_DOMAIN]}

# ── Администратор ───────────────────────────────────────────────────────
# Ваш адрес в Sinhron (профиль → «Скопировать адрес», 64 знака); можно
# несколько через запятую. Сервер будет писать туда в чат «Сервер»: высокая
# нагрузка (процессор, память, соединения) и новые жалобы (с IP). Пусто — без
# администратора (сервер тогда не хранит IP).
ADMIN_KEYS=${CFG[ADMIN_KEYS]}

# ── Код ─────────────────────────────────────────────────────────────────
# Если скрипт запущен из скачанного репозитория — используется он, а эти
# строки не нужны. Иначе код скачивается сюда:
INSTALL_DIR=${CFG[INSTALL_DIR]}
REPO_URL=${CFG[REPO_URL]}
REPO_BRANCH=${CFG[REPO_BRANCH]}
EOF
}

script_self() {
  local self=${BASH_SOURCE[0]:-install.sh}
  [[ $self == /* ]] || self="./${self#./}"
  printf '%s' "$self"
}

write_config() {
  render_config | write_file "$CONFIG_FILE" 0640
}

print_config_summary() {
  printf '\n  %sНастройки%s (%s)\n' "$C_BOLD" "$C_RESET" "$CONFIG_FILE"
  printf '    Сервер:           %s\n' "${CFG[SINHRON_DOMAIN]}"
  printf '    LiveKit / TURN:   %s / %s\n' "${CFG[LIVEKIT_DOMAIN]}" "${CFG[TURN_DOMAIN]}"
  printf '    Публичный IP:     %s\n' "${CFG[PUBLIC_IP]}"
  printf '    Хранить сообщения: %s дн.\n' "${CFG[MESSAGE_RETENTION_DAYS]}"
  printf '    Резервные копии:  %s (%s)\n' "${CFG[DAILY_BACKUP]}" "${CFG[BACKUP_DIR]}"
  printf '    Автообновления:   %s;  PgBouncer: %s\n' "${CFG[AUTO_SECURITY_UPDATES]}" "${CFG[ENABLE_PGBOUNCER]}"
  if [[ ${CFG[ENABLE_NTFY]} == yes ]]; then
    printf '    Push Android:     ntfy на %s\n' "${CFG[NTFY_DOMAIN]:-push.<домен> (найду сам)}"
  fi
  if [[ -n ${CFG[ADMIN_KEYS]} ]]; then
    printf '    Администратор:    %s\n' "${CFG[ADMIN_KEYS]:0:12}…"
  fi
}

ask_config() {
  config_defaults
  [[ -f $CONFIG_FILE ]] && load_config "$CONFIG_FILE"
  printf '\n  Ответьте на несколько вопросов — %sEnter%s оставляет значение в [скобках].\n\n' "$C_BOLD" "$C_RESET" >"$TTY"
  local v
  ask v "Домен сервера (например chat.example.com)" "${CFG[SINHRON_DOMAIN]}" valid_domain
  CFG[SINHRON_DOMAIN]=${v,,}
  [[ ${CFG[LIVEKIT_DOMAIN]} == livekit.* || -z ${CFG[LIVEKIT_DOMAIN]} ]] && CFG[LIVEKIT_DOMAIN]=livekit.${CFG[SINHRON_DOMAIN]}
  [[ ${CFG[TURN_DOMAIN]} == turn.* || -z ${CFG[TURN_DOMAIN]} ]] && CFG[TURN_DOMAIN]=turn.${CFG[SINHRON_DOMAIN]}
  if ! ask_yes_no "Имена для звонков: ${CFG[LIVEKIT_DOMAIN]} и ${CFG[TURN_DOMAIN]} — подходят?" y; then
    ask v "Имя для LiveKit" "${CFG[LIVEKIT_DOMAIN]}" valid_domain
    CFG[LIVEKIT_DOMAIN]=${v,,}
    ask v "Имя для TURN" "${CFG[TURN_DOMAIN]}" valid_domain
    CFG[TURN_DOMAIN]=${v,,}
  fi
  local detected
  detected=$(detect_public_ip || true)
  ask v "Публичный IPv4 сервера${detected:+ (найден $detected)}" "${detected:-${CFG[PUBLIC_IP]}}" valid_ip_or_auto
  CFG[PUBLIC_IP]=$v
  ask v "Сколько дней хранить недоставленные сообщения" "${CFG[MESSAGE_RETENTION_DAYS]}" valid_days
  CFG[MESSAGE_RETENTION_DAYS]=$v
  if ask_yes_no "Ежедневная резервная копия (в ${CFG[BACKUP_DIR]})?" "${CFG[DAILY_BACKUP]:0:1}"; then CFG[DAILY_BACKUP]=yes; else CFG[DAILY_BACKUP]=no; fi
  if ask_yes_no "Автоматически ставить обновления безопасности Ubuntu?" "${CFG[AUTO_SECURITY_UPDATES]:0:1}"; then
    CFG[AUTO_SECURITY_UPDATES]=yes
  else
    CFG[AUTO_SECURITY_UPDATES]=no
  fi
  ask v "Ваш адрес в Sinhron для служебных уведомлений (профиль → «Скопировать адрес»; Enter — без администратора)" "${CFG[ADMIN_KEYS]}" valid_admin_keys
  CFG[ADMIN_KEYS]=$v
  apply_derived_defaults
  validate_config || die "Настройки не прошли проверку"
  write_config
  ok "Ответы сохранены в $CONFIG_FILE — в следующий раз можно запустить с --yes"
}

# ── Detection ────────────────────────────────────────────────────────────

detect_public_ip() {
  local url ip
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com https://ipv4.icanhazip.com; do
    ip=$(curl -4 -fsS --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]') || continue
    valid_ipv4 "$ip" && { printf '%s' "$ip"; return 0; }
  done
  return 1
}

# The IPv4 on this machine's outgoing interface.
detect_local_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}'
}

# coturn must advertise the public IP; behind 1:1 NAT it needs public/private.
turn_external_ip() {
  local public=$1 local_ip=$2
  if [[ -z $local_ip || $local_ip == "$public" ]]; then
    printf '%s' "$public"
  else
    printf '%s/%s' "$public" "$local_ip"
  fi
}

detect_ssh_port() {
  local port=''
  if have sshd; then
    port=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }') || true
  fi
  if [[ -z $port ]]; then
    port=$(ss -tlnpH 2>/dev/null | awk '/"sshd"/ { n = split($4, a, ":"); print a[n]; exit }') || port=''
  fi
  [[ -n ${SSH_CONNECTION:-} && -z $port ]] && port=$(awk '{ print $4 }' <<<"$SSH_CONNECTION")
  printf '%s' "${port:-22}"
}

# Resolve a name to its IPv4 addresses (one per line).
resolve_ipv4() {
  local name=$1
  if have dig; then
    dig +short A "$name" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' || dig +short A "$name" 2>/dev/null | grep -E '^[0-9.]+$' || true
  else
    getent ahostsv4 "$name" 2>/dev/null | awk '{ print $1 }' | sort -u || true
  fi
}

# Which of the three names don't point at [ip]? Prints them.
dns_mismatches() {
  local ip=$1 name addrs
  shift
  for name in "$@"; do
    addrs=$(resolve_ipv4 "$name")
    grep -qxF "$ip" <<<"$addrs" || printf '%s\t%s\n' "$name" "$(tr '\n' ' ' <<<"$addrs")"
  done
}

# ── .env (secrets are generated once, then kept) ─────────────────────────

declare -A ENV_OLD=()

load_env() {
  local file=$1 line
  ENV_OLD=()
  [[ -f $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
    ENV_OLD[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
  done <"$file"
}

rand_hex() { openssl rand -hex "$1"; }

# server/.env for docker compose — our keys first, then anything the
# operator added by hand (kept as is).
render_env() {
  local public_ip=$1 local_ip=$2 d=${CFG[SINHRON_DOMAIN]} lk=${CFG[LIVEKIT_DOMAIN]} turn=${CFG[TURN_DOMAIN]}
  local db_pass=${ENV_OLD[SINHRON_DB_PASSWORD]:-}
  local lk_keys=${ENV_OLD[LIVEKIT_KEYS]:-}
  local turn_secret=${ENV_OLD[TURN_SHARED_SECRET]:-}
  # Placeholders from .env.example / deploy-guide §3 are never kept (the server refuses them).
  [[ -z $db_pass || $db_pass == dev_only || $db_pass == change-me-before-prod || $db_pass == GENERATE_* ]] && db_pass=$(rand_hex 32)
  [[ -z $lk_keys || $lk_keys == devkey:* || $lk_keys == GENERATE_* ]] && lk_keys="API$(rand_hex 8): $(rand_hex 32)"
  [[ -z $turn_secret || $turn_secret == devturnsecret* || $turn_secret == GENERATE_* ]] && turn_secret=$(rand_hex 32)
  # deploy-deps:8 — a new install: the server logs in as its own role, not
  # the database superuser. An existing one keeps `sinhron` until its
  # operator sets SINHRON_DB_APP_USER=sinhron_app here (deploy-guide §9.1, step 3).
  local app_user=${ENV_OLD[SINHRON_DB_APP_USER]:-} app_pass=${ENV_OLD[SINHRON_DB_APP_PASSWORD]:-}
  if [[ -z $app_user ]]; then
    app_user=sinhron
    [[ -z ${ENV_OLD[SINHRON_DB_PASSWORD]:-} ]] && app_user=sinhron_app
  fi
  [[ $app_user != sinhron && -z $app_pass ]] && app_pass=$(rand_hex 32)
  # deploy-deps:16 — the server's publish token for its own ntfy (format of
  # ntfy tokens: tk_ and 29 letters/digits).
  local ntfy_token=${ENV_OLD[SINHRON_NTFY_TOKEN]:-}
  [[ $ntfy_token =~ ^tk_[a-z0-9]{29}$ ]] || ntfy_token=tk_$(rand_hex 15 | cut -c1-29)
  local -A managed=(
    [SINHRON_PUBLIC_HOSTNAME]=$d
    [SINHRON_LIVEKIT_HOSTNAME]=$lk
    [SINHRON_TURN_HOSTNAME]=$turn
    [SINHRON_DB_PASSWORD]=$db_pass
    [SINHRON_DB_APP_USER]=$app_user
    [LIVEKIT_KEYS]=$lk_keys
    [TURN_SHARED_SECRET]=$turn_secret
    [TURN_REALM]=$d
    [TURN_EXTERNAL_IP]=$(turn_external_ip "$public_ip" "$local_ip")
    [TURN_URLS]="turn:$d:3478?transport=udp,turn:$d:3478?transport=tcp,turns:$turn:443?transport=tcp"
    [SINHRON_MESSAGE_RETENTION_DAYS]=${CFG[MESSAGE_RETENTION_DAYS]}
    [RUST_LOG]=${ENV_OLD[RUST_LOG]:-info}
    [SINHRON_NTFY_TOKEN]=$ntfy_token
  )
  [[ -n $app_pass ]] && managed[SINHRON_DB_APP_PASSWORD]=$app_pass
  local profiles=()
  if [[ ${CFG[ENABLE_PGBOUNCER]} == yes ]]; then
    profiles+=(pgbouncer)
    managed[SINHRON_DB_HOST]=pgbouncer
  fi
  # ADR-040 — own ntfy for Android push; the server POSTs only to it.
  # NTFY_HOST: the name resolve_ntfy settled on (empty: push is off).
  if [[ -n ${NTFY_HOST:-} ]]; then
    profiles+=(ntfy)
    managed[SINHRON_NTFY_HOSTNAME]=$NTFY_HOST
    managed[SINHRON_UNIFIEDPUSH_HOSTS]=$NTFY_HOST
  fi
  # ADR-077 — the server's administrators (empty: none, no IPs kept).
  if [[ -n ${CFG[ADMIN_KEYS]} ]]; then
    managed[SINHRON_ADMIN_IDENTITIES]=${CFG[ADMIN_KEYS]}
  fi
  if ((${#profiles[@]})); then
    managed[COMPOSE_PROFILES]=$(IFS=,; printf '%s' "${profiles[*]}")
  fi
  local order=(SINHRON_PUBLIC_HOSTNAME SINHRON_LIVEKIT_HOSTNAME SINHRON_TURN_HOSTNAME SINHRON_DB_PASSWORD
    SINHRON_DB_APP_USER SINHRON_DB_APP_PASSWORD SINHRON_NTFY_TOKEN LIVEKIT_KEYS TURN_SHARED_SECRET TURN_REALM TURN_EXTERNAL_IP TURN_URLS SINHRON_MESSAGE_RETENTION_DAYS
    RUST_LOG COMPOSE_PROFILES SINHRON_DB_HOST SINHRON_NTFY_HOSTNAME SINHRON_UNIFIEDPUSH_HOSTS
    SINHRON_ADMIN_IDENTITIES) k
  printf '# Written by install.sh — secrets are generated once and kept on rerun.\n'
  printf '# Settings live in %s; change them there and rerun the installer.\n' "$CONFIG_FILE"
  for k in "${order[@]}"; do
    [[ -n ${managed[$k]+x} ]] && printf '%s=%s\n' "$k" "${managed[$k]}"
  done
  local extra=()
  for k in "${!ENV_OLD[@]}"; do
    [[ -n ${managed[$k]+x} ]] && continue
    # PgBouncer turned off again: drop what we set for it.
    [[ $k == COMPOSE_PROFILES ]] && continue
    [[ $k == SINHRON_DB_HOST ]] && [[ ${CFG[ENABLE_PGBOUNCER]} != yes ]] && continue
    [[ $k == SINHRON_NTFY_HOSTNAME || $k == SINHRON_UNIFIEDPUSH_HOSTS ]] && [[ -z ${NTFY_HOST:-} ]] && continue
    # Administrators come from ADMIN_KEYS in the config: emptied there = none.
    [[ $k == SINHRON_ADMIN_IDENTITIES ]] && continue
    extra+=("$k")
  done
  if ((${#extra[@]})); then
    printf '# Added by hand (kept):\n'
    while IFS= read -r k; do printf '%s=%s\n' "$k" "${ENV_OLD[$k]}"; done < <(printf '%s\n' "${extra[@]}" | sort)
  fi
}

# ── Steps ────────────────────────────────────────────────────────────────

require_root() {
  ((EUID == 0)) && return 0
  ((DRY_RUN)) && { warn "Не root — в режиме --dry-run это можно"; return 0; }
  local self
  self=$(script_self)
  if have sudo && [[ -f $self ]]; then
    say "Нужны права администратора — перезапускаю через sudo…"
    exec sudo -E bash "$self" "$@"
  fi
  die "Запустите от root: sudo bash $self (или: curl … | sudo bash)"
}

acquire_lock() {
  ((DRY_RUN)) && return 0
  exec 9>"$LOCK_FILE"
  have flock && ! flock -n 9 && die "Скрипт уже запущен в другом окне (замок $LOCK_FILE)"
  return 0
}

check_system() {
  step "Проверка системы"
  [[ -r /etc/os-release ]] || die "Не найден /etc/os-release — это не Ubuntu"
  local id version codename
  id=$(. /etc/os-release && printf '%s' "${ID:-}")
  version=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
  codename=$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")
  OS_CODENAME=$codename
  if [[ $id != ubuntu ]]; then
    die "Нужна Ubuntu 22.04 или 24.04, а здесь «$id $version»"
  fi
  case $version in
    22.04 | 24.04) ok "Ubuntu $version ($codename)" ;;
    *) warn "Ubuntu $version не проверялась — рассчитано на 22.04 и 24.04; продолжаю" ;;
  esac
  local arch
  arch=$(dpkg --print-architecture)
  [[ $arch == amd64 || $arch == arm64 ]] || die "Архитектура $arch не поддерживается (нужна amd64 или arm64)"
  ok "Архитектура $arch"
  have systemctl || die "Нужен systemd"
  local mem_mb disk_gb
  mem_mb=$(awk '/MemTotal/ { print int($2 / 1024) }' "$MEMINFO")
  disk_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  if ((mem_mb >= 1800)); then ok "Память ${mem_mb} МБ"; else warn "Память ${mem_mb} МБ — мало; добавлю swap, сборка будет медленной"; fi
  if ((disk_gb >= 15)); then
    ok "Свободно на диске ${disk_gb} ГБ"
  elif ((DRY_RUN)); then
    warn "Свободно ${disk_gb} ГБ — для установки нужно хотя бы 15 ГБ"
  else
    die "Свободно ${disk_gb} ГБ — нужно хотя бы 15 ГБ"
  fi
  if curl -fsS --max-time 10 -o /dev/null https://download.docker.com 2>/dev/null; then
    ok "Интернет есть"
  else
    die "Нет доступа к https://download.docker.com — проверьте интернет и DNS"
  fi
  local busy
  busy=$(ss -tlnpH '( sport = :80 or sport = :443 )' 2>/dev/null | grep -v -e docker-proxy -e '"caddy"' || true)
  [[ -z $busy ]] || die "Порты 80/443 уже заняты другой программой (nginx/apache?) — освободите их:
$busy"
}

choose_mode() {
  case $MODE in
    write-config)
      [[ -f $CONFIG_FILE ]] && die "Файл $CONFIG_FILE уже есть — отредактируйте его или удалите"
      config_defaults
      write_config
      say ""
      ok "Создан $CONFIG_FILE"
      say "   Откройте его (например: ${C_BOLD}sudo nano $CONFIG_FILE${C_RESET}), впишите домен и запустите снова:"
      say "   ${C_BOLD}sudo $(script_self) --yes${C_RESET}"
      exit 0
      ;;
    interactive)
      has_tty || die "Нет терминала для вопросов — используйте --write-config и --yes"
      ask_config
      ;;
    yes)
      [[ -f $CONFIG_FILE ]] || die "Нет $CONFIG_FILE — сначала: sudo $(script_self) --write-config"
      load_config "$CONFIG_FILE"
      validate_config || exit 1
      print_config_summary
      ;;
    auto)
      if [[ -f $CONFIG_FILE ]]; then
        load_config "$CONFIG_FILE"
        validate_config || exit 1
        print_config_summary
        if has_tty && ! ask_yes_no "Устанавливать с этими настройками?" y; then
          ask_yes_no "Изменить их сейчас, ответив на вопросы?" y && ask_config || exit 0
        fi
        return 0
      fi
      has_tty || die "Нет настроек и нет терминала. Создайте их: sudo $(script_self) --write-config"
      printf '\n  Как задать настройки?\n' >"$TTY"
      printf '    %s1%s — ответить на вопросы сейчас (ответы сохранятся в %s)\n' "$C_BOLD" "$C_RESET" "$CONFIG_FILE" >"$TTY"
      printf '    %s2%s — создать файл настроек, заполнить его самому и запустить скрипт снова\n' "$C_BOLD" "$C_RESET" >"$TTY"
      local choice
      ask choice "Ваш выбор" 1 valid_choice_12
      if [[ $choice == 2 ]]; then
        MODE=write-config
        choose_mode
      fi
      ask_config
      ;;
  esac
}

valid_choice_12() {
  [[ $1 == 1 || $1 == 2 ]] && return 0
  printf '    Введите 1 или 2\n' >&2
  return 1
}

resolve_network() {
  if [[ ${CFG[PUBLIC_IP]} == auto ]]; then
    PUBLIC_IP=$(detect_public_ip) || die "Не удалось узнать публичный IP — укажите PUBLIC_IP в $CONFIG_FILE"
  else
    PUBLIC_IP=${CFG[PUBLIC_IP]}
  fi
  LOCAL_IP=$(detect_local_ip || true)
  ok "Публичный IP $PUBLIC_IP${LOCAL_IP:+, на интерфейсе $LOCAL_IP}"
  if [[ -n $LOCAL_IP && $LOCAL_IP != "$PUBLIC_IP" ]]; then
    warn "Публичный IP не висит на сервере (1:1 NAT облака). Звонки через TURN могут не работать —"
    warn "надёжнее VPS с публичным IP прямо на интерфейсе (Hetzner, DigitalOcean…). См. ADR-016."
  fi
  if [[ ${CFG[SSH_PORT]} == auto ]]; then SSH_PORT=$(detect_ssh_port); else SSH_PORT=${CFG[SSH_PORT]}; fi
}

# Android push host (owner, 2026-10-18: "the installer must find it for any
# server"). NTFY_DOMAIN when set; else the first of push.<domain> and
# push.<parent domain> whose A record is this server. None: push stays off
# for this run with a hint — it never blocks the install (phones still get
# calls through "Always connected").
ntfy_candidates() {
  local d=${CFG[SINHRON_DOMAIN]} parent
  printf 'push.%s\n' "$d"
  parent=${d#*.}
  [[ $parent == *.* ]] && printf 'push.%s\n' "$parent"
  return 0
}

resolve_ntfy() {
  NTFY_HOST=''
  [[ ${CFG[ENABLE_NTFY]} == yes ]] || return 0
  if [[ -n ${CFG[NTFY_DOMAIN]} ]]; then
    NTFY_HOST=${CFG[NTFY_DOMAIN]}
    return 0
  fi
  local c
  while IFS= read -r c; do
    if resolve_ipv4 "$c" | grep -qxF "$PUBLIC_IP"; then
      NTFY_HOST=$c
      ok "Push для Android: $c"
      return 0
    fi
  done < <(ntfy_candidates)
  warn "Push для Android пока выключен: нет записи A $(ntfy_candidates | head -1) → $PUBLIC_IP."
  warn "Создайте её и запустите установщик снова (до тех пор — «Постоянное соединение» в приложении)."
  return 0
}

check_dns() {
  step "DNS-записи"
  local names=("${CFG[SINHRON_DOMAIN]}" "${CFG[LIVEKIT_DOMAIN]}" "${CFG[TURN_DOMAIN]}") bad
  if [[ -n ${NTFY_HOST:-} ]]; then names+=("$NTFY_HOST"); fi
  while true; do
    bad=$(dns_mismatches "$PUBLIC_IP" "${names[@]}")
    if [[ -z $bad ]]; then
      ok "Все имена (${#names[@]}) указывают на $PUBLIC_IP"
      return 0
    fi
    warn "Эти имена ещё не указывают на этот сервер:"
    local name addrs
    while IFS=$'\t' read -r name addrs; do
      printf '      %s → %s\n' "$name" "${addrs:-(нет записи)}" >&2
    done <<<"$bad"
    printf '\n    У регистратора домена создайте записи (TTL любой):\n' >&2
    for name in "${names[@]}"; do printf '      %-40s A    %s\n' "$name" "$PUBLIC_IP" >&2; done
    printf '    В Cloudflare включите для них режим «DNS only» (серое облачко).\n\n' >&2
    if ((SKIP_DNS_CHECK)); then
      warn "--skip-dns-check: продолжаю без DNS (сертификаты не выпустятся, пока записей нет)"
      return 0
    fi
    if ! has_tty || [[ $MODE == yes ]]; then
      die "DNS не готов. Создайте записи и запустите снова (или --skip-dns-check)"
    fi
    if ask_yes_no "Проверить ещё раз? (н — продолжить без проверки)" y; then
      say "    Жду 20 секунд…"
      sleep 20
    else
      warn "Продолжаю без DNS — сертификаты выпустятся, когда записи появятся"
      return 0
    fi
  done
}

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

apt_get() { run env DEBIAN_FRONTEND=noninteractive apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"; }

install_packages() {
  step "Обновление системы и пакеты"
  say "  Это может занять несколько минут…"
  apt_get update
  if ((SKIP_UPGRADE)); then
    skip "Обновление системы пропущено (--no-upgrade)"
  else
    apt_get upgrade
    ok "Система обновлена"
  fi
  local missing=() p
  for p in "${BASE_PACKAGES[@]}"; do pkg_installed "$p" || missing+=("$p"); done
  if ((${#missing[@]})); then
    apt_get install --no-install-recommends "${missing[@]}"
    ok "Установлено: ${missing[*]}"
  else
    skip "Нужные пакеты уже стоят"
  fi
  [[ -f /var/run/reboot-required ]] && REBOOT_NEEDED=1
  return 0
}

setup_auto_updates() {
  if [[ ${CFG[AUTO_SECURITY_UPDATES]} != yes ]]; then
    skip "Автообновления выключены в настройках"
    return 0
  fi
  write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF'
// Written by Sinhron install.sh — daily package lists + security updates.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  run systemctl enable --now unattended-upgrades
  ok "Автообновления безопасности включены"
}

setup_swap() {
  local mem_mb swap_mb size
  mem_mb=$(awk '/MemTotal/ { print int($2 / 1024) }' "$MEMINFO")
  swap_mb=$(awk '/SwapTotal/ { print int($2 / 1024) }' "$MEMINFO")
  if ((mem_mb >= 3500 || swap_mb >= 1024)); then
    skip "Swap не нужен (память ${mem_mb} МБ, swap ${swap_mb} МБ)"
    return 0
  fi
  size=$((mem_mb < 2000 ? 4 : 2))
  if [[ -f $SWAPFILE ]]; then
    skip "$SWAPFILE уже есть"
  else
    run fallocate -l "${size}G" "$SWAPFILE"
    run chmod 600 "$SWAPFILE"
    run mkswap "$SWAPFILE"
  fi
  run swapon "$SWAPFILE" || true
  grep -q "^$SWAPFILE " /etc/fstab 2>/dev/null || { ((DRY_RUN)) || printf '%s none swap sw 0 0\n' "$SWAPFILE" >>/etc/fstab; }
  ok "Swap ${size} ГБ — чтобы сборка не упала по памяти"
}

install_docker() {
  step "Docker"
  if have docker && docker compose version >/dev/null 2>&1; then
    skip "Docker и compose уже есть ($(docker --version | awk '{ print $3 }' | tr -d ,), compose $(docker compose version --short 2>/dev/null))"
  else
    if have docker && pkg_installed docker.io; then
      # Ubuntu's own Docker: add the matching compose plugin.
      apt_get install docker-compose-v2 || die "Не удалось поставить docker compose"
      ok "Добавлен docker compose"
    else
      local key=/etc/apt/keyrings/docker.asc arch
      arch=$(dpkg --print-architecture)
      run install -m 0755 -d /etc/apt/keyrings
      run curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$key"
      run chmod a+r "$key"
      printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/ubuntu %s stable\n' "$arch" "$key" "$OS_CODENAME" |
        write_file /etc/apt/sources.list.d/docker.list 0644
      apt_get update
      apt_get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ok "Docker установлен"
    fi
  fi
  run systemctl enable --now docker
  ((DRY_RUN)) || docker info >/dev/null 2>&1 || die "Docker установлен, но не запускается (systemctl status docker)"
  ok "Docker работает"
}

setup_firewall() {
  step "Firewall и защита SSH"
  # SSH first, so enabling the firewall never locks you out.
  run ufw allow "$SSH_PORT/tcp" comment 'SSH'
  local rule
  for rule in "${FIREWALL_RULES[@]}"; do run ufw allow "$rule" comment 'Sinhron'; done
  if ufw status 2>/dev/null | grep -q '^Status: active'; then
    skip "ufw уже включён — правила добавлены"
  else
    run ufw --force enable
    ok "ufw включён"
  fi
  ok "Открыты: SSH $SSH_PORT/tcp, ${FIREWALL_RULES[*]}"
  if [[ $SSH_PORT != 22 ]]; then
    write_file /etc/fail2ban/jail.d/sinhron-sshd.local 0644 <<EOF
# Written by Sinhron install.sh — SSH runs on port $SSH_PORT.
[sshd]
enabled = true
port = $SSH_PORT
EOF
  fi
  run systemctl enable --now fail2ban
  run systemctl restart fail2ban
  ok "fail2ban следит за входами по SSH"
  harden_ssh
  setup_auto_updates
  setup_swap
}

# Security review 2026-11-02: root logged in by password — the door most
# servers are broken through. Only when a key already lets someone in
# (never locks the operator out): keys only, root by key only.
harden_ssh() {
  local keys=0 f
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [[ -s $f ]] && grep -qE '^(ssh-|ecdsa-|sk-)' "$f" && keys=1
  done
  if ((!keys)); then
    warn "SSH: ключей входа нет — вход по паролю оставлен. Добавьте ключ и запустите установщик снова"
    return 0
  fi
  write_file /etc/ssh/sshd_config.d/10-sinhron.conf 0644 <<'SSHD'
# Written by Sinhron install.sh — sign in with a key only.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
SSHD
  if ((DRY_RUN)) || sshd -t 2>/dev/null; then
    run systemctl reload ssh 2>/dev/null || run systemctl reload sshd
    ok "SSH: вход только по ключу"
  else
    run rm -f /etc/ssh/sshd_config.d/10-sinhron.conf
    warn "SSH: настройка не прошла проверку sshd -t — оставлено как было"
  fi
}

# deploy-deps:5 — an update ran whatever was on the branch, as root (and the
# nightly backup cron runs scripts from this tree). Now the code moves only to
# the commit the operator names with --commit; without it the checked-out
# commit stays, whatever was pushed since.
move_to_commit() {
  local repo=$1
  if [[ -z $PIN_COMMIT ]]; then
    skip "Код не обновляю (остаётся $(git -C "$repo" rev-parse --short HEAD 2>/dev/null)): новый — только с --commit <id>"
    return 0
  fi
  run git -C "$repo" fetch --quiet origin "${CFG[REPO_BRANCH]}" || die "Не удалось получить ${CFG[REPO_BRANCH]} из origin"
  run git -C "$repo" -c advice.detachedHead=false checkout --quiet --detach "$PIN_COMMIT" ||
    die "Коммита $PIN_COMMIT нет в ${CFG[REPO_BRANCH]} — код не тронут"
  ok "Код на коммите $PIN_COMMIT"
}

fetch_code() {
  step "Код сервера"
  local here
  here=$(cd "$(dirname "$(script_self)")" && pwd)
  if [[ -f $here/docker-compose.yml && -f $here/Dockerfile && -d $here/../.git ]]; then
    REPO_ROOT=$(cd "$here/.." && pwd)
    ok "Использую репозиторий, из которого запущен скрипт: $REPO_ROOT"
    if [[ -n $(git -C "$REPO_ROOT" status --porcelain --untracked-files=no 2>/dev/null) ]]; then
      # Named a commit, but the code can't move to it: stop here, before
      # anything is rebuilt from the old code and reported as done.
      # (a short id counts too: both sides are resolved to the full one)
      [[ -z $PIN_COMMIT || $(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null) == "$(git -C "$REPO_ROOT" rev-parse --verify --quiet "$PIN_COMMIT^{commit}" 2>/dev/null)" ]] ||
        die "В $REPO_ROOT есть локальные правки — перейти на $PIN_COMMIT нельзя. Код и службы не тронуты.
  Посмотреть их: git -C $REPO_ROOT status
  Отложить их:   git -C $REPO_ROOT stash   (затем запустите установщик ещё раз)"
      skip "Есть локальные правки — код не обновляю"
    else
      move_to_commit "$REPO_ROOT"
    fi
  else
    REPO_ROOT=${CFG[INSTALL_DIR]}
    if [[ -d $REPO_ROOT/.git ]]; then
      move_to_commit "$REPO_ROOT"
    else
      [[ -e $REPO_ROOT && -n $(ls -A "$REPO_ROOT" 2>/dev/null) ]] && die "$REPO_ROOT не пустая и это не git-репозиторий"
      run git clone --quiet --branch "${CFG[REPO_BRANCH]}" "${CFG[REPO_URL]}" "$REPO_ROOT" ||
        die "Не удалось скачать ${CFG[REPO_URL]} — если репозиторий закрытый, скачайте его сами и запустите server/install.sh оттуда"
      if [[ -n $PIN_COMMIT ]]; then
        run git -C "$REPO_ROOT" -c advice.detachedHead=false checkout --quiet --detach "$PIN_COMMIT" ||
          die "Коммита $PIN_COMMIT нет в ${CFG[REPO_BRANCH]}"
      fi
      ok "Код скачан в $REPO_ROOT ($(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null))"
    fi
  fi
  SERVER_DIR=$REPO_ROOT/server
  ((DRY_RUN)) || [[ -f $SERVER_DIR/docker-compose.yml ]] || die "В $SERVER_DIR нет docker-compose.yml"
}

compose() { docker compose --project-directory "$SERVER_DIR" -f "$SERVER_DIR/docker-compose.yml" "$@"; }

postgres_has_data() {
  ((DRY_RUN)) && return 1
  docker volume ls -q 2>/dev/null | grep -qE '(^|_)sinhron_pgdata$'
}

write_env() {
  step "Пароли и ключи"
  local env_file=$SERVER_DIR/.env
  load_env "$env_file"
  if [[ -z ${ENV_OLD[SINHRON_DB_PASSWORD]:-} ]] && postgres_has_data; then
    die "База данных уже есть, а пароля к ней в $env_file нет (файл удалён?).
  Верните .env из резервной копии. Если данные не нужны: docker compose down -v (удалит ВСЕ сообщения)."
  fi
  local had_secrets=0
  [[ -n ${ENV_OLD[TURN_SHARED_SECRET]:-} && ${ENV_OLD[TURN_SHARED_SECRET]} != devturnsecret* ]] && had_secrets=1
  # A failure while making a secret must not reach the file: openssl is
  # checked first (inside render_env a failed $(…) goes unnoticed), and the
  # text is rendered whole before the file is touched.
  ((DRY_RUN)) || [[ $(rand_hex 4 2>/dev/null || true) =~ ^[0-9a-f]{8}$ ]] ||
    die "openssl не выдаёт случайные числа — пароли и ключи не создать, $env_file не тронут"
  local env_text
  env_text=$(render_env "$PUBLIC_IP" "$LOCAL_IP") || die "Не удалось создать пароли и ключи — $env_file не тронут"
  printf '%s\n' "$env_text" | write_file "$env_file" 0600
  if ((had_secrets)); then skip "Пароли и ключи уже были — оставлены как есть"; else ok "Созданы пароль базы, ключи LiveKit и TURN"; fi
  ok "$env_file (доступ только root)"
  # deploy-deps:8 / D-P1 — said on every run until the operator switches:
  # an existing server keeps logging in to the database as its superuser.
  if ((!DRY_RUN)) && grep -qx 'SINHRON_DB_APP_USER=sinhron' "$env_file"; then
    warn "Сервер ходит в базу суперпользователем — когда будет время, переключите на свою роль: docs/deploy-guide.md §9.1, шаг 3 (сейчас всё работает как раньше)"
  fi
}

start_services() {
  step "Сборка и запуск"
  say "  Первая сборка занимает 5–15 минут (Rust и Caddy собираются на сервере)…"
  run compose pull --quiet --ignore-buildable
  run compose build --pull
  ok "Образы собраны"
  prepare_neighbours
  # deploy-deps:8 — the server's own database role exists and owns the
  # tables before the server logs in with it (idempotent; nothing to do
  # while it is still the superuser `sinhron`).
  run compose up -d --wait postgres
  run compose exec -T postgres sh /docker-entrypoint-initdb.d/10-app-role.sh
  local stale
  stale=$(stale_config_services)
  run compose up -d --remove-orphans
  ok "Контейнеры запущены"
  apply_mounted_configs "$stale"
}

# Audit 2026-11b, D-G1 — `compose up -d` leaves a running container on its
# old copy of a mounted settings file: a new Caddyfile / livekit.yaml /
# turnserver.conf lay on disk and did nothing until a reboot. The sums of the
# three files are kept from the last run; a service that was already running
# and whose file differs is recreated. Never fatal: the hint says what to run.
readonly MOUNTED_CONFIGS="caddy:Caddyfile livekit:livekit.yaml coturn:turnserver.conf"
mounted_sums() { (cd "$SERVER_DIR" && cksum Caddyfile livekit.yaml turnserver.conf 2>/dev/null) || true; }
stale_config_services() {
  ((DRY_RUN)) && return 0
  local pair svc file now
  now=$(mounted_sums)
  for pair in $MOUNTED_CONFIGS; do
    svc=${pair%%:*} file=${pair#*:}
    grep -qxF "$(grep " $file\$" <<<"$now")" "$CONFIG_DIR/mounted-configs.sums" 2>/dev/null && continue
    [[ -n $(compose ps -q "$svc" 2>/dev/null) ]] && printf '%s ' "$svc"
  done
  return 0
}
apply_mounted_configs() {
  ((DRY_RUN)) && return 0
  local stale=$1
  if [[ -n ${stale// /} ]]; then
    # shellcheck disable=SC2086 # a word list on purpose
    if run compose up -d --wait --force-recreate --no-deps $stale; then
      ok "Перезапущены с новыми файлами настроек: $stale"
    else
      warn "Не удалось перезапустить с новыми настройками: $stale
  Сделайте это вручную: cd $SERVER_DIR && docker compose -f docker-compose.yml up -d --wait --force-recreate $stale"
      return 0
    fi
  fi
  mounted_sums | write_file "$CONFIG_DIR/mounted-configs.sums" 0644
}

# Status 203 — Caddy can serve other projects' sites: compose needs the
# external `edge` network to exist before `up`, and the folder Caddy imports
# site files from. Both idempotent; an empty folder changes nothing.
prepare_neighbours() {
  run install -d -m 0755 "$CADDY_SITES_DIR"
  if ((!DRY_RUN)) && docker network inspect "$EDGE_NETWORK" >/dev/null 2>&1; then
    skip "Сеть $EDGE_NETWORK для соседних сайтов уже есть"
  else
    run docker network create "$EDGE_NETWORK"
    ok "Создана сеть $EDGE_NETWORK для соседних сайтов ($CADDY_SITES_DIR)"
  fi
}

wait_healthy() {
  step "Проверка, что сервер отвечает"
  ((DRY_RUN)) && { skip "dry-run: не проверяю"; return 0; }
  local url="https://${CFG[SINHRON_DOMAIN]}/_healthz" deadline=$((SECONDS + 300)) local_ok=0
  while ((SECONDS < deadline)); do
    if ((!local_ok)) && [[ $(docker inspect -f '{{.State.Health.Status}}' sinhron-server 2>/dev/null) == healthy ]]; then
      local_ok=1
      ok "Сервер внутри работает"
    fi
    if curl -fsS --max-time 8 "$url" 2>/dev/null | grep -q '"sinhron-server"'; then
      ok "Снаружи отвечает: $url"
      return 0
    fi
    sleep 5
  done
  warn "За 5 минут $url не ответил."
  compose ps >&2 || true
  printf '\n    Последние строки Caddy (сертификаты):\n' >&2
  docker logs --tail 15 sinhron-caddy 2>&1 | sed 's/^/      /' >&2 || true
  printf '\n    Частые причины: DNS ещё не обновился, порты 80/443 закрыты в firewall облака,\n' >&2
  printf '    Let'"'"'s Encrypt временно ограничил выдачу. Сервер продолжит попытки сам.\n' >&2
  return 1
}

setup_backups() {
  step "Резервные копии"
  if [[ ${CFG[DAILY_BACKUP]} != yes ]]; then
    skip "Выключены в настройках"
    return 0
  fi
  local pass=$CONFIG_DIR/backup-pass dir=${CFG[BACKUP_DIR]}
  if [[ -s $pass ]]; then
    skip "Пароль копий уже есть ($pass)"
  else
    rand_hex 32 | write_file "$pass" 0600
    ok "Создан пароль для шифрования копий: $pass"
  fi
  run install -d -m 0700 "$dir"
  write_file /etc/cron.d/sinhron-backup 0644 <<EOF
# Written by Sinhron install.sh — nightly backup (docs/deploy-guide.md §8).
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * * root cd $SERVER_DIR && SINHRON_BACKUP_PASSFILE=$pass scripts/backup.sh $dir >> /var/log/sinhron-backup.log 2>&1
EOF
  ok "Каждую ночь в 03:00 → $dir (журнал /var/log/sinhron-backup.log)"
  warn "Скопируйте $pass в надёжное место вне сервера — без него .env из копии не расшифровать"
}

finish() {
  local addr="https://${CFG[SINHRON_DOMAIN]}"
  local qr="$QR_PREFIX$addr"
  printf '\n%s══════════════════════════════════════════════════════════════%s\n' "$C_GREEN" "$C_RESET"
  printf '%s  Sinhron работает%s\n' "$C_BOLD$C_GREEN" "$C_RESET"
  printf '%s══════════════════════════════════════════════════════════════%s\n\n' "$C_GREEN" "$C_RESET"
  printf '  Адрес сервера для приложения:  %s%s%s\n\n' "$C_BOLD" "${CFG[SINHRON_DOMAIN]}" "$C_RESET"
  if have qrencode && ((!DRY_RUN)); then
    printf '  Или отсканируйте в приложении («Сканировать QR-код сервера»):\n\n'
    qrencode -t ANSIUTF8 -m 2 "$qr" | sed 's/^/    /'
    qrencode -o "$CONFIG_DIR/server-qr.png" -s 8 -m 2 "$qr" 2>/dev/null && printf '\n  QR-код картинкой: %s\n' "$CONFIG_DIR/server-qr.png"
  fi
  printf '\n  %sФайлы%s\n' "$C_BOLD" "$C_RESET"
  printf '    Настройки:  %s\n' "$CONFIG_FILE"
  printf '    Секреты:    %s/.env\n' "$SERVER_DIR"
  printf '    Журнал:     %s\n' "$LOG_FILE"
  printf '\n  %sКоманды%s\n' "$C_BOLD" "$C_RESET"
  printf '    Состояние:  cd %s && docker compose -f docker-compose.yml ps\n' "$SERVER_DIR"
  printf '    Логи:       cd %s && docker compose -f docker-compose.yml logs -f --tail 100\n' "$SERVER_DIR"
  printf '    Обновить:   sudo bash %s/install.sh --yes --commit <id коммита>\n' "$SERVER_DIR"
  printf '\n  %sЕсли у провайдера есть свой firewall%s (Hetzner Cloud Firewall, AWS Security Group…),\n' "$C_BOLD" "$C_RESET"
  printf '  откройте там те же порты: %s/tcp %s\n' "$SSH_PORT" "${FIREWALL_RULES[*]}"
  ((REBOOT_NEEDED)) && printf '\n  %s!%s Обновление ядра ждёт перезагрузки: sudo reboot (сервер поднимется сам)\n' "$C_YELLOW" "$C_RESET"
  printf '\n'
  log "done: $addr"
}

usage() {
  cat <<EOF
Установщик сервера Sinhron (Ubuntu 22.04 / 24.04).

  sudo $(script_self) [параметры]

Без параметров спросит: ответить на вопросы сейчас или создать файл настроек.

  -i, --interactive     ответить на вопросы (сохранятся в $CONFIG_FILE)
  -w, --write-config    только создать файл настроек и выйти
  -y, --yes             ничего не спрашивать, взять настройки из файла
  -c, --config ФАЙЛ     другой файл настроек (по умолчанию $CONFIG_FILE)
      --commit ID       обновить код ровно до этого коммита (полный id, 40 знаков);
                        без него код не обновляется
      --skip-dns-check  не ждать DNS-записей
      --no-upgrade      не обновлять пакеты системы
      --dry-run         показать, что будет сделано, ничего не меняя
  -h, --help            эта справка

Повторный запуск безопасен: сделанное пропускается; код обновляется только с --commit.
EOF
}

parse_args() {
  while (($#)); do
    case $1 in
      -i | --interactive) MODE=interactive ;;
      -w | --write-config) MODE=write-config ;;
      -y | --yes) MODE=yes ;;
      -c | --config)
        [[ -n ${2:-} ]] || die "--config: укажите путь к файлу"
        CONFIG_FILE=$2
        CONFIG_DIR=$(dirname "$2")
        shift
        ;;
      --commit)
        valid_commit "${2:-}" || die "--commit: укажите полный id коммита"
        PIN_COMMIT=$2
        shift
        ;;
      --skip-dns-check) SKIP_DNS_CHECK=1 ;;
      --no-upgrade) SKIP_UPGRADE=1 ;;
      --dry-run) DRY_RUN=1 ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; die "Неизвестный параметр: $1" ;;
    esac
    shift
  done
}

banner() {
  printf '\n%s  Sinhron · установка сервера%s  %s(installer v%s)%s\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$INSTALLER_VERSION" "$C_RESET"
  ((DRY_RUN)) && printf '  %sРежим --dry-run: ничего не меняется, команды только показываются.%s\n' "$C_CYAN" "$C_RESET"
  return 0
}

# The folder of sinhron.conf and the backup password. Only a folder we make,
# or our own /etc/sinhron, gets its mode: `--config /tmp/s.conf` used to turn
# /tmp itself (or /etc, a home folder) into 0750 (audit 2026-11b).
prepare_config_dir() {
  if [[ ! -d $CONFIG_DIR ]]; then
    mkdir -p "$CONFIG_DIR" && chmod 0750 "$CONFIG_DIR"
  elif [[ $CONFIG_DIR == "$CONFIG_DIR_DEFAULT" ]]; then
    chmod 0750 "$CONFIG_DIR"
  fi
}

main() {
  parse_args "$@"
  require_root "$@"
  # A dry run changes nothing — not even the system log.
  ((DRY_RUN)) && [[ -z ${SINHRON_LOG_FILE:-} ]] && LOG_FILE=$(mktemp -t sinhron-dry-run.XXXXXX)
  if ((!DRY_RUN)); then
    mkdir -p "$(dirname "$LOG_FILE")"
    prepare_config_dir
    touch "$LOG_FILE" && chmod 0600 "$LOG_FILE"
  fi
  trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
  acquire_lock
  banner
  log "installer v$INSTALLER_VERSION start: $*"
  choose_mode
  check_system
  resolve_network
  resolve_ntfy
  check_dns
  install_packages
  install_docker
  setup_firewall
  fetch_code
  write_env
  start_services
  local healthy=0
  wait_healthy && healthy=1
  setup_backups
  ((healthy)) || warn "Сервер ещё не отвечает снаружи — см. выше; остальное установлено"
  finish
}

# Sourced by the tests: only the functions, nothing runs.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
