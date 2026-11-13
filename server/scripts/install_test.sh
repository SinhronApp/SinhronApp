#!/usr/bin/env bash
# Tests for server/install.sh (ADR-032): config parsing and validation, the
# .env (secrets made once, then kept), NAT and DNS logic, and a full
# --dry-run of the install with the system commands stubbed out.
#
#   bash server/scripts/install_test.sh        (bash 4+; CI runs it on Ubuntu)

# shellcheck disable=SC2034,SC2317 # variables are read by the sourced installer; stubs are called by it
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALL=$HERE/../install.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0 FAIL=0
check() { # check "name" actual expected
  if [[ $2 == "$3" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n  got:      %q\n  expected: %q\n' "$1" "$2" "$3"
  fi
}
check_true() { if "${@:2}"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; fi; }
check_false() { if "${@:2}"; then FAIL=$((FAIL + 1)); printf 'FAIL %s (expected failure)\n' "$1"; else PASS=$((PASS + 1)); fi; }

export NO_COLOR=1
export SINHRON_CONFIG_DIR=$WORK/etc SINHRON_LOG_FILE=$WORK/install.log
mkdir -p "$WORK/etc"
# shellcheck source=../install.sh
source "$INSTALL"
set +e # the installer's errexit is for real runs

# ── Validators ───────────────────────────────────────────────────────────
for d in chat.example.com a.b.co xn--80ak6aa92e.xn--p1ai sub-1.my-host.org; do check_true "domain ok: $d" valid_domain "$d"; done
for d in example localhost '-bad.example.com' 'bad_.example.com' 'a..b.com' 'chat.example.123' 'with space.com'; do
  check_false "domain bad: $d" valid_domain "$d" 2>/dev/null
done
for ip in 1.2.3.4 255.255.255.255 0.0.0.0; do check_true "ip ok: $ip" valid_ipv4 "$ip"; done
for ip in 256.1.1.1 1.2.3 1.2.3.4.5 a.b.c.d 01.2.3.999; do check_false "ip bad: $ip" valid_ipv4 "$ip"; done
check_true "auto ip" valid_ip_or_auto auto
check_false "port 0" valid_port 0 2>/dev/null
check_true "port 2222" valid_port 2222
check_false "days 0" valid_days 0 2>/dev/null
check_true "yes/no" valid_yes_no YES

# ── Config: template → edit → load ───────────────────────────────────────
CONFIG_FILE=$WORK/etc/sinhron.conf
config_defaults
render_config >"$CONFIG_FILE"
load_config "$CONFIG_FILE" 2>/dev/null
check "template has no domain" "${CFG[SINHRON_DOMAIN]}" ""
check_false "empty template does not validate" validate_config 2>/dev/null

sed -i.bak 's/^SINHRON_DOMAIN=.*/SINHRON_DOMAIN = "Chat.Example.COM"   # мой домен/' "$CONFIG_FILE" && rm -f "$CONFIG_FILE.bak"
load_config "$CONFIG_FILE"
check "domain lower-cased, quotes and comment dropped" "${CFG[SINHRON_DOMAIN]}" chat.example.com
check "livekit derived" "${CFG[LIVEKIT_DOMAIN]}" livekit.chat.example.com
check "turn derived" "${CFG[TURN_DOMAIN]}" turn.chat.example.com
check_true "edited config validates" validate_config

# Round trip: what render_config writes, load_config reads back the same.
CFG[PUBLIC_IP]=203.0.113.7 CFG[DAILY_BACKUP]=no CFG[MESSAGE_RETENTION_DAYS]=30
declare -A before=()
for k in "${!CFG[@]}"; do before[$k]=${CFG[$k]}; done
render_config >"$WORK/rt.conf"
load_config "$WORK/rt.conf"
rt_ok=1
for k in "${!before[@]}"; do [[ ${CFG[$k]} == "${before[$k]}" ]] || { rt_ok=0; echo "  differs: $k"; }; done
check "render → load round trip" "$rt_ok" 1

# Every problem is listed at once.
config_defaults
CFG[SINHRON_DOMAIN]=bad CFG[PUBLIC_IP]=999.1.1.1 CFG[MESSAGE_RETENTION_DAYS]=x CFG[DAILY_BACKUP]=maybe
errs=$(validate_config 2>&1)
check "validation fails" "$?" 1
check "all four errors reported" "$(grep -c '•' <<<"$errs")" 4

# Unknown keys warn; garbage lines stop with the line number.
printf 'SINHRON_DOMAIN=chat.example.com\nFOO=bar\n' >"$WORK/unknown.conf"
out=$(load_config "$WORK/unknown.conf" 2>&1)
check "unknown key warns" "$(grep -c 'неизвестный ключ FOO' <<<"$out")" 1
printf 'SINHRON_DOMAIN=chat.example.com\nthis is not a setting\n' >"$WORK/garbage.conf"
out=$( (load_config "$WORK/garbage.conf") 2>&1)
check "garbage line names the line" "$(grep -c 'garbage.conf:2' <<<"$out")" 1

# Same three names twice is refused.
config_defaults
CFG[SINHRON_DOMAIN]=chat.example.com CFG[LIVEKIT_DOMAIN]=chat.example.com
apply_derived_defaults
check_false "names must differ" validate_config 2>/dev/null

# ── NAT ──────────────────────────────────────────────────────────────────
check "public IP on the interface" "$(turn_external_ip 203.0.113.7 203.0.113.7)" 203.0.113.7
check "1:1 NAT" "$(turn_external_ip 203.0.113.7 10.0.0.5)" 203.0.113.7/10.0.0.5
check "no local IP" "$(turn_external_ip 203.0.113.7 '')" 203.0.113.7

# ── DNS ──────────────────────────────────────────────────────────────────
resolve_ipv4() {
  case $1 in
    chat.example.com) printf '203.0.113.7\n' ;;
    livekit.chat.example.com) printf '198.51.100.1\n203.0.113.7\n' ;;
    turn.chat.example.com) ;;
  esac
}
bad=$(dns_mismatches 203.0.113.7 chat.example.com livekit.chat.example.com turn.chat.example.com)
check "only the missing name is reported" "$(cut -f1 <<<"$bad")" turn.chat.example.com

