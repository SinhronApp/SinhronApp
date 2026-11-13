# Sinhron · operator deploy guide

> Step-by-step руководство для соло-оператора: от голой VM до работающего self-hosted мессенджера.
> Аудитория: технически грамотный пользователь который хочет поднять Sinhron для себя/семьи/маленькой команды.
> Версия: v1.0 / 2026-05-23 · быстрая установка — 2026-10-14 (ADR-032)

---

## 0.5. Быстрая установка одной командой (рекомендуется)

`server/install.sh` делает всё, что описано ниже, сам: проверяет систему, обновляет пакеты, ставит Docker, включает firewall (SSH остаётся открытым), fail2ban, автообновления безопасности, swap при малой памяти, создаёт все пароли и ключи, собирает и запускает сервер, проверяет, что он отвечает снаружи, ставит ночные резервные копии и в конце показывает **адрес и QR-код** для приложения.

Нужно заранее: VPS с Ubuntu 22.04/24.04 и публичным IP, домен и три записи A (`домен`, `livekit.домен`, `turn.домен` → IP сервера; в Cloudflare — «DNS only»).

```bash
git clone https://github.com/SinhronApp/SinhronApp.git sinhron && cd sinhron
sudo bash server/install.sh
```

Скрипт предложит: **1** — ответить на вопросы сейчас (домен; остальное с разумными значениями), **2** — создать файл настроек `/etc/sinhron/sinhron.conf`, заполнить его и запустить снова. Ответы на вопросы сохраняются в тот же файл — результат одинаковый.

| Параметр | Что делает |
|---|---|
| `--interactive` | сразу вопросы |
| `--write-config` | только создать файл настроек |
| `--yes` | ничего не спрашивать (автоматизация, обновление) |
| `--commit <id>` | обновить код ровно до этого коммита (полный id, 40 знаков); без него код не обновляется (ADR-090) |
| `--dry-run` | показать, что будет сделано, ничего не меняя |
| `--skip-dns-check` / `--no-upgrade` | не ждать DNS / не обновлять систему |

Повторный запуск безопасен: сделанное пропускается, пароли и ключи (`server/.env`) сохраняются, код обновляется, образы пересобираются — так же делается **обновление** (`sudo bash server/install.sh --yes`). Журнал — `/var/log/sinhron-install.log`. Если у провайдера свой firewall (Hetzner Cloud Firewall, AWS Security Group) — откройте там те же порты, что в §1.1. **С 2026-11-04 (ADR-090, deploy-deps:5) код обновляется только с `--commit <id>`:** `sudo bash server/install.sh --yes --commit <полный id коммита>` — установщик забирает ветку из `origin` и переходит ровно на этот коммит; без `--commit` остаётся тот, что есть (пересобирается он же). Так никто, кто может писать в репозиторий, не запустит свой код от root при следующем обновлении (или в ночном cron копий). Id коммита владелец берёт у себя (`git rev-parse HEAD`) и передаёт отдельно; как сейчас — `git bundle` и переход на коммит руками, затем `--yes` — тоже работает.

Остальная часть руководства — то же самое вручную и подробности (обновление, резервные копии, PgBouncer).

---

## 0. Прежде чем начать

**Что вам нужно:**

| Ресурс | Минимум | Рекомендую | Стоимость |
|---|---|---|---|
| VM | 2 vCPU, 2 GB RAM, 20 GB SSD, Ubuntu 22.04+ | 4 vCPU, 8 GB RAM, 50 GB SSD | €5-30/мес Hetzner, $15-120/мес AWS/DO |
| Доменное имя | Любой `.com/.eu/.app` | Что вам нравится | $10-30/год |
| Apple Developer Account | (опционально, для push) | Нужен для production iOS | $99/год |
| Apple Push Notification Service key (.p8) | (опционально) | Нужен для production push | Free (включено в Developer) |

**Skill prerequisites:**
- Базовая Linux (ssh, ufw, systemd)
- Базовый Docker / docker-compose
- DNS records (A / AAAA / CNAME)

**Что ШЕЛКОМ предполагается:**
- У вас уже есть домен зарегистрирован
- Вы знаете как сделать `ssh user@vm.example.com`
- Базовая security hygiene (SSH key auth, fail2ban, sudo)

---

## 1. Provision VM

### 1.1. Hetzner (рекомендую для соло-оператора)

```bash
# Cloud → New Project → Add Server
# Location: closest to your users (для русскоязычных — Хельсинки/Falkenstein)
# Image: Ubuntu 22.04
# Type: CX31 (4 vCPU, 8 GB, €15/мес)
# SSH key: добавьте свой публичный ключ при создании
```

Дальше:
```bash
ssh root@your.vm.ip

# Минимальная hardening
apt update && apt upgrade -y
adduser sinhron
usermod -aG sudo sinhron
ufw allow 22/tcp            # SSH
ufw allow 80/tcp            # HTTP (Let's Encrypt HTTP-01 + redirect)
ufw allow 443/tcp           # HTTPS (API, LiveKit wss) + TURN over TLS
# Звонки (ADR-016):
ufw allow 3478              # coturn STUN/TURN, tcp+udp
ufw allow 49152:49999/udp   # coturn relay range (turnserver.conf min/max-port)
ufw allow 7881/tcp          # LiveKit ICE/TCP fallback
ufw allow 7882/udp          # LiveKit media (single UDP port)
ufw enable
# NB: порты, опубликованные Docker'ом (80/443/7881/7882), обходят ufw —
# Docker пишет свои iptables-правила. coturn на host network ufw видит.
# Если у провайдера есть внешний firewall (security group) — откройте
# там тот же список.

# Disable root SSH (после копирования ключа на sinhron user)
# Edit /etc/ssh/sshd_config: PermitRootLogin no, PasswordAuthentication no
systemctl reload ssh

# Установить Docker + compose
curl -fsSL https://get.docker.com | sh
usermod -aG docker sinhron
exit
ssh sinhron@your.vm.ip
docker --version  # должен показать 25.x+
docker compose version  # 2.x+
```

### 1.2. DNS

В кабинете DNS-провайдера (Cloudflare / Namecheap / etc.):

```
A  sinhron.example.com          →  <your-vm-ip>   # API + WS   (SINHRON_PUBLIC_HOSTNAME)
A  livekit.sinhron.example.com  →  <your-vm-ip>   # звонки     (SINHRON_LIVEKIT_HOSTNAME)
A  turn.sinhron.example.com     →  <your-vm-ip>   # TURN/TLS   (SINHRON_TURN_HOSTNAME)
```

Подождите ~5 минут пока TTL отстоится. Проверьте каждое имя: `dig turn.sinhron.example.com +short`.

**Публичный IP.** Запишите его — это `TURN_EXTERNAL_IP`. Если IP не висит на интерфейсе VM (`ip -4 addr` его не показывает: 1:1 NAT у Yandex Cloud, AWS EIP и т.п.), значение — `<публичный>/<приватный>`. Лучше всего — VPS с публичным IP прямо на интерфейсе: тогда relay coturn → LiveKit на тот же хост гарантированно работает (hairpin через NAT провайдера — не везде).

---

## 2. Подготовить project files

```bash
mkdir -p ~/sinhron && cd ~/sinhron
git clone https://github.com/yourorg/sinhron.git .
# или scp с локальной dev машины:
# (с локальной): rsync -av --exclude target --exclude .git \
#   ./server/ sinhron@vm:~/sinhron/server/
```

