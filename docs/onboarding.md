# Sinhron · onboarding для нового contributor / для Claude после context reset

> Цель: за 30 минут от чистого `git clone` до "вижу как Alice пишет Bob'у через сервер".
> Если что-то не работает на твоей машине — это, скорее всего, баг в этой инструкции, не в коде. Pull request приветствуется.

---

## Что ты получишь после прохождения

1. ✅ Локально собранный workspace (rust client + server + Flutter)
2. ✅ Запущенный Postgres + sinhron-server (locally)
3. ✅ iOS Simulator + сборка приложения
4. ✅ End-to-end smoke `cargo run --example full_e2e` — Alice ↔ Bob через настоящий протокол
5. ✅ Понимание где что лежит (см. `docs/code-map.md`)

---

## 0. Предпосылки

**Машина:** Mac (рекомендуется) или Linux. Windows — не тестировано, может работать.

**Инструменты которые надо иметь:**

| Tool | Версия | Установка |
|---|---|---|
| **Rust** | 1.94.1+ | `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh` |
| **Flutter** | 3.41.5 (через fvm) | `brew install fvm`, потом `cd client_flutter && fvm install` |
| **Xcode + iOS Simulator** | Latest | App Store. Затем `sudo xcode-select --install` |
| **Docker Desktop** | 25.x+ | https://www.docker.com/products/docker-desktop/ |
| **flutter_rust_bridge_codegen** | 2.11.1 | `cargo install flutter_rust_bridge_codegen --version 2.11.1` |
| **PostgreSQL client** (опц.) | 16 | `brew install postgresql@16` — для psql из CLI |
| **gh** (опц.) | latest | `brew install gh` — для GitHub interactions |
| **ripgrep** | latest | `brew install ripgrep` — быстрее `grep` |

**Проверь что есть всё:**

```bash
rustc --version          # >= 1.94.1
fvm flutter --version    # 3.41.5
xcodebuild -version      # >= 16
docker --version         # >= 25
flutter_rust_bridge_codegen --version  # 2.11.1
```

---

## 1. Клонирование + первая компиляция

```bash
git clone <your-repo-url> sinhron
cd sinhron

# Структура должна быть:
# .
# ├── client_flutter/
# ├── server/
# ├── design_handoff_sinhron/
# └── docs/

# Установить Flutter SDK через fvm (один раз на машину)
cd client_flutter
fvm install   # читает .fvmrc → ставит Flutter 3.41.5
fvm flutter --version  # должно показать 3.41.5

# Поставить Dart deps
fvm flutter pub get

# Compile Rust workspace (client)
cd rust
cargo check --workspace   # ~3-5 минут first time
# успех = "Finished `dev` profile"

cd ../..

# Compile server workspace
cd server
SQLX_OFFLINE=true cargo check
# успех = "Finished `dev` profile"
cd ..
```

**Если что-то падает на этом этапе:**
- "Error: 'fvm' not found" → `brew install fvm`, перезапусти shell
- "couldn't find Cargo.toml" → проверь что ты в правильной директории
- Long Rust compile + curl errors → проверь internet, retry
- "linker error" на macOS → `xcode-select --install`

---

## 2. Запустить тесты