# ── .env: secrets made once, kept after; hand-added lines kept ───────────
config_defaults
CFG[SINHRON_DOMAIN]=chat.example.com
apply_derived_defaults
ENV_OLD=()
render_env 203.0.113.7 203.0.113.7 >"$WORK/.env"
load_env "$WORK/.env"
first_db=${ENV_OLD[SINHRON_DB_PASSWORD]}
first_turn=${ENV_OLD[TURN_SHARED_SECRET]}
first_lk=${ENV_OLD[LIVEKIT_KEYS]}
check "db password is 64 hex" "$([[ $first_db =~ ^[0-9a-f]{64}$ ]] && echo y)" y
check "turn secret is 64 hex" "$([[ $first_turn =~ ^[0-9a-f]{64}$ ]] && echo y)" y
check "livekit keys 'key: secret'" "$([[ $first_lk =~ ^API[0-9a-f]{16}:\ [0-9a-f]{64}$ ]] && echo y)" y
check "TURN URLs" "${ENV_OLD[TURN_URLS]}" "turn:chat.example.com:3478?transport=udp,turn:chat.example.com:3478?transport=tcp,turns:turn.chat.example.com:443?transport=tcp"
check "TURN external IP" "${ENV_OLD[TURN_EXTERNAL_IP]}" 203.0.113.7
check "hostnames" "${ENV_OLD[SINHRON_LIVEKIT_HOSTNAME]} ${ENV_OLD[SINHRON_TURN_HOSTNAME]}" "livekit.chat.example.com turn.chat.example.com"
check "no pgbouncer by default" "${ENV_OLD[COMPOSE_PROFILES]:-}" ""
first_app=${ENV_OLD[SINHRON_DB_APP_PASSWORD]:-}
first_ntfy=${ENV_OLD[SINHRON_NTFY_TOKEN]:-}
check "a new install: the server's own db role" "${ENV_OLD[SINHRON_DB_APP_USER]}" sinhron_app
check "its password is 64 hex" "$([[ $first_app =~ ^[0-9a-f]{64}$ ]] && echo y)" y
check "ntfy token: tk_ and 29 letters/digits" "$([[ $first_ntfy =~ ^tk_[a-z0-9]{29}$ ]] && echo y)" y

printf 'SINHRON_RATE_SUBMIT=900/60\n' >>"$WORK/.env"
CFG[ENABLE_PGBOUNCER]=yes CFG[MESSAGE_RETENTION_DAYS]=30
load_env "$WORK/.env"
render_env 203.0.113.7 10.0.0.5 >"$WORK/.env2"
load_env "$WORK/.env2"
check "db password kept on rerun" "${ENV_OLD[SINHRON_DB_PASSWORD]}" "$first_db"
check "turn secret kept" "${ENV_OLD[TURN_SHARED_SECRET]}" "$first_turn"
check "livekit keys kept" "${ENV_OLD[LIVEKIT_KEYS]}" "$first_lk"
check "db role and its password kept" "${ENV_OLD[SINHRON_DB_APP_USER]} ${ENV_OLD[SINHRON_DB_APP_PASSWORD]}" "sinhron_app $first_app"
check "ntfy token kept" "${ENV_OLD[SINHRON_NTFY_TOKEN]}" "$first_ntfy"
check "hand-added line kept" "${ENV_OLD[SINHRON_RATE_SUBMIT]}" 900/60
check "config change applied" "${ENV_OLD[SINHRON_MESSAGE_RETENTION_DAYS]}" 30
check "NAT form" "${ENV_OLD[TURN_EXTERNAL_IP]}" 203.0.113.7/10.0.0.5
check "pgbouncer on" "${ENV_OLD[COMPOSE_PROFILES]} ${ENV_OLD[SINHRON_DB_HOST]}" "pgbouncer pgbouncer"
check "no administrators by default" "${ENV_OLD[SINHRON_ADMIN_IDENTITIES]:-}" ""

# ADR-077 — administrators: spaces / upper case tidied, written to .env;
# emptied in the config → gone from .env.
a=$(printf 'aa%.0s' {1..32}) b=$(printf 'BB%.0s' {1..32})
CFG[ADMIN_KEYS]="$a  $b"
apply_derived_defaults
check_true "two admin keys validate" validate_config
render_env 203.0.113.7 10.0.0.5 >"$WORK/.env-admin"
load_env "$WORK/.env-admin"
check "admin keys in .env" "${ENV_OLD[SINHRON_ADMIN_IDENTITIES]}" "$a,${b,,}"
CFG[ADMIN_KEYS]=''
render_env 203.0.113.7 10.0.0.5 >"$WORK/.env-admin2"
load_env "$WORK/.env-admin2"
check "admin keys removed" "${ENV_OLD[SINHRON_ADMIN_IDENTITIES]:-}" ""
CFG[ADMIN_KEYS]='not-a-key'
check_false "bad admin key refused" validate_config 2>/dev/null
CFG[ADMIN_KEYS]=''