Файлы которые нам нужны:
- `server/Dockerfile`
- `server/docker-compose.yml`
- `server/Caddyfile` + `server/Dockerfile.caddy`
- `server/Caddyfile` и `server/livekit.yaml` смонтированы в контейнеры как отдельные файлы: `git reset` заменяет файл, а контейнер продолжает видеть старый — после обновления `docker compose up -d --force-recreate caddy` (или `livekit`); проверка — `md5sum server/Caddyfile` = `docker exec sinhron-caddy md5sum /etc/caddy/Caddyfile`. Новый Caddyfile до установки проверять: `docker cp server/Caddyfile sinhron-caddy:/tmp/C && docker exec sinhron-caddy caddy validate --config /tmp/C --adapter caddyfile`.
- `server/livekit.yaml`, `server/turnserver.conf` (`livekit.yaml` с ADR-041: `allow_pause` и список кодеков opus/red/vp8/h264/rtx — после обновления файла перезапустить `livekit`: `docker compose -f docker-compose.yml up -d --force-recreate --no-deps livekit`)
- `server/.env.example` (шаблон для `.env`)
- `server/migrations/*.sql`

---

## 3. Конфигурация секретов

```bash
cd ~/sinhron/server
cp .env.example .env  # если нет, создайте вручную ниже
chmod 600 .env
nano .env
```

**Содержание `.env`:**

```ini
# ── Postgres (внутри docker network, не открыто наружу) ──
POSTGRES_USER=sinhron
POSTGRES_PASSWORD=GENERATE_A_RANDOM_64_CHAR_STRING_HERE
POSTGRES_DB=sinhron

# Server reads from this string
SINHRON_DB_URL=postgres://sinhron:GENERATE_A_RANDOM_64_CHAR_STRING_HERE@postgres:5432/sinhron
# deploy-deps:8 (ADR-087) — со своим docker-compose.yml так: сервер входит
# своей ролью, не суперпользователем (установщик пишет сам; новая установка —
# sinhron_app, существующая — sinhron, пока не переключите, §9.1).
# SINHRON_DB_APP_USER=sinhron_app
# SINHRON_DB_APP_PASSWORD=<openssl rand -hex 32>
# SINHRON_DB_MIGRATE_URL=…   # только если запросы идут через пулер; compose задаёт сам (§10.1)
# Пароль базы; адрес базы для сервера (SINHRON_DB_URL) compose собирает сам из него.
# POSTGRES_PASSWORD / SINHRON_DB_URL здесь compose НЕ читает (раньше гайд их называл —
# и база молча получала пароль `dev_only`). Задаётся только для новой базы: у уже
# созданной сменить — `ALTER ROLE sinhron PASSWORD '…'` в psql, потом здесь.
SINHRON_DB_PASSWORD=GENERATE_RANDOM_HEX_64_HERE  # openssl rand -hex 32

# ── Server binding ──
SINHRON_LISTEN=0.0.0.0:8080

# ── PgPool tuning (T1.5 Risk #9) ──
SINHRON_PG_MAX_CONNS=32          # 16-32 для small group, 64+ для производства
SINHRON_PG_ACQUIRE_TIMEOUT_SECS=5

# ── Rate limits (T1.5) ──
# Format: N/W — N запросов за W секунд
SINHRON_RATE_REGISTER=10/3600    # 10 регистраций в час с одной identity
SINHRON_RATE_KP_UPLOAD=200/3600  # 200 KeyPackage upload'ов в час
SINHRON_RATE_SUBMIT=600/60       # 600 сообщений в минуту
SINHRON_RATE_REQUESTS=60/60      # ADR-071: «запросы» (без ключа доступа) от одного одному
SINHRON_RATE_REQUEST_PUSH=10/3600      # ADR-071: push о запросах одному человеку в час
SINHRON_RATE_REQUEST_PUSH_PAIR=1/600   # ADR-071: …и от одного отправителя — раз в 10 минут
# SINHRON_RATE_KP_CONSUME_CALLER=240/3600 # ADR-087: KeyPackage, которые берёт один аккаунт, в час

# ── Retention (spec §7.6 / WU A9) ──
SINHRON_MESSAGE_RETENTION_DAYS=365   # сообщения и приглашения в чат ждут телефон до года (запись 220; было 14)
SINHRON_RETENTION_SWEEP_SECS=3600    # sweep раз в час

# ── Logging ──
RUST_LOG=info,sinhron_server=info,sqlx=warn

# ── Push для Android — свой ntfy (ADR-040) ──
# Включён по умолчанию (ENABLE_NTFY=yes). Имя установщик находит сам, если
# NTFY_DOMAIN пусто: push.<домен> или push.<домен уровнем выше> — то, что в
# DNS указывает на этот сервер (так на любом новом сервере). Нет такой записи —
# push пока выключен, установка не останавливается; появится запись — запустить
# установщик снова. Он включит профиль `ntfy`, Caddy-сайт и
# SINHRON_UNIFIEDPUSH_HOSTS. На телефоне — приложение ntfy, в нём этот сервер:
# Sinhron сам показывает адрес (GET /v1/push/info) в «Настройки» → «Уведомления».
# SINHRON_UNIFIEDPUSH_HOSTS=push.chat.example.com
# ADR-087 — публиковать в свой ntfy может только сервер, этим токеном
# (установщик делает один раз: tk_ и 29 букв/цифр). Без него push на Android
# не уходят. Токен получает только первый хост из списка выше.
# SINHRON_NTFY_TOKEN=tk_0123456789abcdef0123456789abc

# ── (Опционально) Администратор сервера (ADR-077) ──
# Ваш адрес в Sinhron (профиль → «Скопировать адрес», 64 знака), можно
# несколько через запятую. Через установщик — ADMIN_KEYS в /etc/sinhron/sinhron.conf
# (он сам пишет эту строку; убрали там — уходит и отсюда). Сервер пишет в
# приложение, в строку «Сервер» вверху «Чатов»: тревоги о нагрузке (процессор
# ≥ 90 % три минуты, память ≥ 90 % две, соединений ≥ 2000; сразу, одна и та же —
# не чаще раза в 30 мин, и «снова в норме») и каждую жалобу (кто, на кого, оба IP).
# IP к жалобам хранятся 30 дней, уведомления — 30 дней. Пусто — администратора
# нет, сервер не хранит IP. После изменения — перезапуск sinhron-server
# (установщик делает сам).
# SINHRON_ADMIN_IDENTITIES=<64 hex>[,<64 hex>]

# ── (Опционально) Ссылки-приглашения (ADR-043) ──
# https://<домен>/join#… — страница для телефона без приложения и файлы,
# по которым iPhone / Android открывают такие ссылки сразу в Sinhron.
# Кнопки «Установить» на странице (только https; пусто — «попросите
# пригласившего прислать ссылку»):
# SINHRON_IOS_INSTALL_URL=https://testflight.apple.com/join/XXXXXXXX
# SINHRON_ANDROID_INSTALL_URL=https://example.com/sinhron.apk
# Своя сборка приложения (иначе — официальные идентификаторы):
# SINHRON_APPLE_APP_ID=TEAMID.bundle.id
# SINHRON_ANDROID_PACKAGE=com.example.app  SINHRON_ANDROID_CERT_SHA256=AA:BB:…
# Своя сборка с другим доменом: домен — в Runner.entitlements
# (applinks:<домен>) и в манифесте Android (intent-filter /join и /i/).
# Короткие ссылки https://<домен>/i/<id>#<ключ> (2026-11-03): Caddy отдаёт
# /i/* серверу, как /join (тот же CSP); зашифрованные приглашения — в
# таблице short_invites (миграция 20261103120000, сервер применит сам при
# запуске), год. После обновления Caddyfile — пересоздать caddy.

# ── (Опционально) Push-уведомления APNs (ADR-038) ──
# Ключ .p8: /etc/sinhron/apns/AuthKey.p8 на хосте — владелец uid 10001
# (пользователь контейнера), права 400; compose монтирует каталог только
# для чтения. Песочница / production выбирается по каждому токену сама.
# APNS_KEY_PATH=/etc/sinhron/apns/AuthKey.p8
# APNS_KEY_ID=XYZ123
# APNS_TEAM_ID=ABCDEFG123
# APNS_TOPIC=com.sinhron.sinhron

# ── (Опционально) Push Google для Android (FCM, ADR-057) ──
# Два файла из своего проекта Firebase (шаги — docs/open-items.md):
#   /etc/sinhron/fcm/service-account.json  — закрытый ключ (uid 10001, права 400)
#   /etc/sinhron/fcm/google-services.json  — id Android-приложения com.sinhron.sinhron
# Оба на месте → включено (в журнале «FCM (Google push for Android) enabled»);
# нет → выключено. .env трогать не нужно; другие пути — так:
# SINHRON_FCM_SERVICE_ACCOUNT=/etc/sinhron/fcm/service-account.json
# SINHRON_FCM_CLIENT_CONFIG=/etc/sinhron/fcm/google-services.json
# ── (Опционально) Стикерпаки из Telegram по ссылке (ADR-062) ──
# Токен бота от @BotFather — файл на хосте, не в .env и не в git:
#   install -d -m 700 -o 10001 /etc/sinhron/telegram
#   printf %s '<токен>' > /etc/sinhron/telegram/bot-token
#   chown 10001 /etc/sinhron/telegram/bot-token && chmod 400 /etc/sinhron/telegram/bot-token
#   docker compose up -d sinhron-server
# Нет файла — функция выключена (приложение: «Сервер не настроен…»).
# В журнале при старте: "telegram sticker packs configured=true".
# Из России api.telegram.org по IPv4 не отвечает (2026-10-18), по IPv6 —
# да: sinhron-server подключён к сети egress6. Если не доходит никак —
# другой адрес Bot API (свой telegram-bot-api за границей):
# SINHRON_TELEGRAM_API_URL=https://bot-api.example.org
# SINHRON_RATE_TG_PACKS=30/3600   SINHRON_RATE_TG_FILES=3000/3600  # на аккаунт

# ── (Опционально, TLS pinning operator CA) ──
# Если делаете deployment with pinned CA, генерируйте CA + бандлите его
# в Flutter client как `SINHRON_PINNED_CA_PEM` через --dart-define.
# Server-side ничего настраивать не надо.

# ── Calls infrastructure (spec §10, ADR-015/016) ──
SINHRON_PUBLIC_HOSTNAME=sinhron.example.com
SINHRON_LIVEKIT_HOSTNAME=livekit.sinhron.example.com
SINHRON_TURN_HOSTNAME=turn.sinhron.example.com
# LiveKit auth keys: "<key>: <secret>" — echo "$(openssl rand -hex 16): $(openssl rand -base64 32)"
LIVEKIT_KEYS=GENERATE_KEY: GENERATE_RANDOM_BASE64_SECRET_HERE
# LIVEKIT_URL не задаём — compose сам отдаёт клиентам wss://${SINHRON_LIVEKIT_HOSTNAME}
TURN_SHARED_SECRET=GENERATE_RANDOM_HEX_64_HERE  # openssl rand -hex 32
TURN_REALM=sinhron
TURN_EXTERNAL_IP=<your-vm-ip>                   # или <public>/<private> за 1:1 NAT
# Порядок = порядок попыток ICE: UDP, TCP, затем TLS:443 для сетей «только HTTPS»
TURN_URLS=turn:sinhron.example.com:3478?transport=udp,turn:sinhron.example.com:3478?transport=tcp,turns:turn.sinhron.example.com:443?transport=tcp
# TURN_TTL_SECS=86400                           # 24h; ограничивает максимальную длину звонка
```