```bash
# Client side (~71+ tests across крейтов)
cd client_flutter/rust
cargo test --workspace
# expected (2026-10-13): sinhron_crypto 15 + sinhron_net 8 (+4 tests/keepalive.rs) +
#           sinhron_storage 22 + sinhron_sync 58 + sinhron_call 21 (11 sframe + 10 state) +
#           sinhron_cli 2 + sinhron_core (FFI) 3 = 133 passed

# Server side (без DB — 51 passed, 17 ignored)
cd ../../server
SQLX_OFFLINE=true cargo test          # с 2026-10-13 компилируются и примеры, и doc-тесты
# без базы: 51 passed, 17 ignored (тесты с Postgres)
# С базой: DATABASE_URL=postgres://… cargo test -- --include-ignored → 68 passed
#   (на Mac без Docker: временный Postgres только на unix-сокете —
#    initdb + pg_ctl -o "-c listen_addresses='' -k <короткий путь>", путь сокета < 104 байт)
# Sealed без аутентификации (ADR-026) и QR-привязка (ADR-027), сервер + Postgres:
#   SINHRON_E2E_HTTP=http://127.0.0.1:18080 cargo run -p sinhron_sync --example unidentified_e2e
#   SINHRON_E2E_HTTP=http://127.0.0.1:18080 cargo run -p sinhron_sync --example pairing_e2e
# Прокси SOCKS5 (ADR-028): любой SOCKS5 на 127.0.0.1:18081 (для проверки годится крошечный
#   скрипт на asyncio — CONNECT без авторизации), затем
#   SINHRON_E2E_HTTP=http://127.0.0.1:18080 SINHRON_E2E_SOCKS=127.0.0.1:18081 cargo run -p sinhron_sync --example proxy_e2e
# Несколько устройств end-to-end (ADR-025; запущенный сервер + Postgres):
#   SINHRON_E2E_HTTP=http://127.0.0.1:18080 cargo run -p sinhron_sync --example multidevice_e2e
#   (повторные прогоны на той же базе: Welcome прошлых прогонов пропускаются — так и задумано;
#    больше 5 регистраций личности в час → 429, перезапуск сервера сбрасывает счётчик)
# Sealed sender end-to-end (ADR-023; запущенный сервер + Postgres):
#   SINHRON_E2E_HTTP=http://127.0.0.1:18080 cargo run -p sinhron_sync --example sealed_e2e
# Медиа end-to-end (нужен запущенный сервер + Postgres):
#   SINHRON_E2E_HTTP=http://127.0.0.1:8080 cargo run -p sinhron_sync --example media_e2e
# Включает: 25 baseline + 11 call_session + 5 handlers/call

# Flutter widget tests (43 golden tests + 12 FSM в active_call_provider_test.dart;
# часть FSM тестов требует Rust dylib loaded — see tech-debt 4.1)
cd ../client_flutter
fvm flutter test
# факт (2026-10-13, macOS): 301 passed, 6 failed — падают FSM-тесты
# active_call_provider_test.dart, которым нужна загруженная Rust-библиотека
# (tech-debt 4.1). Любое другое падение — регрессия.
fvm flutter analyze
# факт: 3 замечания (unused import / super parameter / unused _accept в
# active_call_provider_test.dart) — старые, не регрессия
```

**Если что-то не проходит:** скорее всего env issue (missing dep), а не реальный bug. Открой issue / читай `docs/tech-debt.md` § 6 "Известные gotchas".

**В облаке (Claude Code web / приложение Claude на телефоне):** репозиторий `github.com/SinhronApp/SinhronApp`. При старте сессии SessionStart-hook (`.claude/settings.json` → `.claude/cloud_setup.sh`) ставит protoc + Flutter 3.41.5, поднимает PostgreSQL 16 (роль `sinhron`, только `CREATEDB`) и экспортирует `DATABASE_URL`/`SINHRON_DB_URL` — `cargo test -- --include-ignored` на сервере работает без ручной настройки. Лог: `/tmp/cloud_setup.log`. Golden-тесты (`test/goldens/`, `test/goldens_screens/`) в облаке пропускать — сняты на macOS (экраны — ещё и в UTC+3). iOS-сборка — только на Mac. Команды — в корневом `CLAUDE.md`.

---

## 3. Поднять Postgres + server

**Вариант A: через Docker (рекомендуется)**