CFG[ENABLE_PGBOUNCER]=no
render_env 203.0.113.7 203.0.113.7 >"$WORK/.env3"
load_env "$WORK/.env3"
check "pgbouncer off again drops its lines" "${ENV_OLD[COMPOSE_PROFILES]:-}${ENV_OLD[SINHRON_DB_HOST]:-}" ""
check "each key once" "$(grep -cE '^[A-Z_]+=' "$WORK/.env3")" "$(cut -d= -f1 "$WORK/.env3" | grep -E '^[A-Z_]+$' | sort -u | wc -l | tr -d ' ')"

# ADR-040 — own ntfy for Android push: on by default; the host is found in DNS
# (owner, 2026-10-18: "the installer must find it for any server").
check "push on by default" "$(config_defaults; printf '%s' "${CFG[ENABLE_NTFY]}")" yes
check "where to look" "$(ntfy_candidates | tr '\n' ' ')" "push.chat.example.com push.example.com "
check "no parent for a two-part domain" "$(CFG[SINHRON_DOMAIN]=example.com; ntfy_candidates | tr '\n' ' ')" "push.example.com "
PUBLIC_IP=203.0.113.7
resolve_ipv4() { [[ $1 == push.example.com ]] && printf '203.0.113.7\n'; return 0; }
CFG[ENABLE_NTFY]=yes CFG[NTFY_DOMAIN]=''
resolve_ntfy >/dev/null 2>&1
check "the name that points here is found" "$NTFY_HOST" push.example.com
resolve_ipv4() { [[ $1 == push.chat.example.com || $1 == push.example.com ]] && printf '203.0.113.7\n'; return 0; }
resolve_ntfy >/dev/null 2>&1
check "push.<domain> first when both point here" "$NTFY_HOST" push.chat.example.com
resolve_ipv4() { [[ $1 == push.chat.example.com ]] && printf '198.51.100.1\n'; return 0; }
resolve_ntfy >/dev/null 2>&1
check "no record for this server: push off, install goes on" "$NTFY_HOST" ""
CFG[NTFY_DOMAIN]=push.chat.example.com
resolve_ntfy >/dev/null 2>&1
check "a name set by hand is kept" "$NTFY_HOST" push.chat.example.com
render_env 203.0.113.7 203.0.113.7 >"$WORK/.env5"
load_env "$WORK/.env5"
check "ntfy on" "${ENV_OLD[COMPOSE_PROFILES]} ${ENV_OLD[SINHRON_NTFY_HOSTNAME]} ${ENV_OLD[SINHRON_UNIFIEDPUSH_HOSTS]}" "ntfy push.chat.example.com push.chat.example.com"
CFG[ENABLE_PGBOUNCER]=yes
render_env 203.0.113.7 203.0.113.7 >"$WORK/.env6"
load_env "$WORK/.env6"
check "pgbouncer and ntfy together" "${ENV_OLD[COMPOSE_PROFILES]}" "pgbouncer,ntfy"
CFG[ENABLE_PGBOUNCER]=no CFG[ENABLE_NTFY]=no
resolve_ntfy >/dev/null 2>&1
render_env 203.0.113.7 203.0.113.7 >"$WORK/.env7"
load_env "$WORK/.env7"
check "ntfy off again drops its lines" "${ENV_OLD[COMPOSE_PROFILES]:-}${ENV_OLD[SINHRON_NTFY_HOSTNAME]:-}${ENV_OLD[SINHRON_UNIFIEDPUSH_HOSTS]:-}" ""
CFG[ENABLE_NTFY]=yes CFG[NTFY_DOMAIN]=chat.example.com
check_false "ntfy domain must differ from the server's" validate_config
CFG[ENABLE_NTFY]=bogus CFG[NTFY_DOMAIN]=''
check_false "ENABLE_NTFY must be yes/no" validate_config
CFG[ENABLE_NTFY]=no CFG[NTFY_DOMAIN]=''
NTFY_HOST=''

# The repo's dev placeholders are never shipped.
ENV_OLD=([SINHRON_DB_PASSWORD]=change-me-before-prod [LIVEKIT_KEYS]='devkey: devsecret' [TURN_SHARED_SECRET]=devturnsecret_x)
render_env 203.0.113.7 '' >"$WORK/.env4"
check "no dev placeholders" "$(grep -cE 'change-me|devkey|devturnsecret' "$WORK/.env4")" 0
# deploy-deps:8 — an existing install keeps its superuser login until switched.
ENV_OLD=([SINHRON_DB_PASSWORD]=$first_db)
render_env 203.0.113.7 '' >"$WORK/.env-old"
load_env "$WORK/.env-old"
check "an existing install keeps the superuser until switched" "${ENV_OLD[SINHRON_DB_APP_USER]} ${ENV_OLD[SINHRON_DB_APP_PASSWORD]:-none}" "sinhron none"
ENV_OLD=([SINHRON_DB_PASSWORD]=GENERATE_RANDOM_HEX_64_HERE [LIVEKIT_KEYS]='GENERATE_KEY: GENERATE_RANDOM_BASE64_SECRET_HERE' [TURN_SHARED_SECRET]=GENERATE_RANDOM_HEX_64_HERE)
render_env 203.0.113.7 '' >"$WORK/.env4"
check "no deploy-guide placeholders" "$(grep -c GENERATE_ "$WORK/.env4")" 0