> **Заглушки не пройдут (запись 233, `docs/security-review-2026-11.md`, `deploy-deps:6`).** Сервер с LiveKit на `wss://` (не `*.localhost`) не стартует, если в `LIVEKIT_KEYS`, `TURN_SHARED_SECRET` или пароле базы осталось значение из репозитория (`devsecret…`, `devturnsecret…`, `GENERATE_…`, `dev_only`, `change-me…`): с ним любой зашёл бы в админку LiveKit, выписал бы себе TURN или вошёл в базу. В журнале — какая переменная; `install.sh` такие значения сам заменяет случайными. Секреты LiveKit и TURN не видны в `ps`: LiveKit берёт их из окружения, coturn — из своей копии `turnserver.conf` внутри контейнера (`deploy-deps:7`). После обновления: `docker compose -f docker-compose.yml up -d --force-recreate livekit coturn caddy` и один раз сменить оба секрета (их мог видеть любой пользователь сервера).

> С 2026-10-13 `docker-compose.yml` передаёт серверу и `SINHRON_PG_*`, `SINHRON_RATE_*`, `SINHRON_RETENTION_SWEEP_SECS`, `SINHRON_WS_IDLE_TIMEOUT_SECS` (таймаут тишины WS, по умолчанию 45 с с 2026-10-16 — было 75; минимум 15; клиенты шлют heartbeat раз в 20 с; с 2026-10-18 Android в фоне просит до 300 с на свою сессию — сервер держит её промежуток + половину, а в `Caddyfile` у `/v1/sync` `read_timeout 10m`) (tech-debt 2.17 закрыт). Не заданная переменная приходит пустой строкой — сервер считает её незаданной и берёт значение по умолчанию.

Сгенерировать random password:
```bash
openssl rand -hex 32
```

---

## 4. Caddy (TLS + маршрутизация 443)

Используется **`server/Caddyfile` из репозитория** — копировать сюда его не нужно, он единственный источник правды. Образ собирается из `server/Dockerfile.caddy` (Caddy 2.11.7 + модуль `caddy-l4` v0.1.2): в стандартном образе нет layer4.

Как он устроен (ADR-016):
- **TCP 443 принимает layer4-роутер** и делит соединения по SNI:
  - `SINHRON_TURN_HOSTNAME` → Caddy снимает TLS и отдаёт чистый TURN-over-TCP в coturn (`host.docker.internal:3478`). Это `turns:…:443` — звонки проходят в сетях, где открыт только HTTPS.
  - всё остальное → TLS passthrough + PROXY protocol v2 в HTTP-часть Caddy на `127.0.0.1:8443`, она обслуживает API и LiveKit. PROXY protocol нужен, чтобы сервер видел реальный IP клиента (лимиты по IP).