```bash
cd server
cp .env.example .env  # если нет, создай вручную с минимальным содержанием:
# POSTGRES_USER=sinhron
# POSTGRES_PASSWORD=local_dev_only_password
# POSTGRES_DB=sinhron
# SINHRON_DB_URL=postgres://sinhron:local_dev_only_password@postgres:5432/sinhron
# SINHRON_LISTEN=0.0.0.0:8080
# RUST_LOG=info,sinhron_server=debug,sqlx=warn

# Запустить весь стек (Postgres + sinhron-app + Caddy)
docker compose up -d

# Проверить логи
docker compose logs -f sinhron-app
# должно появиться "sinhron-server listening 0.0.0.0:8080"

# Smoke test
curl http://localhost:8080/_healthz
# {"status":"ok","service":"sinhron-server","version":"0.1.0"}
curl http://localhost:8080/_readyz
# {"status":"ok"}  (если 503 — Postgres ещё не успел)
```

**Вариант B: нативный Postgres (если Docker раздражает)**

```bash
brew install postgresql@16
brew services start postgresql@16
createdb sinhron_dev

cd server
DATABASE_URL=postgres://localhost/sinhron_dev SQLX_OFFLINE=false cargo sqlx migrate run
DATABASE_URL=postgres://localhost/sinhron_dev SINHRON_DB_URL=postgres://localhost/sinhron_dev cargo run --release
# sinhron-server listening 0.0.0.0:8080
```

**Если падает:**
- "connection refused" → Postgres не стартанул. `docker compose logs postgres` или `brew services list`.
- "could not find Cargo.toml" → cd в server/
- "version mismatch" — pin'нь в .env правильную Postgres URL

---

## 4. End-to-end smoke: Alice ↔ Bob

С сервером в running state:

```bash
cd client_flutter/rust
cargo run --example full_e2e
```

**Expected output:**

```
→ full_e2e starting · ws=ws://localhost:8080/v1/sync http=http://localhost:8080
alice → bootstrap_with_server
alice ✓ user_pk=... identity=...
bob → bootstrap_with_server
bob ✓ user_pk=... identity=...
alice ✓ ws connected
bob ✓ ws connected
alice ← bob_identity = ...
alice ✓ group_id = ...
alice ✓ invite outcome · commit=... welcome=...
alice → Welcome dispatched via WS
bob ← Welcome group=... welcome_len=...
bob ✓ joined group ...
alice → Submit dispatched · ciphertext_len=...
bob ← Push group=... ciphertext_len=...
bob ✓ decrypted plaintext: "hello sinhron, this is real MLS over the wire"

🎯 full_e2e end-to-end · MLS plaintext round-trip ✓
```

**Если падает:**
- `Connection refused` → server не запущен, см. §3
- `Unauthorized` → check server logs `docker compose logs sinhron-app`
- timeout → может быть TLS pinning issue, но в dev URL ws:// (не wss://) — pinning не должен срабатывать

---

## 5. Запустить Flutter app в iOS Simulator

```bash
cd client_flutter

# Выбрать симулятор (один раз)
xcrun simctl list devices available  # посмотри что есть
# Запустить например iPhone 16 Pro Max
xcrun simctl boot "iPhone 16 Pro Max"
open -a Simulator

# Билд + запуск
fvm flutter run -d "iPhone 16 Pro Max"
# default URL = ws://localhost:8080/v1/sync — будет работать с локальным server
```

**В Simulator:**
1. Видишь splash screen → swipe / wait
2. Welcome screen → "Get started"
3. ServerInvite → "Continue"
4. Profile screen → введи имя → "Continue"
5. RecoveryPhrase screen → запиши phrase (или копируй) → check "I've written it down" + "I understand losing it means losing the account" → "Continue"
6. **Identity persisted → ChatList screen**

**Settings → Phase 2 diagnostics** (внизу) покажет:
- `boot: OK` (зелёная плашка)
- `core: sinhron_core 0.1.0 ...`
- `db: /.../sinhron.db`
- `mls: /.../sinhron-mls.sqlite (X.X KiB)` — proof of SQLCipher persistence
- `id: fp=XXXX XXXX XXXX · saved ...`