# ── Questions: answers are checked, retried, saved in the same config ───
answers() { printf '%s\n' "$@" >"$WORK/answers"; }
interactive() ( # runs in a subshell: exit codes and globals stay here
  TTY_IN=$WORK/answers TTY=/dev/null TTY_FD_OPEN=
  CONFIG_FILE=$1
  shift
  detect_public_ip() { printf '203.0.113.9'; }
  "$@"
)
answers 'not a domain' 'Chat.Test.org' '' '' '30' 'н' '' 'abc' "$(printf 'AB%.0s' {1..32})"
interactive "$WORK/ask.conf" ask_config >/dev/null 2>&1
check "answers saved" "$?" 0
config_defaults
load_config "$WORK/ask.conf"
check "bad answer retried, then saved lower-case" "${CFG[SINHRON_DOMAIN]}" chat.test.org
check "call names default" "${CFG[LIVEKIT_DOMAIN]} ${CFG[TURN_DOMAIN]}" "livekit.chat.test.org turn.chat.test.org"
check "detected IP taken on Enter" "${CFG[PUBLIC_IP]}" 203.0.113.9
check "typed days" "${CFG[MESSAGE_RETENTION_DAYS]}" 30
check "no backups (answered н)" "${CFG[DAILY_BACKUP]}" no
check "updates default yes" "${CFG[AUTO_SECURITY_UPDATES]}" yes
check "admin address retried, then saved lower-case" "${CFG[ADMIN_KEYS]}" "$(printf 'ab%.0s' {1..32})"

# Own names for calls.
answers 'chat.test.org' 'n' 'calls.test.org' 'relay.test.org' '' '' '' '' ''
interactive "$WORK/ask2.conf" ask_config >/dev/null 2>&1
config_defaults
load_config "$WORK/ask2.conf"
check "custom call names" "${CFG[LIVEKIT_DOMAIN]} ${CFG[TURN_DOMAIN]}" "calls.test.org relay.test.org"

# First run without a config: "2" writes the template and stops.
answers '2'
( MODE=auto; interactive "$WORK/menu.conf" choose_mode ) >/dev/null 2>&1
check "menu 2 exits cleanly" "$?" 0
check "menu 2 wrote the template" "$(grep -c '^SINHRON_DOMAIN=$' "$WORK/menu.conf")" 1
# "1" asks the questions and saves them in the same format.
answers '1' 'chat.test.org' '' '' '' '' '' ''
( MODE=auto; interactive "$WORK/menu1.conf" choose_mode ) >/dev/null 2>&1
check "menu 1 saved answers" "$(grep -c '^SINHRON_DOMAIN=chat.test.org$' "$WORK/menu1.conf")" 1
check "same keys as the template" "$(grep -oE '^[A-Z_]+=' "$WORK/menu1.conf" | tr -d '\n')" "$(grep -oE '^[A-Z_]+=' "$WORK/menu.conf" | tr -d '\n')"
# --write-config refuses to overwrite an existing file.
( MODE=write-config; CONFIG_FILE=$WORK/menu1.conf; choose_mode ) >/dev/null 2>&1
check "write-config keeps an existing file" "$?" 1

# ── Full --dry-run with the system stubbed ───────────────────────────────
cat >"$WORK/meminfo" <<'EOF'
MemTotal:        3000000 kB
SwapTotal:             0 kB
EOF
cat >"$WORK/etc/sinhron.conf" <<'EOF'
SINHRON_DOMAIN=chat.example.com
PUBLIC_IP=203.0.113.7
SSH_PORT=2222
EOF
dry=$(
  SINHRON_MEMINFO=$WORK/meminfo
  MEMINFO=$WORK/meminfo
  SWAPFILE=$WORK/swapfile # CI runners already have /swapfile
  check_system() { step "Проверка системы"; OS_CODENAME=noble; ok "stub"; }
  detect_local_ip() { printf '203.0.113.7'; }
  resolve_ipv4() { printf '203.0.113.7\n'; }
  have() { [[ $1 != docker ]] && command -v "$1" >/dev/null 2>&1; }
  dpkg() { printf 'amd64\n'; } # not on macOS dev machines
  qrencode() { :; }
  main --dry-run --yes 2>&1
)
code=$?
check "dry run succeeds" "$code" 0
for want in 'apt-get -y -q' 'docker-compose-plugin' 'ufw allow 2222/tcp' 'ufw allow 49152:49999/udp' 'ufw --force enable' \
  'fallocate -l 2G' 'write /etc/fail2ban/jail.d/sinhron-sshd.local' 'compose build --pull' \
  'install -d -m 0755 /etc/sinhron/caddy-sites' 'docker network create edge' \
  'compose up -d --remove-orphans' 'write /etc/cron.d/sinhron-backup' 'chat.example.com' 'Все имена (4) указывают' \
  'Push для Android: push.chat.example.com'; do
  check "dry run mentions: $want" "$(grep -cF -- "$want" <<<"$dry" | awk '{ print ($1 > 0) }')" 1