- `SINHRON_PUBLIC_HOSTNAME` → `/v1/*`, `/_healthz`, `/_readyz` в `sinhron-server:8080`, остальное 404. Это же имя получает сам сервер (ADR-086): приложения подписывают имя из своего адреса сервера, и сервер принимает только подписи со своим именем — оно должно совпадать с тем, что вписано в приложениях. При запуске сервер пишет в журнал `signatures are taken for these server names`.
- `SINHRON_LIVEKIT_HOSTNAME` → `livekit:7880` (wss-сигналинг звонков).
- Порт 80 → редирект на https + ACME HTTP-01 для всех трёх имён.
- HTTP/3 выключен (UDP 443 не маршрутизируется).
- **Заголовки безопасности** (сниппет `security_headers`, tech-debt 2.14) на API и LiveKit: HSTS на 2 года с поддоменами (**без `preload`** — это необратимая заявка в списки браузеров, оператор решает сам), CSP `default-src 'none'; frame-ancestors 'none'` (API не отдаёт HTML; ставится как значение по умолчанию — `?Content-Security-Policy`, — потому что страница `/join` (ADR-043) задаёт свой CSP с хешем единственного скрипта; обычная установка шла позже и затирала его), `nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, запрет камеры/микрофона/геолокации, заголовок `Server` убран. Проверка после запуска: `curl -sI https://<SINHRON_PUBLIC_HOSTNAME>/_healthz`.

**Скачивание приложения для Android** (2026-10-18). Файлы из `server/download/` (не в git) отдаются по `https://<SINHRON_PUBLIC_HOSTNAME>/download/<файл>` (Caddy, `handle_path /download/*`, папка смонтирована только для чтения; у `.apk` — `Content-Type: application/vnd.android.package-archive`). Положить `sinhron.apk` и указать в `.env` `SINHRON_ANDROID_INSTALL_URL=https://<host>/download/sinhron.apk` — страница `/join` покажет кнопку «Установить для Android». Для людей без Google Play и без доступа к закрытому репозиторию.

**Политика конфиденциальности** (2026-10-23, status 195). `server/download/privacy.html` (в git, исключение в `.gitignore`) отдаётся как `https://<host>/download/privacy.html` — эту ссылку требует экран согласия Google (копия на Google Диске). После правки: `rsync server/download/privacy.html root@<сервер>:/opt/sinhron/server/download/`, перезапуск не нужен.

**Google Диск для копии на Android** (ADR-073, status 195). Проект Firebase/Google Cloud сервера: Google Drive API включён; Google Auth Platform — External, **In production**, домашняя страница `/join`, политика выше, разрешённый домен; OAuth-клиент типа Android с пакетом приложения и SHA-1 ключа подписи релиза (`keytool -list -v -keystore android-release.jks`). Своя сборка с другим ключом — свой клиент с её SHA-1.

**Обновления Android-приложения** (ADR-058, 2026-10-18). Установленное из нашего APK приложение раз в 6 часов (и по «Настройки → О приложении → Проверить обновления») смотрит `https://<host>/download/android.json`; если там сборка новее — предлагает обновиться (скачивание, проверка SHA-256 и нашей подписи, системный установщик). Выкладка новой версии без Мака (2026-11-13): GitHub → Actions → **Release** → Run workflow (`.github/workflows/release.yml`: те же скрипты, ключ подписи — из секретов репозитория; APK и `android.json` — в выпуск на GitHub), затем на сервере `bash /opt/sinhron/server/scripts/fetch_android.sh <tag>` (скачивает, сверяет SHA-256, раскладывает так же, `android.json` последним). Там же — сборка iPhone в TestFlight (`testflight.sh` с ключом App Store Connect API). С Мака — как раньше, двумя командами:
```bash
cd client_flutter && bash scripts/android_release.sh          # RELEASE_NOTES="…" — текст в карточке (необязательно)
bash scripts/publish_android.sh --host root@<сервер>            # --dry-run — только показать команды
```
`android_release.sh` кладёт в `build/android-release/` файлы `sinhron-<версия>-<сборка>-<abi>.apk` и `android.json` (манифест не пишется, если подпись не наша). `publish_android.sh` по ssh заливает их в `/opt/sinhron/server/download/` (`--dir` — другая папка): APK → постоянные имена `sinhron.apk` / `sinhron-32bit.apk` (для `/join`) → `android.json` последним → удаляет сборки старше трёх последних. Caddy отдаёт `android.json` с `Cache-Control: no-cache` — после правки Caddyfile: `docker compose up -d --force-recreate caddy`. Без `android.json` приложение просто не предлагает обновлений.

**Сертификаты, если Let's Encrypt недоступен** (так было 2026-10-18 на российском VPS: адрес Let's Encrypt в Cloudflare по IPv4 не отвечал, по IPv6 — отвечал). Caddy подключён ко второй сети `egress6` с IPv6 (`docker-compose.yml`) — выходит к Let's Encrypt по IPv6, если у сервера он есть; без IPv6 у сервера ничего не меняется. Учётная запись сертификатов — `ACME_EMAIL` (по умолчанию `certs@<SINHRON_PUBLIC_HOSTNAME>`; свой адрес — в `.env`, чтобы письма об истечении шли вам): с ней Caddy пробует ещё и ZeroSSL. Из России ZeroSSL отказал (его API отдаёт 403), так что на IPv6 вся надежда. Проверка: `docker logs sinhron-caddy 2>&1 | grep -E "certificate obtained|could not get certificate"`.

### 4.1. Другие сайты на этом сервере (status 203)

Порты 80/443 у сервера одни, и держит их `sinhron-caddy`. Если на том же сервере работает ещё один проект (например, другой сайт — свой `docker compose`-проект, без опубликованных портов), Caddy Sinhron может обслуживать и его домен, ничего не меняя для Sinhron:

- В конце `server/Caddyfile` — `import /etc/caddy/sites/*.caddy`. Папка на хосте — **`/etc/sinhron/caddy-sites`** (смонтирована в Caddy только для чтения; `install.sh` создаёт её с правами 0755). Пустая папка — норма: Caddy пишет предупреждение «No files matching import glob pattern» и работает как раньше.
- Caddy подключён к общей Docker-сети **`edge`** (`external: true`). Её создаёт `install.sh` до `compose up` (`docker network inspect edge || docker network create edge`). Без неё `compose up` для caddy падает с «network edge declared as external, but could not be found» — при ручном запуске создайте её сами той же командой. Сети `default` и `egress6` (выход по IPv6 к Let's Encrypt) остаются как были.
- Соседние домены обслуживает та же HTTP-часть Caddy на `:8443`: layer4 на `:443` всё, кроме имени TURN, отдаёт туда. Сертификаты — как у наших имён: HTTP-01 на `:80` (блок `http://` с редиректом проверке не мешает — Caddy отвечает на ACME-запросы раньше маршрутов), с запасным ZeroSSL.

**Что делает сосед:**
1. Подключает свой веб-контейнер к сети `edge` (в его compose: `networks: edge: {external: true, name: edge}` и у сервиса `networks: [default, edge]`). Порты наружу не публикует.
2. Кладёт файл `/etc/sinhron/caddy-sites/<имя>.caddy` — обычный блок сайта, **без порта** (`:443` занят layer4) и без своего `http://`-блока:
   ```caddy
   notes.example.com {
   	reverse_proxy datascratch-web:3000
   }
   ```
   DNS-записи A/AAAA домена — на этот сервер.
3. Проверяет и применяет **без перезапуска** (текущие звонки не рвутся):
   ```bash
   docker exec sinhron-caddy caddy validate --config /etc/caddy/Caddyfile
   docker exec sinhron-caddy caddy reload --config /etc/caddy/Caddyfile
   ```
   Ошибочный файл `reload` отвергает — продолжает работать старая конфигурация. **Но** с ошибочным файлом Caddy не запустится при следующем перезапуске контейнера или сервера — и Sinhron тоже будет недоступен. Поэтому `validate` — всегда, до `reload`; занять имя Sinhron (тот же домен) тоже ошибка.
4. Убрать сайт — удалить файл и снова `reload`.

**Заголовки безопасности — дело соседа.** Сниппет `(security_headers)` Sinhron соседние сайты **не** получают и импортировать его не должны: его CSP `default-src 'none'` сломает любое веб-приложение. Свои HSTS/CSP сосед пишет в своём блоке (`header { … }`) или отдаёт из приложения.

**После обновления Sinhron, меняющего `docker-compose.yml` для caddy** (как это — монтирование и сеть `edge`), контейнер надо пересоздать: `sudo bash server/install.sh --yes` делает это сам (`compose up -d`); вручную — `docker compose -f docker-compose.yml up -d --force-recreate caddy`. Это короткий перезапуск Caddy: идущие звонки через 443 и WebSocket переподключаются. Правка только соседних файлов перезапуска не требует (`reload`).

Проверка в CI (`docker-image`): `server/scripts/caddy_sites_check.sh` — `caddy validate` в собранном образе с пустой папкой, с примером сайта и с ошибочным файлом (должен отвергнуться); затем Caddy из настоящего compose (`egress6` + `edge`) отвечает и на `/_healthz` Sinhron, и на тестовый соседний сайт после `reload`.

---

## 5. docker-compose

Используется **`server/docker-compose.yml` из репозитория**. Важно:

- **Production запускать только с `-f docker-compose.yml`** (и перезапуск отдельного сервиса тоже: `docker compose -f docker-compose.yml up -d --force-recreate --no-deps <сервис>`). Файл для локальной разработки теперь называется `docker-compose.dev.yml` и сам **не подхватывается** (раньше — `docker-compose.override.yml`, Docker брал его автоматически: 2026-10-19 перезапуск без `-f` выдал телефонам LiveKit на `ws://localhost:7880`, все звонки сбрасывались на 0 с — status 167). Для разработки: `docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d`.
- Postgres опубликован только на `127.0.0.1:5433` — наружу не виден.
- `coturn` — `network_mode: host` (relay-порты 49152–49999/udp прямо на хосте), `--external-ip=${TURN_EXTERNAL_IP}`. Без `TURN_EXTERNAL_IP` compose откажется стартовать.
- `livekit` — сигналинг 7880 наружу не публикуется (только через Caddy), медиа: `7881/tcp` + `7882/udp`.
- `caddy` — в сетях `default`, `egress6` (IPv6-выход) и внешней `edge` (соседние сайты, §4.1); монтирует `/etc/sinhron/caddy-sites`.
- `sinhron-server` получает `LIVEKIT_KEYS`, `LIVEKIT_URL=wss://${SINHRON_LIVEKIT_HOSTNAME}`, `TURN_SHARED_SECRET`, `TURN_URLS`, `TURN_TTL_SECS` — без них `/v1/call/*` отвечают 503.

---

## 6. Запуск

```bash
cd ~/sinhron/server
alias dc='docker compose -f docker-compose.yml'   # production: только базовый файл

dc pull postgres livekit coturn
dc build sinhron-server caddy   # ~3-5 минут первый раз (Rust build + xcaddy)
dc up -d

dc ps
# 5 контейнеров: postgres, sinhron-server, caddy, livekit, coturn
# postgres, sinhron-server, livekit — (healthy) через ~10–60 с; у caddy healthcheck нет.
# sinhron-server проверяет себя сам: `/app/sinhron-server --healthcheck` (GET /_healthz,
# выход 0/1) — в образе нет wget/curl. Почему unhealthy:
#   docker inspect -f '{{json .State.Health}}' sinhron-server

curl https://sinhron.example.com/_healthz          # → 200
curl https://sinhron.example.com/_readyz           # → 200 (503 если postgres недоступен)
curl https://livekit.sinhron.example.com/          # → 200 "OK" (LiveKit через Caddy)
```

---

## 6.5. Звонки: проверка NAT traversal

### TURN over TLS на 443
```bash
# TLS-рукопожатие с сертификатом turn-имени (Caddy layer4 → coturn):
openssl s_client -connect turn.sinhron.example.com:443 -servername turn.sinhron.example.com </dev/null 2>/dev/null | openssl x509 -noout -subject
# → subject=CN=turn.sinhron.example.com
```

### TURN allocation (UDP / TCP)
```bash
# Временные креды по той же схеме, что /v1/call/turn (expiry:nonce + HMAC-SHA1):
U="$(( $(date +%s) + 600 )):check"
P=$(printf '%s' "$U" | openssl dgst -sha1 -hmac "$TURN_SHARED_SECRET" -binary | base64)
docker exec sinhron-coturn turnutils_uclient -u "$U" -w "$P" -y <your-vm-ip>       # UDP
docker exec sinhron-coturn turnutils_uclient -t -u "$U" -w "$P" -y <your-vm-ip>    # TCP
# → без ошибок allocation
```
Для проверки снаружи — официальный Trickle ICE из WebRTC samples (https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/): ввести `turns:turn.sinhron.example.com:443?transport=tcp` + креды выше — должен появиться `relay`-кандидат.

### Приёмка (обязательно перед «продакшеном»)
Реальный звонок между двумя физическими устройствами в **разных** сетях: iPhone на мобильной сети ↔ Mac/iPhone на Wi-Fi; затем один из них в сети, где закрыто всё, кроме 443 (корпоративный Wi-Fi или правило firewall). Сценарии — `docs/evidence/calls-manual-test-plan.md` §1.11.

### coturn — caveats
- `network_mode: host` на Linux — штатный режим. На Mac (Docker Desktop) нет настоящего host networking — dev-override возвращает bridge с диапазоном 49152–49200; кросс-сетевой TURN проверяется только на Linux-хосте.
- Логин TURN — `<expiry>:<случайный nonce>`, без identity: логи coturn не раскрывают, кто звонит.
- Креды живут `TURN_TTL_SECS` (по умолчанию 24h) — coturn перепроверяет их на каждом refresh allocation, так что TTL = потолок длины звонка.

### Apple Developer Program — не требуется для этой инфраструктуры

LiveKit + coturn работают без Apple Dev account. Apple cert требуется ТОЛЬКО для **PushKit VoIP push** (= incoming call на lock-screen). Без него calls работают только когда iPhone foreground. Документировано в `plan-calls.md` §11 (Phasing notes).

---

## 7. Логи + мониторинг

```bash
# Live tail server logs
docker compose -f docker-compose.yml logs -f sinhron-server

# Postgres logs (rare, useful for slow query debugging)
docker compose -f docker-compose.yml logs -f postgres

# Caddy access log
docker compose -f docker-compose.yml logs -f caddy
```

**Что искать в логах:**
- `ws session authenticated` — успешные WS connect
- `message persisted` — успешные Submit
- `fanout delivered=N` — broadcast'ы
- `retention sweep removed rows` — periodic cleanup
- `rate-limited registration` — кто-то спамит /v1/identity (расследуйте если часто)
- `push notify failed` — APNs / FCM не доставился
- `ws idle watchdog fired` — клиент disconnect'нулся без bye

**Метрики:** отдельного эндпоинта нет (убран 2026-10-26); тревоги о нагрузке — чат «Сервер» (ADR-077).

---

## 8. Backup + restore runbook

### 8.1. Backup

```bash
# Daily Postgres dump (cron)
crontab -e
# add:
# 0 3 * * * cd ~/sinhron/server && docker compose -f docker-compose.yml exec -T postgres pg_dump -U sinhron sinhron | gzip > ~/backups/sinhron-$(date +\%F).sql.gz

# Media blobs (ciphertext, ADR-017) — named volume sinhron_media. Тот же
# день, что и pg_dump: строки media ссылаются на эти файлы.
# 15 3 * * * docker run --rm -v server_sinhron_media:/m:ro -v ~/backups:/b alpine tar czf /b/sinhron-media-$(date +\%F).tgz -C /m .

# Backup the .env (encrypted!)
gpg --symmetric --cipher-algo AES256 .env
# → .env.gpg — копируйте в безопасное место (другой VPS, encrypted USB)
```

**Одним скриптом (всё три сразу):** `server/scripts/backup.sh` — дамп, медиа и `.env`, **все три** зашифрованы GPG паролем из файла (`sinhron-<дата>.sql.gz.gpg`, `sinhron-media-<дата>.tgz.gpg`, `env-<дата>.gpg`; без файла пароля скрипт ничего не сохраняет и завершается с ошибкой — раньше дамп и медиа ложились открытыми (записи 222, 233)), хранит 14 дней:

```bash
echo 'длинный-случайный-пароль' > ~/.sinhron-backup-pass && chmod 600 ~/.sinhron-backup-pass
# crontab -e:
# 0 3 * * * cd ~/sinhron/server && SINHRON_BACKUP_PASSFILE=~/.sinhron-backup-pass scripts/backup.sh ~/backups >> ~/backups/backup.log 2>&1
```

Папку `~/backups` копируйте за пределы VM (rsync / rclone): на самой VM резервная копия от потери диска не спасает.

### 8.2. Restore

**Одним скриптом:** `SINHRON_BACKUP_PASSFILE=/etc/sinhron/backup-pass server/scripts/restore.sh <папка> [дата] [--yes]` — берёт **только зашифрованные** `sinhron-<дата>.sql.gz.gpg` и `sinhron-media-<дата>.tgz.gpg` из папки `backup.sh` (без даты — самые новые; дата только `ГГГГ-ММ-ДД`), каждый файл должен открываться паролем копий — файл без шифрования (`gpg --store`) или подложенный открытый дамп рядом не принимаются (запись 233, `deploy-deps:15`). Старый открытый дамп (до 2026-11-02) — только руками: `gunzip -c <дамп> | docker compose exec -T postgres psql -U sinhron -d sinhron` после `DROP SCHEMA public CASCADE; CREATE SCHEMA public;`. Дальше скрипт останавливает `sinhron-server`, заменяет базу и файлы медиа (владельцы файлов сохраняются), запускает сервер (миграции новее копии применятся сами). `.env` сначала вернуть самому (`gpg -d env-<дата>.gpg` паролем копий; `install.sh` существующий `.env` не трогает, только `TURN_EXTERNAL_IP` пересчитывает под новый IP).

**Переезд на другой сервер (так сделано 2026-10-16, DigitalOcean → российский провайдер):**
1. На новом: `/etc/sinhron/{sinhron.conf,backup-pass,apns/AuthKey.p8}` (apns — владелец uid 10001, `dr-x------`) и `server/.env` со старого; `install.sh --yes --skip-dns-check`.
2. Пробное восстановление из любой свежей копии, сверка числа строк.
3. На старом `docker compose stop sinhron-server` (больше никто не пишет), `backup.sh` в новую папку → на новый → `restore.sh … --yes`; сверка числа строк во всех таблицах.
4. DNS: A-записи `chat`, `livekit.chat`, `turn.chat` → новый IP. Пока у телефонов старая запись (TTL), они получают ошибку и повторяют — сообщения ждут в очереди отправки. Caddy на новом выпускает сертификаты сам, как только DNS указывает на него.
5. Старый удалять после проверки сообщений, звонков и push на новом.

Вручную (то же самое):

```bash
# 1. Скопировать новейший .sql.gz dump на новую VM
scp backups/sinhron-2026-05-22.sql.gz sinhron@newvm:~/restore.sql.gz

# 2. На новой VM, запустить compose БЕЗ migrations
docker compose -f docker-compose.yml up -d postgres
docker compose -f docker-compose.yml exec postgres psql -U sinhron -d sinhron -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'
gunzip -c restore.sql.gz | docker compose -f docker-compose.yml exec -T postgres psql -U sinhron sinhron

# 3. Start sinhron-server (он применит migrations поверх восстановленной схемы — idempotent)
docker compose -f docker-compose.yml up -d sinhron-server
```

### 8.3. Что покрывает backup

- ✅ Identities, devices, keypackages, groups, group_members
- ✅ Messages (encrypted ciphertext only)
- ✅ State_backups (per-user encrypted blob)
- ✅ Media — метаданные в Postgres + файлы в томе `sinhron_media` (оба нужны; файлы без строк удалятся не будут, строки без файлов → 404)
- ❌ In-memory session registry (теряется на restart — клиенты переподключатся)
- ❌ pending_welcomes (теряются если не дренировались — recipient получит invite re-issued)

---

## 9. Обновление

Обычно — установщиком: `sudo bash server/install.sh --yes --commit <id>` (ADR-090). Вручную:

```bash
cd ~/sinhron/server
git fetch origin main && git checkout --detach <id>   # ровно названный коммит, не «что на main»
docker compose -f docker-compose.yml build sinhron-server
docker compose -f docker-compose.yml up -d sinhron-server
# Migrations применятся автоматически на startup (sqlx::migrate)
docker compose -f docker-compose.yml ps sinhron-server   # → (healthy)
```

До 2026-10-15 `sinhron-server` всегда показывался `unhealthy` (healthcheck звал `wget`, которого нет в образе), хотя сервер работал. После обновления и пересборки — `healthy`.

### 9.1. Обновление 2026-11-04 (запись 240, ADR-087) — разовые шаги

**Сервер и все телефоны — вместе.** Переходных режимов больше нет: приложение старше этой версии после обновления сервера не добавит человека или устройство в чат (взятие KeyPackage без подписи — 401) и не объявит чат (401). Строки `SINHRON_LEGACY_MESSAGE_PUSH` и `SINHRON_LEGACY_GROUP_ANNOUNCE` в `.env`, если есть, больше ничего не делают — можно удалить.

1. **Обновить установщиком** (`sudo bash server/install.sh --yes`): он сам допишет в `.env` `SINHRON_NTFY_TOKEN` (публикация в свой ntfy теперь только с ним) и `SINHRON_DB_APP_USER=sinhron` (пока база остаётся на суперпользователе), перезапустит Postgres (несколько секунд) и все контейнеры. ntfy обновится до v2.28.0 (вернуться на v2.11.0 после этого нельзя — он переносит свою базу). Миграция `20261104160000` (push-токены) применится сама.
   Без установщика: добавить в `server/.env` строку `SINHRON_NTFY_TOKEN=tk_$(openssl rand -hex 15 | cut -c1-29)` (подставить вывод команды), затем `docker compose -f docker-compose.yml up -d`. Без токена ntfy не примет публикации сервера — push на Android не придут.
2. **Проверить:** Android (через ntfy) получает уведомление о сообщении и звонок; чужой не публикует: `curl -s -o /dev/null -w '%{http_code}\n' -d x https://<ntfy-домен>/up-test` → `403` (раньше `200`).
3. **Перевести сервер на свою роль базы (когда удобно; откат — шаг 3в):**
   а. В `server/.env` поменять `SINHRON_DB_APP_USER=sinhron` на `SINHRON_DB_APP_USER=sinhron_app` и добавить `SINHRON_DB_APP_PASSWORD=` + вывод `openssl rand -hex 32`.
   б. `sudo bash server/install.sh --yes` (он создаст роль, отдаст ей базу, схему и таблицы и перезапустит сервер). Вручную то же: `docker compose -f docker-compose.yml up -d --wait postgres && docker compose -f docker-compose.yml exec -T postgres sh /docker-entrypoint-initdb.d/10-app-role.sh && docker compose -f docker-compose.yml up -d`. Проверка: `docker compose -f docker-compose.yml exec -T postgres psql -U sinhron -d sinhron -Atc "SELECT rolsuper FROM pg_roles WHERE rolname='sinhron_app'"` → `f`; сервер `healthy`, сообщения ходят.
   в. Откат: вернуть `SINHRON_DB_APP_USER=sinhron`, убрать `SINHRON_DB_APP_PASSWORD`, `docker compose -f docker-compose.yml up -d` — суперпользователь читает таблицы любого владельца.
   Резервные копии теперь без владельцев (`pg_dump --no-owner`), `restore.sh` после восстановления отдаёт всё роли сервера.

### 9.2. Обновление 2026-11-04 (запись 244, ADR-090) — разовые шаги

**Сервер и все телефоны — вместе.** Приглашение в звонок без подписи звонящего сервер не пропускает (400), а новое приложение не показывает звонок без неё; announce без эпохи — отказ. Две миграции применятся сами: `20261104190000` (автор эпохи; застрявшим на 0 чатам — эпоха их карточки) и `20261104190100` (`backup_marks`). С ADR-093 (запись 250) ещё `20261106120000`: карточки по одной на устройство (старые удаляются, телефоны выложат свои сами при первой синхронизации), колонка автора эпохи удаляется.

1. `sudo bash server/install.sh --yes --commit <id>` (с этой версии без `--commit` код не обновляется; первый раз — как раньше: bundle и коммит руками, затем `--yes`).
2. **Проверить:** звонок на iPhone при закрытом приложении — имя на экране блокировки; групповой чат — добавить человека (Commit проходит, не «попробуйте ещё раз»); копия — «Создать копию сейчас» без ошибок.

### 9.3. Выпуск 0.12.0 — сервер и все телефоны (записи 223–252)

**Пошаговая инструкция для владельца — [`docs/release-0.12.0.md`](release-0.12.0.md).** Команды выпуска живут только там; здесь — что и почему, для помощника. Не копируйте шаги сюда: две копии разойдутся.

**Откуда и куда.** На сервере — код записи 222 (коммит `ebb2ce95`, выкладка 2026-11-02); запись 223 (#63) и всё после неё не выкладывались. На телефонах и iPad — 0.11.2. Выпуск несёт записи 223–252: видимое из 223 (иконки в меню, короткие ссылки-приглашения `/i/…`) и исправления проверки безопасности.

**Правила выпуска.**
- **Сначала сервер, потом телефоны.** Старое приложение новый сервер не пускает (401), новое не входит на старый. Приложение версию не проверяет: опоздавший видит только «Подключение…», iPhone звонит, но ответить нельзя; сообщения ждут на сервере. Семью предупреждают заранее другим способом.
- **Телефон, открывший 0.12.0, на 0.11.x не возвращается**: старая сборка не откроет хранилище MLS после новой (запись 251), схема базы приложения выросла, Android не ставит старый APK поверх нового. Откат сервера — **только пока ни один телефон не обновлён**.
- **`<id>` коммита записывают после последнего PR** (версия, снимки) — иначе на сервере он не совпадёт с `main`.
- **Сборка iPhone уходит в TestFlight после проверки сервера**: у `scripts/testflight.sh` есть только «собрать и отправить» и `--no-upload`; отдельного «выпустить» нет, и раздаёт ли группа сборки сама — из репозитория не видно. До сервера — только `--no-upload` (доказывает, что Swift и SQLCipher собираются).

**Скрипты выпуска** (`server/scripts/`, тест `release_test.sh`; на сервере их достают из нового коммита `git show <id>:…` в `/root/release-0.12.0/`, потому что preflight запускается, пока на диске ещё старый код):
- `release_preflight.sh [--dry-run] <версия>` — место на диске (15 ГБ, как требует `install.sh`), нет ли паролей-заглушек в `.env`, свежая копия `backup.sh` в `/root/backups/pre-<версия>/`, пробное восстановление дампа во временную базу, запись текущего коммита, образов и копии `.env` (600), копия `release_rollback.sh` туда же.
- `release_postcheck.sh [--dry-run] [<версия>]` — контейнеры healthy, число применённых миграций равно числу файлов в `server/migrations/`, `/_healthz`, вход WebSocket, TURN, LiveKit, настройки push; только читает.
- `release_rollback.sh [--dry-run] <версия>` — откат сервера из состояния preflight; спрашивает слово-подтверждение.

**Что делает обновление на сервере** (`install.sh --yes --no-upgrade` после `git checkout --detach <id>`):
- переписывает `server/.env` из `/etc/sinhron/sinhron.conf`: `SINHRON_PUBLIC_HOSTNAME` = `SINHRON_DOMAIN` оттуда (проверять и править имя нужно **в `sinhron.conf`**, не в `.env`; без верного имени сервер отклонит все входы — подписи называют сервер, ADR-086); дописывает `SINHRON_NTFY_TOKEN` и `SINHRON_DB_APP_USER=sinhron`; существующие секреты и пароль базы оставляет;
- **пароли-заглушки** (`dev_only`, `change-me…`, `GENERATE_…`) установщик заменил бы случайными **только в `.env`** — пароль в самой базе не меняется, сервер не войдёт в базу. Поэтому заглушка = стоп до выпуска (её ловит preflight), а не «установщик сам заменит»;
- без `--no-upgrade` делает `apt-get upgrade` (может обновить и перезапустить Docker) — в вечер выпуска не нужно; до любых изменений останавливается, если свободно меньше 15 ГБ, не сходится DNS или недоступен `download.docker.com`; «Sinhron работает» в конце печатается, даже если сервер за 5 минут не ответил — верить `release_postcheck.sh`;
- пересоздаёт контейнеры из `docker-compose.yml` (только из него): Postgres 16.4 → 16.15, ntfy v2.11.0 → v2.28.0 (обратно нельзя — он переносит свою базу), coturn r2 → r3 с новым запуском (секрет из своей копии конфига, не из аргументов), LiveKit — ключи из окружения; Caddy тоже пересоздаётся;
- **соседний сайт** (§4.1) живёт за тем же Caddy: перед выпуском `caddy validate` (ошибочный файл в `/etc/sinhron/caddy-sites/` не даст Caddy запуститься — недоступен будет и Sinhron); неотслеживаемый `server/docker-compose.override.yml` («сайты соседей», запись от 2026-11-01) установщик не читает — если сосед держался на нём, его сайт после пересоздания Caddy не вернётся, подключать как в §4.1;
- сервер при запуске сам применяет все миграции новее `20261101120000_admin_notices`. Сколько их: `git diff --name-only --diff-filter=A ebb2ce95 <id> -- server/migrations | wc -l` (цифру здесь не пишем — она растёт с исправлениями). Они только добавляют, кроме `20261106120000`: старые карточки чатов удаляются (каждый телефон выложит свои при первой синхронизации). Обратных миграций нет. Успех — строка журнала `migrations applied at startup`; сбой — `startup migration failed`, и с 0.12.0 сервер при этом **выходит** (контейнер перезапускается по кругу; прежний образ на базе с новой миграцией тоже не поднимется — откатывать только вместе с базой); postcheck дополнительно считает строки `_sqlx_migrations`;
- `server/turnserver.conf`: `user-quota=96` (было 24). Файл смонтирован в coturn одним файлом — после `git checkout` контейнер, созданный раньше, видит старый; в этом выпуске образ coturn меняется и контейнер пересоздаётся сам, но инструкция всё равно делает `up -d --force-recreate coturn` и проверяет строку;
- общий предел медиа `SINHRON_MEDIA_TOTAL_BYTES` (по умолчанию 50 ГиБ, проброшен в compose): на диске меньше ~70 ГБ задать меньше строкой в `.env` (установщик дописанные руками строки сохраняет); первая уборка удалит файлы медиа без строки в базе старше суток — базу и том медиа восстанавливать только вместе (`restore.sh` так и делает);
- новые необязательные пределы (`SINHRON_RATE_WS_CONNECT`, `_WS_BULK`, `_WS_COMMIT`, `SINHRON_RATE_GROUPS`, `SINHRON_RATE_KP_CONSUME_PAIR`) — значения по умолчанию подходят; при 429 на подключении у всей семьи за одним адресом поднять `SINHRON_RATE_WS_CONNECT`;
- `server/scripts/reports.sh` обновляется вместе с кодом (бан оставляет строку-блокировку) — старый скрипт с новым сервером не использовать;
- новый сервер в первый же час начнёт удалять запечатанные сообщения, полученные больше 30 дней назад (запись 240).

**Откат** (`release_rollback.sh`, порядок важен): `git checkout --detach` на записанный коммит и **сборка прежнего образа, пока новый сервер ещё работает** (сборка — минуты и сеть; не собралось — код возвращается, сервер не тронут) → остановить `sinhron-server` → вернуть `.env` из копии preflight (через временный файл; `gpg -d … > .env` при опечатке обнуляет `.env`) → `restore.sh <папка> <дата из файла stamp>` — ровно тот дамп, что preflight пробно восстановил, не «самый новый в папке»; копию старше двух суток скрипт не берёт (он в конце сам запускает `sinhron-server`: с ещё новым образом тот снова применил бы новые миграции к восстановленной базе) → поднять остальные сервисы **кроме ntfy** (`up -d` по всему старому compose понизил бы ntfy до v2.11 на базе от v2.28). Со старым сервером новый ntfy принимает публикации только с токеном — push на Android через ntfy до повторного выпуска может не приходить. Postgres при откате вернётся на 16.4 на том же томе (минорная версия; на живом сервере не проверялось).

**Разовые дела после выпуска** (команды — в `release-0.12.0.md`, часть Г): запрос «чужие устройства» (запись 227) — до обновления он показывает, сколько таких строк; если в выпускаемом коммите есть миграция `revoke_ghost_devices` (ветка исправлений аудита 12.11), сервер отключит их сам и после обновления запрос даст 0, иначе — вопрос владельцу; смена `LIVEKIT_KEYS` и `TURN_SHARED_SECRET` (их было видно в `ps`, установщик старые не меняет) и проверка `ps`; на каждом iPhone — «Перенести в связку ключей iCloud»; звонок через «Звонки через запасной путь» (TURN — в CI не запускается, его healthy значит только «процесс жив»); позже — своя роль базы (§9.1 шаг 3) и `install.sh --yes` без `--no-upgrade`.

**Чего никто не проверял до выпуска:** Swift (кроме `PushShared.swift` с тестами — только полная сборка iOS на Маке), ntfy 2.28 с токеном, новый запуск coturn и LiveKit — ни в CI, ни на живом сервере; установщик на сервере с данными последний раз запускали 2026-10-19.

**Rolling restart:**
```bash
docker compose -f docker-compose.yml up -d --force-recreate --no-deps sinhron-server
# Postgres + Caddy не трогаются. Клиенты ws переподключатся.
```

---

## 10. Когда переходить на следующий уровень

| Признак | Действие |
|---|---|
| `SINHRON_PG_MAX_CONNS` > 80% утилизация | Bump SINHRON_PG_MAX_CONNS, watch RAM |
| > 100 concurrent users | Bump VM до 8 vCPU / 16 GB |
| Звонки приходят (когда сделаем) | Add LiveKit + coturn services в compose |
| Сервер в одной геолокации не хватает | Split LiveKit на ближайшую к users VM |
| > 1000 users | Multi-replica sinhron-server + pgbouncer + dedicated Postgres |

### 10.1. PgBouncer (tech-debt 2.13)

В `docker-compose.yml` есть необязательный сервис `pgbouncer` (`edoburu/pgbouncer:v1.25.2-p0`, профиль `pgbouncer`, только внутри docker-сети). Включить — в `.env`:

```bash
COMPOSE_PROFILES=pgbouncer
SINHRON_DB_HOST=pgbouncer
# PGBOUNCER_MAX_CLIENT_CONN=1000
# PGBOUNCER_POOL_SIZE=20
```

Режим `transaction`, `MAX_PREPARED_STATEMENTS=200` — PgBouncer ≥ 1.21 сохраняет подготовленные запросы sqlx. **Миграции идут мимо PgBouncer** (`SINHRON_DB_MIGRATE_URL` прямо в `postgres`): мигратор держит advisory lock на всю сессию, а transaction pooling отдаёт каждую транзакцию случайному соединению. `IGNORE_STARTUP_PARAMETERS: extra_float_digits` обязателен: sqlx шлёт этот параметр при подключении, без него PgBouncer рвёт соединение (`unsupported startup parameter`) — найдено живым прогоном 2026-10-14 (PgBouncer 1.25.2, transaction, сквозные тесты зелёные). Проверить после включения: `docker compose logs sinhron-server | grep migrations` и `/_readyz`.

---

## 11. Безопасность production checklist

- [ ] SSH only via key auth, password disabled
- [ ] `ufw` enable, только нужные порты открыты
- [ ] Postgres password длинный (>32 chars), не commit'нут в git
- [ ] `.env` chmod 600, owner = sinhron
- [ ] Каждодневный pg_dump в безопасное место (другой VPS или encrypted blob)
- [ ] Caddy email вписан (cert expiry alerts)
- [ ] `curl -sI https://<host>/_healthz` показывает `Strict-Transport-Security` и `Content-Security-Policy`
- [ ] `fail2ban` enabled для SSH
- [ ] OS updates через `unattended-upgrades`
- [ ] Backup `.env.gpg` где-то ВНЕ VM
- [ ] Monitoring (uptimerobot.com или собственный Prometheus + Alertmanager)
- [ ] Запасной admin SSH key зарегистрирован (на случай потери основного)

---

## 12. Что точно НЕ нужно делать

- ❌ Открывать 5432 (Postgres) наружу
- ❌ Открывать 8080 (sinhron-server) наружу — только через Caddy
- ❌ Хранить `.env` в git
- ❌ Запускать docker compose -f docker-compose.yml от root user
- ❌ Использовать default Postgres password в production
- ❌ Отключать `synchronous = NORMAL` в Postgres (data loss risk)
- ❌ Игнорировать `pending_welcomes` retention — заполнит диск если миллионы offline invites
- ❌ Скрывать `RUST_LOG=info` в production — без логов диагностика невозможна

---

## 13. Куда обращаться при проблемах

- **GitHub Issues** (TODO: настроить project repo)
- **Threat model**: `docs/threat-model.md` — что считается атакой и как защищаемся
- **ADRs**: `docs/decisions.md` — почему мы делали так а не иначе

---

**Версия документа.** v1.0 / 2026-05-23. Обновляется при изменении deployment surface (новый required env var, новый сервис, etc.).