---

## 6. Запустить второй Simulator (Alice + Bob в parallel)

Sim'ы могут крутиться сразу несколько:

```bash
# Список доступных
xcrun simctl list devices available
# Boot ВТОРОЙ
xcrun simctl boot "iPad Pro 13-inch (M4)"  # или любой другой ID

# Запустить тот же app на втором
fvm flutter run -d "iPad Pro 13-inch (M4)"
```

**Тестовый сценарий:**
- Alice (Sim 1): онбординг с phrase A → ChatList → Profile Edit → копируй identity hex (64 hex)
- Bob (Sim 2): онбординг с phrase B → ChatList → Compose → "Paste id" → вставь Alice's hex → "Start chat"
- Bob видит свежий chat row
- Bob пишет "hi" → Alice получает через WS → Push → decrypt → bubble в её ChatView

**Если не приходит сообщение Bob → Alice:**
- check server logs: `docker compose logs sinhron-app | tail -20`
- check WS-connect logs в Sim debug console — "[sinhron][net] connected" должно быть
- check Settings → Diagnostics — `mls: ... (X.X KiB > 0)` означает MLS state persisted

---

## 6.5. Тестирование звонков локально (Phase 3 Calls)

**Pre-req.** docker-compose должен поднять не только postgres + sinhron-app + caddy, но ещё **livekit** + **coturn**. Они уже в `server/docker-compose.yml`. Дополнительно нужны env vars в `.env`:

```bash
# В дополнение к POSTGRES_* / SINHRON_* из §3:
LIVEKIT_KEYS=devkey: secret-min-32-chars-required-by-livekit-server-1234
LIVEKIT_URL=ws://<Mac LAN IP>:7880      # dev-override отдаёт это клиентам (без Caddy)
TURN_SHARED_SECRET=local-dev-only-turn-secret-min-32-chars-1234
TURN_REALM=sinhron.local
TURN_URLS=turn:localhost:3478?transport=udp
TURN_EXTERNAL_IP=127.0.0.1              # обязателен для compose; в dev не используется
# TURN_TTL_SECS=86400
```

> ⚠️ Эти secrets — **локальные only**. Никогда не используй их в production. Generate new для prod via `openssl rand -hex 32`.

```bash
cd server
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d   # dev: 8080 и 7880 открыты, Caddy выключен
docker compose ps   # postgres + sinhron-server + livekit + coturn (caddy — в профиле donotstart)

# Smoke check LiveKit
curl http://localhost:7880   # должно вернуть HTML LiveKit welcome page

# Smoke check TURN (нужен turnutils из homebrew coturn package)
# brew install coturn
# turnutils_uclient -u <username-from-curl-below> -w <cred-from-curl-below> -y localhost
```

**Headless test через sinhron_cli (без Sim):**

```bash
cd client_flutter/rust
cargo build -p sinhron_cli

# Alice + Bob bootstrap (см. §7)
# Затем:
./target/debug/sinhron-cli call-invite \
    --phrase "abandon ... art" \
    --server http://localhost:8080 \
    --group "$ALICE_GID" \
    --kind audio   # или video

# В parallel в другой консоли Bob accept:
./target/debug/sinhron-cli call-accept \
    --phrase "legal ... title" \
    --server http://localhost:8080 \
    --call-id "<uuid-printed-by-invite>"

# Затем end:
./target/debug/sinhron-cli call-end \
    --phrase "..." \
    --server http://localhost:8080 \
    --call-id "..."
```

CLI делает signaling (CallInvite/Accept/End/Ring proto frames через WS) **но не запускает реальный media stack** (нет libwebrtc). Это поднимает CallSession через WS + проверяет ringing watchdog. Для real media — нужен Flutter app на 2-х Sim'ах.

**2-Sim media test (полный e2e):**