done
check "dry run wrote nothing to /etc" "$(ls "$WORK/etc")" sinhron.conf
check "the edge network exists before compose up" \
  "$(grep -nF -e 'docker network create edge' -e 'compose up -d' <<<"$dry" | cut -d: -f1 | tr '\n' ' ')" \
  "$(grep -nF -e 'docker network create edge' -e 'compose up -d' <<<"$dry" | cut -d: -f1 | sort -n | tr '\n' ' ')"
check "SSH is allowed before ufw is enabled" \
  "$(grep -nF -e 'ufw allow 2222/tcp' -e 'ufw --force enable' <<<"$dry" | cut -d: -f1 | tr '\n' ' ')" \
  "$(grep -nF -e 'ufw allow 2222/tcp' -e 'ufw --force enable' <<<"$dry" | cut -d: -f1 | sort -n | tr '\n' ' ')"

# ── Updates move only to the named commit (deploy-deps:5) ───────────────
# Whoever could push to the branch ran their code as root at the next
# `install.sh --yes` (and in the nightly backup cron, from the same tree).
check_true "full commit id ok" valid_commit "$(printf '%040d' 0 | tr 0 a)"
check_false "short commit id refused" valid_commit abc1234 2>/dev/null
check_false "a branch name is not a commit" valid_commit main 2>/dev/null
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
g init -q --bare "$WORK/origin.git"
g clone -q "$WORK/origin.git" "$WORK/dev" 2>/dev/null
mkdir -p "$WORK/dev/server" && : >"$WORK/dev/server/docker-compose.yml"
g -C "$WORK/dev" add server && g -C "$WORK/dev" commit -q -m owner
owner=$(git -C "$WORK/dev" rev-parse HEAD)
g -C "$WORK/dev" push -q origin HEAD:main 2>/dev/null
g clone -q "$WORK/origin.git" "$WORK/opt"
g -C "$WORK/dev" commit -q --allow-empty -m attacker
attacker=$(git -C "$WORK/dev" rev-parse HEAD)
g -C "$WORK/dev" push -q origin HEAD:main 2>/dev/null
update() ( # update [--commit id]: fetch_code on $WORK/opt, as an update would
  script_self() { printf '%s' "$WORK/nowhere/install.sh"; }
  DRY_RUN=0 CFG[INSTALL_DIR]=$WORK/opt CFG[REPO_BRANCH]=main PIN_COMMIT=${2:-}
  fetch_code
) >/dev/null 2>&1
mkdir -p "$WORK/nowhere"
check_true "no --commit: the update still runs" update
check "no --commit: the pushed commit is not installed" "$(git -C "$WORK/opt" rev-parse HEAD)" "$owner"
check_false "a commit that isn't there: refused" update --commit "$(printf '%040d' 7)"
check "…and the code is not touched" "$(git -C "$WORK/opt" rev-parse HEAD)" "$owner"
check_true "--commit with a commit that is there" update --commit "$attacker"
check "--commit moves to exactly that commit" "$(git -C "$WORK/opt" rev-parse HEAD)" "$attacker"
update --commit "$owner"
check "--commit can go back too" "$(git -C "$WORK/opt" rev-parse HEAD)" "$owner"
parse_commit() ( parse_args --commit "$1" ) 2>/dev/null
check_false "--commit needs a full id" parse_commit abc
# Audit 2026-11b — run from a checkout with local edits, `--commit` was
# skipped without a word: the old code was rebuilt and reported as done.
: >"$WORK/opt/server/Dockerfile"
update_here() ( # update_here [--commit id]: fetch_code run from $WORK/opt itself
  script_self() { printf '%s' "$WORK/opt/server/install.sh"; }
  DRY_RUN=0 CFG[REPO_BRANCH]=main PIN_COMMIT=${2:-}
  fetch_code
) >/dev/null 2>&1
check_true "run from the checkout: --commit moves the code" update_here --commit "$attacker"
check "…to exactly that commit" "$(git -C "$WORK/opt" rev-parse HEAD)" "$attacker"
echo edited >>"$WORK/opt/server/docker-compose.yml"
check_true "local edits, no --commit: the update still runs" update_here
check_true "local edits, --commit = the commit already there: runs" update_here --commit "$attacker"
check_false "local edits, --commit elsewhere: stops" update_here --commit "$owner"
check "…and neither the code nor the edit is touched" \
  "$(git -C "$WORK/opt" rev-parse HEAD) $(tail -n 1 "$WORK/opt/server/docker-compose.yml")" "$attacker edited"