1. Поднять стек (см. выше).
2. Запустить 2 Sim'а (§5 + §6) с Alice + Bob onboarded.
3. Alice добавляет Bob в чат (Compose → paste hex).
4. ContactInfo Bob'а → "Video Call" → permission gate (mic + camera) → ringing.
5. На Sim Bob'а → incoming LiveCallScreen → "Accept".
6. LiveKit room connects с E2EE SFrame keys из MLS exporter → media flows (видишь front camera).
7. Mute / cam-flip / hangup работают.

**Acceptance criteria + edge cases:** см. `docs/evidence/calls-manual-test-plan.md` (12 baseline + 5 edge сценариев).

**Known limitations (что НЕ работает локально без operator setup):**
- **Lock-screen incoming** — требует PushKit VoIP push + Apple Developer cert. Без cert: incoming показывается только когда app в foreground.
- **Cross-LAN calls** через прод TURN/STUN — local docker-compose uses host network mode для coturn; если хотите test cross-NAT, нужен публичный coturn deploy.

---

## 6.6. iPhone и TestFlight

Подпись — автоматическая, команда `CBJTTRBDF3` (Apple Developer Program, частный разработчик; с 2026-10-15 платная, Team ID тот же, что у прежней Personal Team).

**На свой iPhone (без TestFlight):**

```bash
cd client_flutter
rm -rf .dart_tool/flutter_build build/native_assets/ios   # см. ниже
nice -n 19 fvm flutter build ios --release
xcrun devicectl device install app --device <UDID> build/ios/iphoneos/Runner.app
xcrun devicectl device process launch --device <UDID> com.sinhron.sinhron
```

**Версия — перед каждой сборкой для владельца** (правило владельца, CLAUDE.md): поднять `version:` в `client_flutter/pubspec.yaml` и `kAppVersion` в `lib/features/settings/settings_screen.dart` (тест `test/core/app_version_test.dart` держит их равными); в Настройках → «О приложении» видно «0.2.0 (номер сборки)».

**В TestFlight:** `bash client_flutter/scripts/testflight.sh` — собирает IPA (номер сборки = UTC-время `YYYYMMDDHHMM`, он же передаётся в приложение `--dart-define=SINHRON_BUILD`) и загружает её через Apple ID, под которым вошёл Xcode (`ios/ExportOptionsUpload.plist`, `destination=upload`); `--no-upload` — только IPA. Apple обрабатывает сборку 10–30 мин. Внутренние тестировщики (до 100, без проверки Apple) добавляются в App Store Connect → Users and Access, затем в группу TestFlight.

**Ловушки (найдены 2026-10-15):**
- **Сборки для симулятора и iPhone в одной папке** — Flutter может подложить `objective_c.framework` от другой цели (native assets не перезаписываются): приложение не открывает базу, «Продолжить» не работает. Перед сменой цели — `rm -rf .dart_tool/flutter_build build/native_assets/ios`. Проверка: `otool -l …/Frameworks/objective_c.framework/objective_c | grep -A3 LC_BUILD_VERSION` → `platform 7` симулятор, `platform 2` iPhone.
- **CallKit в симуляторе** завершает каждый звонок — в сборке для симулятора мост `dev.sinhron/callkit` ничего не делает (`CallKitBridge.swift`); звонок идёт через экран приложения. У симулятора нет камеры — видео с его стороны нет, звонок остаётся аудио.
- **Разрешения `permission_handler`** включаются макросами в `ios/Podfile` (`PERMISSION_MICROPHONE`, `PERMISSION_CAMERA`); без них запрос сразу «отказано» без диалога.
- **Симулятор без окна** (правило общего Mac) не синхронизирует буфер обмена с Mac: `pbpaste | xcrun simctl pbcopy <UDID>`.
- **Шифрование:** `ITSAppUsesNonExemptEncryption = NO` в `Info.plist` (только стандартные алгоритмы) — решение владельца 2026-10-15; формально раз в год (до 1 февраля) подаётся self-classification report в BIS.

---

## 6.8. Android (ADR-040, `docs/android-plan.md`)

Тулчейн вне репозитория: JDK 17 (`~/opt/jdk-17`), Android SDK 36 + NDK 28.2 (`~/Library/Android/sdk`), Rust-таргеты `aarch64/armv7/x86_64-linux-android`. Сборка:

```bash
export JAVA_HOME=$HOME/opt/jdk-17/Contents/Home ANDROID_HOME=$HOME/Library/Android/sdk
cd client_flutter && flutter build apk --debug --target-platform android-arm64
```

Подписанный release (ключ `~/Documents/Keys/sinhron/android-release.jks` + `.pass`, вне git — потерять нельзя, обновления не встанут): `bash client_flutter/scripts/android_release.sh`. Push на телефоне: приложение ntfy (F-Droid), сервер в нём — `push.<домен>` оператора (установщик: `ENABLE_NTFY=yes`).

## 6.7. Оператор: жалобы и удаление аккаунта (ADR-037)

Жалобы из приложения лежат в таблице `abuse_reports` (ключи, причина, текст — только если жалующийся решил его отправить). Проще всего — скриптом (2026-10-16): `cd /opt/sinhron/server && scripts/reports.sh` (открытые), `scripts/reports.sh show <id>`, `scripts/reports.sh done <id>`, `scripts/reports.sh ban <ключ>` (спросит подтверждение). Вручную, SQL:

```bash
sudo docker compose -f /opt/sinhron/server/docker-compose.yml exec postgres psql -U sinhron -c "SELECT id, created_at, reason, encode(reported_identity,'hex') AS reported, left(message_text, 200) AS text FROM abuse_reports WHERE reviewed_at IS NULL ORDER BY created_at"
```

**В приложении (ADR-077, 2026-10-24):** если ваш адрес указан администратором (`ADMIN_KEYS` в `/etc/sinhron/sinhron.conf` → `SINHRON_ADMIN_IDENTITIES`), каждая жалоба приходит в строку «Сервер» вверху «Чатов»: номер, причина, начала ключей, IP жалующегося и последний IP нарушителя, сколько на него жалоб за 30 дней, текст и полный ключ (долгое нажатие — скопировать; дальше `scripts/reports.sh ban <ключ>`). Туда же — тревоги о нагрузке (процессор, память, соединения). IP к жалобам стираются через 30 дней (`reporter_ip`, `reported_ip`; `scripts/reports.sh show <id>` их показывает).

Отметить рассмотренной: `UPDATE abuse_reports SET reviewed_at = NOW() WHERE id = …;`. Удалить нарушителя (то же, что делает его собственное «Удалить аккаунт»): `DELETE FROM message_deliveries WHERE recipient_user_pk IN (SELECT user_pk FROM users WHERE identity_pubkey = decode('<hex>','hex')); DELETE FROM users WHERE identity_pubkey = decode('<hex>','hex');` — устройства, ключи и членство уходят каскадом. Apple ждёт реакции на жалобы примерно в течение суток.

## 7. Запустить headless CLI (для skript-тестов)

```bash
cd client_flutter/rust
cargo build -p sinhron_cli

# Bootstrap Alice
./target/debug/sinhron-cli bootstrap \
    --phrase "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art" \
    --server http://localhost:8080
# ✓ user_pk=... already_existed=false identity=... kp_id=...

# Bootstrap Bob (другая phrase)
./target/debug/sinhron-cli bootstrap \
    --phrase "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title" \
    --server http://localhost:8080

# Alice создаёт group
ALICE_GID=$(./target/debug/sinhron-cli create-group \
    --phrase "abandon ... art" 2>/dev/null)
echo "Group: $ALICE_GID"

# Alice фетчит Bob's KP + invite
./target/debug/sinhron-cli invite \
    --phrase "abandon ... art" \
    --server http://localhost:8080 \
    --group "$ALICE_GID" \
    --target "<bob-identity-hex>"

# Listen as Bob:
./target/debug/sinhron-cli listen \
    --phrase "legal ... title" \
    --server http://localhost:8080 \
    --group "$ALICE_GID"

# В другой консоли: Alice posts
./target/debug/sinhron-cli send \
    --phrase "abandon ... art" \
    --server http://localhost:8080 \
    --group "$ALICE_GID" \
    --text "hi from CLI"
# ← Bob's listen console печатает: ← msg "hi from CLI"
```