# ── New settings files reach the running services (audit 2026-11b, D-G1) ─
# `compose up -d` alone left Caddy / LiveKit / coturn on the old mounted file.
G=$WORK/g1
mkdir -p "$G/server" "$G/etc" && echo a >"$G/server/Caddyfile" && echo a >"$G/server/livekit.yaml" && echo a >"$G/server/turnserver.conf"
g1() ( # g1 <running services>: what start_services would recreate
  DRY_RUN=0 SERVER_DIR=$G/server CONFIG_DIR=$G/etc
  compose() {
    case "$*" in
      'ps -q '*) [[ " $RUNNING " == *" $3 "* ]] && echo id ;;
      *) echo "compose $*" >>"$G/log" ;;
    esac
    return "${G1_FAIL:-0}"
  }
  RUNNING=$1
  stale=$(stale_config_services)
  apply_mounted_configs "$stale" >/dev/null 2>&1
  printf '%s' "$stale"
)
check "first install (nothing was running): nothing is recreated" "$(g1 '')" ''
check "…and the sums of the three files are kept" "$(wc -l <"$G/etc/mounted-configs.sums" | tr -d ' ')" 3
check "same files on the next run: nothing is recreated" "$(g1 'caddy livekit coturn')" ''
echo b >"$G/server/turnserver.conf"
check "turnserver.conf changed: coturn alone is recreated" "$(g1 'caddy livekit coturn')" 'coturn '
check "…with one compose call" "$(grep -c 'up -d --wait --force-recreate --no-deps coturn$' "$G/log")" 1
check "…and not again on the run after" "$(g1 'caddy livekit coturn')" ''
echo c >"$G/server/Caddyfile"
check "a failed restart is tried, and does not stop the installer" "$(G1_FAIL=1 g1 'caddy livekit coturn')" 'caddy '
check "…and is tried again on the next run (the sums were not saved)" "$(g1 'caddy livekit coturn')" 'caddy '
rm -f "$G/etc/mounted-configs.sums"
check "an update with no sums yet (the first one after this fix): all three" "$(g1 'caddy livekit coturn')" 'caddy livekit coturn '

# ── --config in a shared folder (audit 2026-11b) ────────────────────────
# `--config /tmp/s.conf` turned /tmp itself into 0750.
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
mkdir -p "$WORK/shared" && chmod 0755 "$WORK/shared"
(CONFIG_DIR=$WORK/shared && prepare_config_dir)
check "an existing folder named by --config keeps its mode" "$(mode_of "$WORK/shared")" 755
(CONFIG_DIR=$WORK/newconf/sinhron && prepare_config_dir)
check "a folder the installer makes is 0750" "$(mode_of "$WORK/newconf/sinhron")" 750

# ── A failed secret never replaces .env (audit 2026-11b) ────────────────
# `render_env | write_file` renamed its temp file over .env even when openssl
# had failed: an empty .env, the database password and call keys gone.
write_env_broken() ( # write_env with a failing openssl, as the installer runs it
  set -Eeuo pipefail
  trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
  rand_hex() { return 1; }
  postgres_has_data() { return 1; }
  DRY_RUN=0 SERVER_DIR=$WORK/envdir PUBLIC_IP=203.0.113.7 LOCAL_IP=203.0.113.7 NTFY_HOST=''
  write_env
) >/dev/null 2>&1
mkdir -p "$WORK/envdir"
printf 'SINHRON_DB_PASSWORD=%064d\nTURN_SHARED_SECRET=keepme\nLIVEKIT_KEYS=APIa: b\nSINHRON_DB_APP_USER=sinhron\n' 0 >"$WORK/envdir/.env"
cp "$WORK/envdir/.env" "$WORK/envdir/.env.before"
check_false "openssl fails: the installer stops" write_env_broken
check_true "…and .env is exactly as it was" cmp -s "$WORK/envdir/.env" "$WORK/envdir/.env.before"
check "…with no temp file left next to it" "$(find "$WORK/envdir" -name '.env.*' ! -name .env.before | wc -l | tr -d ' ')" 0
empty_write() ( DRY_RUN=0; : | write_file "$WORK/envdir/keep" 0600 ) >/dev/null 2>&1
echo secret >"$WORK/envdir/keep"
check_false "write_file refuses an empty result" empty_write
check "…the old file stays" "$(cat "$WORK/envdir/keep")" secret
write_env_ok() (
  postgres_has_data() { return 1; }
  DRY_RUN=0 SERVER_DIR=$WORK/envdir PUBLIC_IP=203.0.113.7 LOCAL_IP=203.0.113.7 NTFY_HOST=''
  write_env
) >/dev/null 2>&1
check_true "openssl works: .env is written" write_env_ok
# D-P1 — an existing server stays the database superuser; the installer says so.
write_env_out() (
  postgres_has_data() { return 1; }
  DRY_RUN=0 SERVER_DIR=$WORK/envdir PUBLIC_IP=203.0.113.7 LOCAL_IP=203.0.113.7 NTFY_HOST=''
  write_env
) 2>&1
check "the superuser role is pointed out" "$(write_env_out | grep -c 'суперпользователем')" 1
sed -i.bak 's/^SINHRON_DB_APP_USER=sinhron$/SINHRON_DB_APP_USER=sinhron_app/' "$WORK/envdir/.env" && rm -f "$WORK/envdir/.env.bak"
check "…and not once the server has its own role" "$(write_env_out | grep -c 'суперпользователем')" 0
sed -i.bak 's/^SINHRON_DB_APP_USER=sinhron_app$/SINHRON_DB_APP_USER=sinhron/' "$WORK/envdir/.env" && rm -f "$WORK/envdir/.env.bak"
check "…old secrets kept, the missing one added" \
  "$(grep -cE '^(TURN_SHARED_SECRET=keepme|LIVEKIT_KEYS=APIa: b|SINHRON_NTFY_TOKEN=tk_[a-z0-9]{29})$' "$WORK/envdir/.env")" 3
check "…mode 0600" "$(stat -c %a "$WORK/envdir/.env" 2>/dev/null || stat -f %Lp "$WORK/envdir/.env")" 600