---

## 8. Что делать дальше

### Если ты новый contributor

1. Прочитай **`docs/PROJECT.md`** — общая карта проекта
2. Прочитай **`docs/code-map.md`** — детальная карта файлов
3. Прочитай **`docs/architecture.md`** — как куски связаны
4. Открой **`docs/decisions.md`** — почему именно так (ADRs 001-015 включая ADR-015 LiveKit + SFrame для calls)
5. Когда дойдёт до реальной работы — **`docs/tech-debt.md`** чтобы не сломать сильнее

### Если ты Claude после context reset

Минимум:
1. Прочитай **`docs/PROJECT.md`**
2. Прочитай **`docs/status.md`** § "Текущая фаза"
3. Прочитай **`docs/overnight-log.md`** если последняя сессия была ночной автономкой
4. Затем — зависит от задачи (см. `/goal` input)

Не делай:
- `git commit` без явного запроса оператора
- `git push --force`, `--no-verify`, `--amend`
- правок `.env*`, `settings.json`, secrets
- удалений файлов кроме `/tmp/*`

### Если ты оператор хочешь deploy

→ **`docs/deploy-guide.md`** step-by-step.

---

## 9. Cheat sheet команд

```bash
# Tests
(cd client_flutter/rust && cargo test --workspace)
(cd server && SQLX_OFFLINE=true cargo test --lib)
(cd client_flutter && fvm flutter test && fvm flutter analyze)

# Build
(cd client_flutter && fvm flutter build ios --simulator --debug --no-codesign)

# Regenerate FRB
(cd client_flutter && flutter_rust_bridge_codegen generate)
(cd client_flutter && bash scripts/check_frb_drift.sh)  # verify clean

# Run examples
(cd client_flutter/rust && cargo run --example full_e2e)
(cd client_flutter/rust && cargo run --example bootstrap_smoke)
(cd client_flutter/rust && cargo run -p sinhron_sync --example calls_e2e)  # SFrame keys end-to-end

# Server up/down
(cd server && docker compose up -d)
(cd server && docker compose down)
(cd server && docker compose logs -f sinhron-app)

# Quick local server (без docker — нативный pg)
(cd server && SINHRON_DB_URL=postgres://localhost/sinhron_dev cargo run --release)

# Find a file fast
rg --files | rg path/to/

# Find a symbol fast
rg 'fn handle_submit' --type rust

# Все TODO в коде
rg 'TODO|FIXME|XXX|HACK' --type rust --type dart
```

---

## 10. Куда обращаться при затыке

- **`docs/glossary.md`** — что такое MLS / SFrame / KP / frb / HKDF / etc.
- **`docs/tech-debt.md`** § 6 "Известные gotchas" — известные ловушки
- **`docs/threat-model.md`** — почему мы делаем X а не Y (security perspective)
- **`design_handoff_sinhron/spec/architecture.md`** — эталон, спека
- **GitHub Issues** (TBD — настроить project repo) — open issue / PR
- **Владелец** — architect / operator

---

**Готов?** Запусти § 4 (`cargo run --example full_e2e`). Когда увидишь `🎯 full_e2e end-to-end · MLS plaintext round-trip ✓` — ты в курсе как тут всё работает на самом нижнем уровне.