# ── Compose healthcheck vs the image ────────────────────────────────────
# The runtime image is debian-slim without wget/curl: the server's
# healthcheck must run the binary itself (src/healthcheck.rs), at the path
# the Dockerfile installs it to. CI's `docker-image` job checks it for real.
hc=$(awk '/^  sinhron-server:/ { s = 1; next } s && /^  [a-z]/ { s = 0 } s && /test:/' "$HERE/../docker-compose.yml")
bin=$(sed -n 's/^ENTRYPOINT \["\([^"]*\)"\]$/\1/p' "$HERE/../Dockerfile")
check "Dockerfile entrypoint found" "$bin" /app/sinhron-server
check "server healthcheck runs the binary" "$(grep -cF -- "\"CMD\", \"$bin\", \"--healthcheck\"" <<<"$hc")" 1
check "server healthcheck needs no wget/curl" "$(grep -cE 'wget|curl' <<<"$hc")" 0

# ── Neighbour sites (status 203) ────────────────────────────────────────
# The folder install.sh creates is the one compose mounts, and Caddy joins
# the external network install.sh creates. CI's `docker-image` job runs
# `caddy validate` with the folder empty and with an example site.
caddy_svc=$(awk '/^  caddy:/ { s = 1; next } s && /^  [a-z]/ { s = 0 } s' "$HERE/../docker-compose.yml")
check "compose mounts the sites folder" "$(grep -cF -- "- $CADDY_SITES_DIR:/etc/caddy/sites:ro" <<<"$caddy_svc")" 1
check "caddy joins the edge network" "$(grep -cE -- "^      - $EDGE_NETWORK\$" <<<"$caddy_svc")" 1
check "edge is external, named $EDGE_NETWORK" \
  "$(awk '/^networks:/ { s = 1; next } s && /^[a-z]/ { s = 0 } s' "$HERE/../docker-compose.yml" | grep -A2 -E '^  edge:' | grep -cE "external: true|name: $EDGE_NETWORK\$")" 2
check "Caddyfile imports the sites folder last" "$(grep -vE '^(#|[[:space:]]*$)' "$HERE/../Caddyfile" | tail -1)" 'import /etc/caddy/sites/*.caddy'

# ── Secrets off the command line, hardening (security review 2026-11) ──
# deploy-deps:7 — `ps` on the host shows argv to every local user.
check "no secret flags in compose files" "$(cat "$HERE/../docker-compose.yml" "$HERE/../docker-compose.dev.yml" | grep -cE -- '--keys|--static-auth-secret')" 0
if docker compose version >/dev/null 2>&1; then
  for f in "-f $HERE/../docker-compose.dev.yml" ""; do # the plain file last: $cfg is checked below
    # shellcheck disable=SC2086 # $f is an optional extra "-f file"
    cfg=$(LIVEKIT_KEYS='APIci: lk-SENTINEL-0123456789abcdef0123456789abcdef' TURN_SHARED_SECRET=turn-SENTINEL-1 \
      TURN_URLS=turn:x TURN_EXTERNAL_IP=192.0.2.1 COMPOSE_PROFILES=ntfy,pgbouncer \
      docker compose -f "$HERE/../docker-compose.yml" $f config --format json)
    check "compose renders${f:+ with the dev file}" "$?" 0
    check "secrets reach no command line${f:+ (dev)}" "$(python3 -c 'import json,sys
for s in json.load(sys.stdin)["services"].values(): print(*(s.get("command") or []), *(s.get("entrypoint") or []))' <<<"$cfg" | grep -c SENTINEL)" 0
  done
  # deploy-deps:9 — every service: no raw sockets, no setuid privilege gain
  # (but coturn: its image needs a file capability to start as `nobody`).
  check "every service hardened" "$(python3 -c 'import json,sys
for n, s in json.load(sys.stdin)["services"].items():
  nnp = "no-new-privileges:true" in (s.get("security_opt") or [])
  if "NET_RAW" not in (s.get("cap_drop") or []) or nnp == (n == "coturn"): print(n)' <<<"$cfg")" ""
fi
# critic:12 — LiveKit spools a big unauthenticated multipart body to disk;
# Caddy caps the calls and push hosts before it reaches them.
for site in SINHRON_LIVEKIT_HOSTNAME SINHRON_NTFY_HOSTNAME; do
  check "Caddy caps request bodies on $site" \
    "$(awk -v s="{\$$site" 'index($0, s) == 1 { b = 1 } b && /^}/ { b = 0 } b' "$HERE/../Caddyfile" | grep -cE '^\s+max_size 1MB$')" 1
done

# ── Backups (security review 2026-11, deploy-deps:15) ───────────────────
# backup.sh / restore.sh copied next to a fake `docker` (logs its arguments,
# keeps what psql is fed) and a throwaway GnuPG home.
B=$WORK/bk
mkdir -p "$B/server/scripts" "$B/bin" "$B/dir" "$B/gnupg" && chmod 700 "$B/gnupg"
cp "$HERE/backup.sh" "$HERE/restore.sh" "$B/server/scripts/" && touch "$B/server/.env"
cat >"$B/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_LOG"
case "$*" in
  *pg_dump*) [ -z "${FAIL_PGDUMP:-}" ] || exit 1; echo 'CREATE TABLE real();' ;;
  *'tar czf -'*) tar czf - -T /dev/null ;;
  *' -c '*) ;;
  *psql*) cat >"$PSQL_IN" ;;
  *'config --format json'*) exit 1 ;;
esac
EOF
chmod +x "$B/bin/docker"
echo backup-pass >"$B/pass"
bk() { PATH=$B/bin:$PATH GNUPGHOME=$B/gnupg DOCKER_LOG=$B/docker.log PSQL_IN=$B/psql.in "$@"; }
enc() { bk gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-file "$B/pass" --symmetric -o "$2" "$1"; }
pair() { # pair <date> <sql> [plain|store]: a dump + an empty media archive
  # ${4-…}: the line pg_dump ends a whole dump with; pass '' for a cut dump.
  printf '%s\n' "$2" "${4--- PostgreSQL database dump complete}" | gzip >"$B/s.gz" && tar czf "$B/m.tgz" -T /dev/null
  case ${3:-} in
    plain) cp "$B/s.gz" "$B/dir/sinhron-$1.sql.gz" && cp "$B/m.tgz" "$B/dir/sinhron-media-$1.tgz" ;;
    store) bk gpg --batch --yes --quiet --store -o "$B/dir/sinhron-$1.sql.gz.gpg" "$B/s.gz"
      bk gpg --batch --yes --quiet --store -o "$B/dir/sinhron-media-$1.tgz.gpg" "$B/m.tgz" ;;
    *) enc "$B/s.gz" "$B/dir/sinhron-$1.sql.gz.gpg" && enc "$B/m.tgz" "$B/dir/sinhron-media-$1.tgz.gpg" ;;
  esac
}
restore() { rm -f "$B/psql.in" "$B/docker.log"; bk env SINHRON_BACKUP_PASSFILE="$B/pass" bash "$B/server/scripts/restore.sh" "$B/dir" "$@" --yes >/dev/null 2>&1; }

bk bash "$B/server/scripts/backup.sh" "$B/out" >/dev/null 2>&1
check "backup without a password file fails" "$?" 1
check "…and saves nothing in the clear" "$(find "$B/out" -type f | wc -l | tr -d ' ')" 0
bk env SINHRON_BACKUP_PASSFILE="$B/pass" bash "$B/server/scripts/backup.sh" "$B/out" >/dev/null 2>&1
check "backup with the password file" "$?" 0
check "only encrypted files" "$(find "$B/out" -type f ! -name '*.gpg' | wc -l | tr -d ' ')" 0
# Audit 2026-11b — a failed pg_dump was encrypted and renamed over the good
# dump of the same day (an empty "backup" that restore.sh would then take).
good=$(cksum "$B"/out/sinhron-2*.sql.gz.gpg)
bk env FAIL_PGDUMP=1 SINHRON_BACKUP_PASSFILE="$B/pass" bash "$B/server/scripts/backup.sh" "$B/out" >/dev/null 2>&1
check "a failed pg_dump fails the backup" "$?" 1
check "…and the good dump of the day stays as it was" "$(cksum "$B"/out/sinhron-2*.sql.gz.gpg)" "$good"
: >"$B/empty"
bk env SINHRON_BACKUP_PASSFILE="$B/empty" bash "$B/server/scripts/backup.sh" "$B/out2" >/dev/null 2>&1
check "an empty password file is refused" "$?" 1

pair 2026-11-01 'CREATE TABLE real();'
pair 2026-11-01 'CREATE TABLE planted();' plain
pair 9999-12-31 'CREATE TABLE planted();' plain
restore
check "restore takes the encrypted dump, not a planted plain one" "$(head -n 1 "$B/psql.in" 2>/dev/null)" 'CREATE TABLE real();'
pair 2026-11-02 'CREATE TABLE forged();' store
restore 2026-11-02
check "a gpg --store file (no password) is refused" "$?" 1
check "…before anything is stopped" "$( { [ -f "$B/docker.log" ] && grep -c stop "$B/docker.log"; } || echo 0)" 0
# Audit 2026-11b, D-B3 — a cut dump (valid gzip, no end line) was loaded
# after the database had been dropped, and restore reported "done".
pair 2026-11-04 'CREATE TABLE half(' '' ''
restore 2026-11-04
check "a dump without pg_dump's end line is refused" "$?" 1
check "…before anything is stopped or dropped" "$( { [ -f "$B/docker.log" ] && grep -c . "$B/docker.log"; } || echo 0)" 0
pair '2026-11-03;touch x;' 'CREATE TABLE forged();'
restore '2026-11-03;touch x;'
check "a date with shell in it is refused" "$?" 1

# ── APK upload (security review 2026-11, deploy-deps:18) ────────────────
# A broken upload must not leave a cut-off APK in the served /download/.
P=$WORK/pub
mkdir -p "$P/scripts" "$P/build/android-release"
cp "$HERE/../../client_flutter/scripts/publish_android.sh" "$P/scripts/"
printf '{"version": "0.0.1", "build": 1}\n' >"$P/build/android-release/android.json"
touch "$P/build/android-release/sinhron-0.0.1-1-arm64-v8a.apk"
up=$(bash "$P/scripts/publish_android.sh" --host x --dir /srv/s/download --dry-run 2>&1 | grep '^\[dry-run\] rsync')
check "upload keeps the broken part outside the served folder" "$(grep -c -- '--partial-dir=/srv/s/.download-partial ' <<<"$up")" 1
check "…and never with plain --partial" "$(grep -c -- '--partial ' <<<"$up")" 0

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
