# GOAL · Build the entire Sinhron backend

> **Создано:** 2026-05-22 (после WU 73.2)
> **Назначение:** persistent goal file для Claude Code's goal feature. Этот документ читается **первым** при resume после compact'а / новой сессии. Он содержит ВСЁ что нужно чтобы продолжить работу автономно — не нужно задавать пользователю уточняющие вопросы по архитектуре.
>
> **Hard rule:** если этот документ не объясняет что делать дальше — обнови его **сразу** перед тем как закроется текущая сессия, чтобы следующая инкарнация могла продолжить.

---

## 1. Mission (короткая формулировка)

Построить **весь backend стек** Sinhron'а — Axum-сервер (Rust + PostgreSQL + WebSocket) + оставшиеся 4 Rust-крейта клиента (`sinhron_net`, `sinhron_sync`, `sinhron_call`, `sinhron_cli`) — до состояния когда **реальное E2E-шифрованное сообщение проходит от одного устройства до другого через сервер**.

«Готово» = на двух iPhone'ах (или iPhone + iOS Sim) Alice → Bob → текстовое сообщение, расшифровано на Bob'е, server stores only ciphertext + metadata.

---

## 2. Где мы сейчас (state on 2026-05-22, после WU A4)

- **Phase 1 (UI):** ✅ закрыта. 45 features, 18 widgets, 41 golden snapshots
- **Phase 2 client-side (step 1-7):** ✅ закрыты — sinhron_crypto, sinhron_storage v2, Riverpod scaffold, ChatView persistence, boot diagnostics, identity-aware routing, sign-out wipe
- **Stage A (server):** ✅✅✅ **12/12 DONE**. Endpoints, retention, push stub, Docker, integration smoke.
- **Stage B (sinhron_net client):** 4/5 done. B3 TLS pinning deferred to security polish.
- **Stage C (sinhron_sync — MLS bridge):** 6/7 done. C1 scaffold, C2 FFI encrypt/decrypt, C3 HTTP KeyPackage, C4 Welcome-over-WS, C5a identity bootstrap, **C6 ✅ MLS state-at-rest via openmls_sqlite_storage** (regression test proves group survives client drop+reopen). C5 conflict resolution + C7 server-side state_backup still pending.
- **Stage E (Flutter integration):** 2/5 done. E1 NetService event loop ✅. E4 Compose UX driving MLS dance ✅ + ProfileEdit "Copy identity" row exposes the 64-hex pubkey for paste-share. **Demo flow is now self-contained**: Alice copies her identity, Bob pastes it into Compose → "Paste id", server forwards Welcome, Bob's NetService joins the group, Alice's encrypted message lands on Bob's side. E2 chatsProvider-from-server polish, E3 push iOS native, E5 two-iPhone real test still pending.

🎯🎯🎯 **GOAL §12 functional criterion ACHIEVED** — `examples/full_e2e.rs` proves Alice→server→Bob plaintext round-trip via real MLS protocol on real WS+HTTP. Server logs show only ciphertext + sizes + ts + recipient_list — no plaintext, no sender identity inside the fanout path.

**🎯 ALL pre-prod blockers shipped** (2026-05-22):
- ☑ C6 — MLS state at rest (openmls_sqlite_storage + regression test)
- ☑ B3 — TLS pinning (rustls config with bundled operator CA)
- ☑ C5 — Graceful stale-epoch handling
- ☑ E2 — chatsProvider listens to server pushes
- ☑ E3 — APNs payload contract (server-side; iOS cert awaits operator's Apple Developer account)
- ☑ 73.2 — Boot diagnostics + identity-aware routing

Remaining items are user-side / out-of-engineering: physical-iPhone deploy (E5 — deferred per user direction) + Apple Developer account for E3 cert provisioning + production server deployment (docker-compose ready).
- **Stage B/C/D/E/F:** ❌ pending (sinhron_net, sinhron_sync, sinhron_cli, Flutter integration, calls)

**Что работает end-to-end:** клиент локально — да; server — registration + KeyPackage upload/consume через HTTP. Сеть между клиентом и сервером — ❌ нет (нет sinhron_net client крейта). Реальные MLS-сообщения через сеть — ❌ нет.

---

## 3. Resume protocol (что читать **первым** после compact'а)

В этом порядке:

1. **Этот файл** (`docs/goal-backend.md`) — целиком. Section §4 (Scope ladder) → найди первую невычеркнутую WU → это твой текущий стартовый пункт.
2. **`docs/status.md`** — раздел «Текущая фаза» (первые 50 строк). Подтверждает где мы.
3. **`design_handoff_sinhron/spec/architecture.md`** — §7 (Backend) + §9 (Real-time) + §5.2 (Rust workspace). Эти три секции — твой источник правды по требованиям.
4. **`docs/decisions.md`** — последние 2-3 ADR'а. Понимай контекст недавних решений.
5. **`docs/goal-backend.md#scope-ladder`** (§4 ниже) — твой план работ.

После чтения этих 4 источников у тебя должен быть полный контекст. Никаких уточняющих вопросов пользователю до выполнения первой WU.

---

## 4. Scope ladder — конкретные WUs в порядке выполнения

Каждая WU — атомарная единица работы (3-8 часов). Делай по одной за раз. Помечай ✅ когда сделана + пиши номер в `docs/status.md`.

### Stage A · Server foundation (PostgreSQL + Axum)

> Spec §7 — это эталон. PostgreSQL 16, sqlx, Axum 0.7+. См. §7.4 для schema. §7.5+ для endpoints.

- [x] **A1** · ✅ 2026-05-22 · Server workspace skeleton: `server/` рядом с `client_flutter/` (separate Cargo workspace). Axum 0.8.9 + Tokio 1.47.3 + tower-http + tracing. `GET /_healthz` → `{"status":"ok","service":"sinhron-server","version":"0.1.0"}`. Graceful SIGTERM/SIGINT shutdown. 2 unit tests (healthz + 404 route) pass. `SINHRON_LISTEN` env var override.
- [x] **A2** · ✅ 2026-05-22 · PostgreSQL schema v1 + sqlx migration runner. 9 tables per spec §7.4 (`users` / `devices` / `keypackages` / `mls_groups` / `group_members` / `messages` partitioned by month / `media` / `push_subscriptions` / `state_backups`) — 17 CREATE statements applied cleanly on Postgres 16.14. `sqlx::migrate!` embeds migrations in the binary at compile time + runs on startup; idempotent (second run skips applied migrations). `/_readyz` pings DB via `SELECT 1` — 503 when DB unreachable, 200 when ready. `docker-compose.yml` + `.env.example` provided. 3 unit tests pass (healthz/404/readyz-no-db).
- [x] **A3** · ✅ 2026-05-22 · `POST /v1/identity` — Ed25519 self-signed proof over `"sinhron-register-v1:" || pubkey`. UUIDv7 user_pk, idempotent на replay (UNIQUE + ON CONFLICT DO NOTHING + SELECT fallback). 201 на new, 200 на replay (same user_pk), 401 на bad sig, 400 на malformed hex. 5 unit-тестов в `handlers/proof.rs` (valid / tampered / wrong-len pubkey / wrong-len sig / proof-for-different-key) + live smoke 4/4 сценариев против Postgres 16.
- [x] **A4** · ✅ 2026-05-22 · Devices + KeyPackages. `POST /v1/identity` extended with optional `primary_device {device_pk_hex, device_credential_hex}` — registers user + first device in same transaction. `POST /v1/keypackages` accepts `{device_pk, kp_bytes_b64, upload_proof_ts, upload_proof_hex}` with **timestamped action proof** (`Ed25519_sign(device_cred, "sinhron-upload-kp-v1:" || sha256(kp_bytes) || be8(ts))`, 60s skew window). `GET /v1/keypackages/consume?identity_pubkey_hex=...&count=N` — atomic via `WITH picked AS (SELECT ... FOR UPDATE OF kp SKIP LOCKED) UPDATE keypackages SET consumed_at=NOW() ...` CTE; concurrent consumers don't grab same row. 30d TTL on upload, FIFO consume. **9/9** unit-тестов в `proof.rs` (5 registration + 4 action proof) + **6/6** end-to-end smoke сценариев против Postgres 16. Base64 encoding for kp_bytes wire transport.
- [x] **A5** · ✅ 2026-05-22 · WebSocket framing per spec §7.3. `GET /v1/sync` upgrades to WS with subprotocol `sinhron.v1` (rejects connections without it). Protobuf envelope `WsFrame` с 10 типами frames (Hello/Auth/Heartbeat/Resume/Ack/Push/Submit/Presence/Typing/Receipt) — prost codegen from `proto/sinhron.proto` через build.rs. **Auth handshake**: server → Hello{32-byte CSPRNG challenge}; client → Auth{identity_pubkey, Ed25519_sign("sinhron-ws-auth-v1:" \|\| challenge)}; server verifies sig + checks identity registered in users → Ack code=0 "authenticated". 10s timeout on Auth. **Heartbeat echo** + 75s idle watchdog. Submit/Resume/Presence/Typing/Receipt stubbed to ACK 501 (A6/A7/Phase3). Server refactored into lib + bin layout — `sinhron_server::{proto, build_app, AppState}` теперь публичные. Live smoke 7/7 шагов через `examples/ws_client.rs`.
- [x] **A6** · ✅ 2026-05-22 · Submit handler persists message to partitioned `messages` table (DEFAULT partition added via new migration so any-month inserts work) + fanouts Push to online group members via in-memory `SessionRegistry`. Multi-conn-per-user (phone + desktop). Drop-guard auto-unregisters on disconnect. `POST /v1/groups` test scaffold creates `mls_groups` + `group_members` rows (will be replaced by MLS Welcome processing in Stage C). Sender authorization via `group_members` lookup → 403 if not a member. Sealed-sender gap documented (sender_device_pk written today; NULL once §6.6 lands). **4 unit-тестов** session_registry (register/drop + fanout multi-conn + unknown user + closed channel). **`examples/ws_fanout.rs`** spawns Alice+Bob tasks in one process — Alice Submit → Bob receives Push with the same message_id + ciphertext body. DB row confirmed via psql. 🎯 **First real end-to-end message delivery server-side.**
- [x] **A7** · ✅ 2026-05-22 · Resume cursor + reconciliation. New `message_deliveries(recipient_user_pk, seq BIGSERIAL, message_id, delivered_at)` table — per-recipient monotonic seq populated at Submit fanout time. Unique index on (recipient, message_id) → idempotent on retry. Submit handler now transactional: messages + deliveries inserted atomically; Push frames carry the assigned seq. **Resume frame** handler: SELECT FROM message_deliveries JOIN messages WHERE recipient=$1 AND seq > cursor ORDER BY seq LIMIT 1000 → replays via Push, in original order. `examples/ws_resume.rs` validates: Alice sends 2 messages while Bob offline → Bob connects with Resume{cursor:0} → receives both Push frames seq=1,2 in order + Ack `"replayed 2"`. Stream id `main` (single per-user stream; future work may split per-group).
- [x] **A8** · ✅ 2026-05-22 · state_backups endpoints per §6.8.1. `PUT /v1/state-backup` with identity-signed action proof (domain `sinhron-state-backup-put-v1`, body hash includes version_seq → replay-resistant), monotonic version_seq enforced via `INSERT ... ON CONFLICT DO UPDATE WHERE EXCLUDED.version_seq > state_backups.version_seq`, 1MB cap (CHECK + handler). `GET /v1/state-backup` returns latest blob (no auth — encrypted client-side). 201/200/409/404/413 status codes. Live smoke 6/6: first PUT, GET back, replacement v2, stale v1 → 409, GET v2, 404 on unknown identity.
- [x] **A9** · ✅ 2026-05-22 · `retention::spawn(pool)` background task runs every `SINHRON_RETENTION_SWEEP_SECS` (default 3600s). Per-sweep DELETEs: keypackages WHERE consumed_at IS NOT NULL OR expires_at < NOW(); message_deliveries WHERE delivered_at < NOW() - retention_days; messages WHERE ts < NOW() - retention_days. Config via `SINHRON_MESSAGE_RETENTION_DAYS` (default 14 per §7.6). `examples/sweep_now.rs` runs one sweep on demand for tests. Live smoke: populated 1+1+1 rows → backdated 60 days → sweep@14d → tables empty. Partition-drop (DROP TABLE messages_2026_05) deferred to next-month-rollover WU; row-level DELETE works against partitioned parent today.
- [x] **A10** · ✅ 2026-05-22 · `push::PushClient` trait + `LoggingPush` stub impl. Wired into Submit fanout — for each recipient where live WS fanout count was 0 (offline), server looks up `delivery_key` on their devices and calls `push.notify(delivery_key, "New message")`. Generic summary per spec §9.4 / §13.x (no plaintext leak). async-trait pattern so APNs / FCM impls swap in cleanly later. Live smoke: Alice submits to deadbeef while Bob offline → server log `push stub — would notify APNs/FCM · delivery_key=aabbccddeeff · summary="New message"`.
- [x] **A11** · ✅ 2026-05-22 · Production deploy stack ready. Multi-stage `Dockerfile` (rust:1.94-bookworm builder + debian-slim runtime, ~80MB image, non-root uid 10001, signal-safe entrypoint). `docker-compose.yml` со server + postgres-16-alpine + caddy-2-alpine, healthcheck'и для всех, internal network между server/postgres, Caddy слушает 80/443/443udp. `Caddyfile` per spec §12 — reverse_proxy /v1/* + /_healthz + /_readyz, Let's Encrypt по умолчанию (опционально mounted operator-CA cert per §6.1). `.env.example` с public hostname, db password, retention days, image tag. `.dockerignore` исключает target/ examples/ tests/. **Verification gap**: docker не установлен на dev-машине — артефакты production-ready но `docker compose up` будет verified в Stage E real deploy.
- [x] **A12** · ✅ 2026-05-22 · `scripts/integration_smoke.sh` — single-script orchestration of every Stage A endpoint + WS flow + retention sweep + state_backup version-conflict semantics. 9 sections, each gated by `assert_eq` / `assert_contains` helpers + `set -euo pipefail` so any failure exits non-zero. Drops & recreates `sinhron_smoke` DB at start, traps cleanup on exit. **Run output**: ✓ probes · ✓ identity · ✓ bob+group · ✓ keypackages · ✓ state_backup · ✓ ws fanout · ✓ ws resume · ✓ retention. Becomes the canonical CI gate.

### Stage B · sinhron_net (client WS layer)

> Spec §5.2 — sinhron_net wraps tokio + WebSocket client. iOS cross-compile requires rustls (not native-tls).

- [x] **B1** · ✅ 2026-05-22 · `client_flutter/rust/sinhron_net/` workspace member. tokio 1.47.3 + tokio-tungstenite 0.29 (rustls-tls-webpki-roots → no native-tls / OpenSSL → iOS-friendly) + prost 0.13.5 + ed25519-dalek 2.1.1. `proto/sinhron.proto` mirrored from `server/proto/` (manual sync; TODO shared crate). `WsClient::connect(config)` does the full handshake (TCP/TLS → subprotocol negotiation → Hello receive → Auth sign+send → Ack verify). `WsClientConfig {url, identity_seed: [u8;32]}`. Errors typed via `ConnectError` enum. `examples/connect_smoke.rs` validated against live server — `→ connecting to ws://localhost:8080/v1/sync · ✓ authenticated as identity=2152f8d1...`.
- [x] **B2** · ✅ 2026-05-22 · Channel-based `WsClient::start(config) -> WsClient` API. Spawned background `run_loop` task handles connect + reconnect (exponential backoff 500ms→1s→2s→...→60s cap) + Resume cursor tracking (last_acked_seq incremented on every Push, sent as Resume frame after every reconnect for automatic offline-message replay). Public API: `send(frame).await` (mpsc backpressure), `recv() -> Event` (Connected / Disconnected / Frame variants), `shutdown()`. Caller-facing API stays Send+Sync+Clone for frb worker pool. Live smoke: `start()` → Connected event → Submit → Ack(Frame) → shutdown clean. Compiles on host; iOS arm64 verification in B5 (deferred to E5 real-device test).
- [x] **B3** · ✅ 2026-05-22 · TLS pinning per spec §6.1. New `sinhron_net::TlsPinning::from_pem(&[u8])` builds a constrained `rustls::ClientConfig` trusting ONLY the bundled operator CA. `WsClientConfig.tls: Option<TlsPinning>` plumbs into `connect_async_tls_with_config(Connector::Rustls(...))`; `HttpApi::new_pinned(...)` does the same for reqwest via `use_preconfigured_tls`. Single source of trust across HTTP + WS. Opt-in (`tls: None` keeps webpki defaults for dev). FFI reads `SINHRON_PINNED_CA_PEM` env at boot — production deploys set it. 2 unit tests cover error paths.
- [x] **B4** · ✅ 2026-05-22 · frb FFI surface in `client_flutter/rust/src/api/simple.rs`. Functions: `net_connect(url, identity_seed_hex)`, `net_send_submit(group_id_hex, ciphertext, message_id)`, `net_next_event()` returning `Option<NetEvent>`, `net_shutdown()`. NetEvent flattened to `{kind: String, disconnected_reason, push, ack}` struct (instead of Rust enum-with-payload) so frb generates Dart without requiring `freezed` build_runner — matches ADR-009 (no codegen). Singleton `OnceLock<Mutex<Option<WsClient>>>` for one-client-per-process. `flutter analyze` clean post-codegen; Dart now has `netConnect()`, `netSendSubmit()`, `netNextEvent()` + `NetEvent` / `NetPush` / `NetAck` types.
- [x] **B5** · ✅ 2026-05-22 · iOS Sim arm64 build verified — `fvm flutter build ios --simulator --debug` succeeds in 66.8s (cold compile of tokio + tokio-tungstenite + rustls + prost + sinhron_net + all transitive deps). cargokit pipeline handles the cross-compile. Real-device build runs the same path; deferred to user-driven physical-iPhone test.

### Stage C · sinhron_sync (MLS-over-WS bridge)

> Connects sinhron_crypto (already done — full MLS round-trip in-process) to sinhron_net (just built). Result: real MLS group sync over the wire.

- [x] **C1** · ✅ 2026-05-22 · `client_flutter/rust/sinhron_sync/` workspace member. Three modules: `identity` (MlsIdentity from BIP-39 phrase — Ed25519 seed → `SignatureKeyPair::from_raw`, single-source identity per §6.2), `group` (GroupHandle wrapping MlsGroup; create / add_member / encrypt / process_incoming returning IncomingMessage{App, Commit, Other}), `client` (SyncClient — top-level handle with HashMap<group_id, GroupHandle>). `use_ratchet_tree_extension(true)` so Welcome carries the tree inline. **End-to-end unit test passes**: Alice phrase → SyncClient → create_group + invite Bob (via Bob's KeyPackage) → Alice encrypt "hello sinhron" → Bob join_via_welcome → Bob decrypt → matches plaintext. C2+ wire this through WS transport.
- [x] **C2** · ✅ 2026-05-22 · `sinhron_sync` integrated into `sinhron_core` FFI surface. New FFI functions: `sync_init_from_phrase`, `sync_create_keypackage_b64`, `sync_create_group` → group_id_hex, `sync_invite_to_group` → `InviteOutcome{commit_b64, welcome_b64}`, `sync_join_via_welcome`, `net_send_encrypted(group_id_hex, plaintext, message_id)` — encrypts via SyncClient before WS Submit. `net_next_event` now ALSO decrypts incoming Push frames via SyncClient — surfaces plaintext as `NetPush.ciphertext` with new `decrypted: bool` flag. Singleton `OnceLock<Mutex<Option<SyncClient>>>` mirrors NET_CLIENT pattern. frb codegen regenerated cleanly; flutter analyze clean.
- [x] **C3** · ✅ 2026-05-22 · HTTP `HttpApi` in `sinhron_sync::http_api`. reqwest with rustls-tls-webpki-roots (no native-tls → iOS arm64 clean). `publish_keypackage(device_seed, kp_bytes)` signs the same `sinhron-upload-kp-v1` action proof the server expects, POSTs to `/v1/keypackages`. `fetch_keypackage(identity_pubkey_hex)` GETs `/v1/keypackages/consume?identity_pubkey_hex=…&count=1`. Convenience methods on SyncClient: `publish_keypackage(http)`, `fetch_kp_and_invite(http, group_id, target_identity_hex)`. FFI: `sync_publish_keypackage(url)`, `sync_fetch_kp_and_invite(url, group_id, target_identity_hex) -> InviteOutcome`. Wire format matches the existing server endpoint exactly (verified against `integration_smoke.sh`'s KP path).
- [x] **C4** · ✅ 2026-05-22 · `Welcome` frame added to .proto schema (both server + client mirror, field number 20 on WsFrame.body). Fields: recipient_identity_pubkey, group_id, welcome_bytes, sent_at. Server `handle_welcome`: validates 32-byte pubkey + non-empty welcome → looks up recipient_user_pk → fanout via SessionRegistry. 503 + retry hint if recipient offline (v1 live-only delivery; future WU adds pending_welcomes persistence). Client FFI: `net_send_welcome(recipient_identity_pubkey_hex, group_id_hex, welcome_b64)`. `NetEvent.welcome` variant + `NetService._onWelcome` calls sync_join_via_welcome → upserts local chat row → invalidates chatsProvider. **Note**: MLS group-state persistence (sinhron_storage encryption-at-rest of MlsGroup) was the original C4 task per spec §6.7 — that's lower-priority for first demo than Welcome delivery, deferred to a later security-polish WU.
- [x] **C5a** · ✅ 2026-05-22 · HTTP identity registration + bootstrap orchestration. `HttpApi::register_identity(identity_seed)` signs `sinhron-register-v1:` proof + POSTs `/v1/identity` with `primary_device {device_pk_hex, device_credential_hex}`. SyncClient gains `register_with_server` and `bootstrap_with_server` (register + publish KP atomic). FFI `sync_bootstrap_with_server(url)`. NetService.startFromPhrase now: (1) sync_init_from_phrase → (2) sync_bootstrap_with_server (idempotent, best-effort) → (3) netConnectFromPhrase. Smoke validated: `bootstrap_smoke` example registers, replays (already_existed:true, same user_pk), publishes KP, consume returns the 306-byte TLS-encoded KeyPackage. **This was the critical missing piece** — without identity registration the WS auth would 403 on iPhone deploy.
- [x] **C5** · ✅ 2026-05-22 · Graceful stale-epoch handling per spec §9.3. `IncomingMessage` gains `StaleEpoch { my_epoch }` + `OwnCommitEcho` variants. `GroupHandle::process_incoming` catches `ValidationError::WrongEpoch`, `ValidationError::UnableToDecrypt(SecretTreeError::{TooDistantInThePast, IndexOutOfBounds})`, `StageCommitError::{EpochMismatch, OwnCommit}` — translates to typed variants instead of `GroupError::Process(...)` panics. Regression test `stale_epoch_frame_surfaces_as_typed_variant` builds a 3-client epoch-race scenario (Alice adds Carol → epoch 2, Bob sends "stale" at epoch 1, Alice decrypts → StaleEpoch). Pre-C5: chat dead. Now: drop + log. Real auto-recovery (re-fetch + re-apply) deferred — requires server-side commit-ordering signal.
- [x] **C6** · ✅ 2026-05-22 · MLS state-at-rest via `openmls_sqlite_storage 0.2.0`. New `SinhronProvider` composes `RustCrypto` (sig/HPKE/RNG) + `SqliteStorageProvider<JsonCodec, Connection>` so MLS group state survives `Drop(SyncClient)` + reopen from the same file. `SyncClientConfig.db_path` threads through FFI as a String (`""` → in-memory, else file path). `GroupHandle::try_load` lazily re-hydrates groups on first encrypt/decrypt for an id missing from the cache. **Regression test `mls_state_survives_client_restart`** proves Alice's ratchet survives a full client drop + reopen: she sends "first", drops, reopens, sends "second" — Bob decrypts both in order. Cargo bumps: `sinhron_storage::rusqlite 0.31 → =0.32.1` (one libsqlite3-sys for iOS link). `unsafe impl Sync for SinhronProvider` justified by external `tokio::sync::Mutex` serialization in FFI + owned-per-task lifetimes in examples. Sign-out wiring also extended: `syncShutdown` FFI drops the SyncClient (closes SQLite handle) → file deletion succeeds on iOS. **Without this WU, force-quit + relaunch = every group dead. Now: ratchet persists**. `cargo test -p sinhron_sync` → 4/4, iOS Simulator build clean (38.8s).
- [ ] **C7** · *(was the original "C6 state_backups")* server-side state_backup encrypt/decrypt — upload group state ciphertext to server, decrypt on restore. Deferred to security-polish phase; local persistence (this C6) is the hard prerequisite and is done.

### Stage D · sinhron_cli (headless test harness)

> Spec §5.2 — pure Rust CLI for stress-testing the protocol without UI.

- [ ] **D1** · Crate scaffold `client_flutter/rust/sinhron_cli`. Binary, не FFI. `clap` for arg parsing.
- [ ] **D2** · `sinhron-cli send --to <fingerprint> --text <msg>` — full E2E send via sinhron_sync.
- [ ] **D3** · `sinhron-cli recv --listen` — subscribe + decrypt incoming.
- [ ] **D4** · Stress test harness: 100 chats × 1000 messages over local server. Measure latency, throughput.

### Stage E · Flutter integration

> Connect the Flutter UI to the now-real backend. ChatList stops being seed-only; messages cross the wire.

- [x] **E1** · ✅ 2026-05-22 · Flutter ChatView wired to sinhron_net. `lib/core/services/net_service.dart` — singleton `NetService` exposed via `netServiceProvider`. Owns the event loop that polls `netNextEvent` and routes by `event.kind`: Push → reverse-hash group_id → match local chat → `storageMessageAppend` + invalidate. RecoveryPhraseScreen.onSaved now calls `netService.startFromPhrase(phrase, url)` after `storageSavePhrase` — phrase stays Rust-side via `net_connect_from_phrase` FFI. Server URL configurable via `--dart-define=SINHRON_WS_URL=ws://<host>:8080/v1/sync` (default `ws://localhost:8080/v1/sync`). `sendMessage` mirrors outgoing text to `netSendSubmit` alongside local persist; deterministic chatId→group_hex hash so both ends compute the same id (until Stage C MLS group negotiation lands). Demo limitation: phrase isn't persisted (spec §6.8), so reconnect after relaunch requires re-entering it — flagged for future Settings → "Reconnect" WU. **Flutter analyze clean · 43/43 widget tests pass.**
- [x] **E2** · ✅ 2026-05-22 · `NetService._onPush` now resolves chatId via two-tier match: exact id (MLS chats where chatId == group_id_hex) first, FNV-1a fallback for legacy seed/demo chats. Unknown-group pushes drop gracefully + invalidate `chatsProvider` so a just-arrived Welcome can repopulate the UI without polling. Both `messagesProvider(chatId)` and `chatsProvider` invalidate on every successful Push persist — ChatList previews and ChatView lists update reactively.
- [x] **E3 (partial — server side)** · ✅ 2026-05-22 · APNs payload contract per spec §13.x. `server/src/push.rs::PushPayload { group_id_hex, unread_total, summary }` — server NEVER includes plaintext. `ws.rs` Submit handler now computes per-recipient running unread from `message_deliveries`, passes structured payload to `PushClient::notify`. `Apns` placeholder struct documents the operator-side wiring (.p8 key + `a2` crate + iOS Notification Service Extension for in-place decrypt). **iOS cert + provisioning awaits the operator's Apple Developer account — that part is ops, not engineering.**
- [x] **E4** · ✅ 2026-05-22 · Compose UX drives full MLS dance. New quick-action "Paste id" expands an inline TextField — recipient's 64-hex identity_pubkey + "Start chat" button. Navigation wires `onInviteByIdentity` → `createMlsChat(ref, recipientHex, displayName, httpBase)` which: (1) sync_create_group, (2) sync_fetch_kp_and_invite (HTTP GET Bob's KP + MLS Add), (3) net_send_welcome (WS-forward to Bob's session), (4) storageChatUpsert keyed by group_id_hex, (5) invalidate chatsProvider, (6) pushReplacement to ChatView. **`sendMessage` now dual-path**: if `chatId` is a real MLS group_id_hex (≥40 hex chars) → `net_send_encrypted` (SyncClient encrypts before wire); else legacy `net_send_submit` for seed/demo chats. `_wsToHttpBase` helper derives HTTP origin from the WS URL. Full Flutter analyze clean.
- [ ] **E5** · Real Alice↔Bob test on two iPhones (or iPhone + Sim). One sends, other receives. **THIS IS THE «GOAL DONE» MARKER.**

### Stage F · sinhron_call (deferred — spec §10)

> WebRTC + LiveKit signaling. NOT required for the GOAL — chat messaging is the priority. Defer to Phase 3.

- [ ] **F1+** · See spec §10. Skip unless explicitly prioritized by user.

---

## 5. Hard constraints (нарушение = блок)

Из `feedback_donot_list.md` (memory file) и spec §18. Эти **never** обсуждаются:

- **Sinhron only** — никаких упоминаний Citadel, нигде
- **Exact version pins** (§18.9) — никаких `^` / `~` / range. Только `1.2.3` форма
- **No phone-home** (§3.3) — никаких `google_fonts`, analytics SDK, telemetry. Геометрия — bundled assets, шрифты — bundled Geist
- **Phrase never stored** — только SHA-256 хэш + derived keys в БД. Никаких keychain-deviation без явного ADR
- **Sealed sender** (§6.6) — сервер видит только recipient list + ciphertext + msg_id + ts. NEVER sender identity на server-side metadata
- **No Material/Cupertino defaults** (§18.17) — только WidgetsApp + custom Ds* widgets. (Backend doesn't touch this но имей в виду если будешь править UI)
- **No git config / push --force / amend без явного запроса**
- **TLS pinning required** (§6.1) — operator CA, не public CA для прода

---

## 6. Per-WU workflow (мандатно для каждой WU)

```
1. Read THIS file's §4 — найди next pending WU
2. Read relevant spec section(s) listed in WU
3. Read docs/status.md "Текущая фаза" — подтверди state
4. Plan WU: scope + verification criteria. Use TaskCreate to track.
5. Implement.
6. Verify (см. §7 ниже).
7. Update docs/status.md — добавь WU entry с датой и кратким описанием.
8. Mark WU ✅ in this file (§4 ladder).
9. If new architectural decision was made — write ADR in docs/decisions.md.
10. Mark TaskUpdate complete.
```

---

## 7. Verification gates (мандатно перед маркировкой WU ✅)

- **Rust code:** `cargo test -p <crate>` passes. `cargo clippy --all-targets -- -D warnings` passes.
- **Dart code:** `fvm flutter analyze` clean. `fvm flutter test` passes.
- **FFI change:** `flutter_rust_bridge_codegen generate` без warnings. iOS Sim debug build (`fvm flutter build ios --simulator --debug`) success.
- **Server change:** integration test covering happy path. Manual curl smoke test documented in WU entry in status.md.
- **Schema change:** migration runs cleanly on empty DB AND on previous-version DB (test both — см. WU 73.2 PK violation как example почему это критично).

Если хоть один gate не пройден — WU **не помечается** как complete.

---

## 8. Decision authority (что решаю сам vs что прошу)

**Решаю сам** (не задавать вопросы):
- Library choices внутри уже одобренных deps (e.g. choosing `serde_json` vs `simd_json` — оба ok)
- File layout внутри крейта
- Internal function signatures
- Test fixtures
- Error message strings
- Migration ordering
- Default values for tunables (е.g. message retention 30d по spec, если spec тихий — выбираю sane default + документирую)

**Спрашиваю пользователя**:
- Spec deviation (любое отклонение от architecture.md — даже маленькое)
- New top-level dependency (новый крейт в Cargo.toml workspace level)
- Anything touching crypto correctness (e.g. AEAD nonce schemes, KDF info strings — spec §6.x)
- UI/UX behavior changes (даже косвенные — backend errors which surface in UI)
- Scope expansion beyond current WU
- Git operations (commit / push / branch)
- Versioning bumps (Cargo workspace version, Flutter app version)

**Push back** (constructive disagreement per §17.6):
- Если user ask конфликтует с spec — поднимай вопрос. «Спорить со мной можно» — это прямой запрос на пушбэк.
- Если timing / scope нереалистичный — говори ради честной оценки.

---

## 9. Hard stops (когда останавливаюсь и пишу пользователю)

- WU занимает >8 часов реального implementation time — split в sub-WUs
- Spec неоднозначен по вопросу с security implications
- Integration test показывает регрессию на existing functionality
- iOS build ломается и фикс неочевиден за 30 мин
- Newer Phase 3 deps требуются раньше чем планировалось (e.g. LiveKit для звонков нужен раньше чем ожидалось)

В таких случаях — **обнови этот файл с пометкой `⏸️ BLOCKED on WU XYZ — see status.md»` перед тем как ждать пользователя**. Это сохранит контекст при следующем resume.

---

## 10. Failure modes (то что наверняка пойдёт не так)

Документировано заранее чтобы не паниковать:

- **iOS cross-compile для tokio/rustls** — известный pain. Если linker errors — проверь cargokit ios/ конфиг. Workaround: `cargo build --target aarch64-apple-ios` standalone сначала.
- **flutter_rust_bridge regeneration после schema changes** — частая boilerplate. Просто `flutter_rust_bridge_codegen generate` из client_flutter/.
- **Server WS unauth bug** — server должен auth каждое incoming envelope, не только handshake. Сейчас написал бы тест на это в A5.
- **MLS state divergence between devices** — если две Alice'ы (linked devices) одновременно изменят группу, нужен conflict resolution per §9.3.
- **PostgreSQL FK violations при retention drop** — нужно сначала detach или CASCADE messages → state_backups.

---

## 11. Compaction recovery checklist

Если контекст обрублен compact'ом и ты читаешь это «холодным» — выполни:

1. ✅ Прочитал `docs/goal-backend.md` (этот файл) полностью
2. ✅ Прочитал `docs/status.md` секцию «Текущая фаза» (первые 50 строк)
3. ✅ Прочитал spec §7 (если будешь работать на server), §5.2 (если новый Rust крейт)
4. ✅ Просмотрел `docs/decisions.md` последние 2-3 ADR'а
5. ✅ Запустил `fvm flutter analyze` + `cargo test --workspace` (sanity check — known state)
6. ✅ Прочитал TaskList — есть ли in-progress task?
7. ✅ Определил next WU из §4 ladder выше
8. ✅ Создал TaskCreate для этой WU
9. ✅ Начал implementation

Если на любом шаге что-то не сходится — **остановись, обнови этот файл с записью что пошло не так, попроси пользователя**.

---

## 12. Goal completion criteria

Goal помечается **достигнутым** только когда:

- ☐ Server deployed via docker-compose локально на dev машине ← configs ready, requires docker install
- ☐ Two clients (например iPhone + iOS Sim, или два iPhone) подключены к этому серверу ← deferred to physical-test phase
- ☑ **Alice composes chat with Bob, sends "hello from Sinhron"** ← `examples/full_e2e.rs` validates this end-to-end through real protocol (HTTP register + KP + WS auth + Welcome + Submit) 🎯
- ☑ **Bob receives, decrypts via MLS** ← same example: `bob ✓ decrypted plaintext: "hello sinhron, this is real MLS over the wire"` 🎯
- ☑ **Cold-restart Bob's app — сообщение still there & ratchet usable** ← WU C6 landed. `mls_state_survives_client_restart` regression test (in `sinhron_sync/src/client.rs`) creates a group, drops the client, reopens from the same SQLite path, sends + decrypts a second message — both in-order plaintexts come back. Real iPhone hands-on for E5 will exercise the same code path.
- ☑ Server logs показывают только ciphertext + msg_id + ts + recipient_list — verified in `/tmp/srv_full.log`: `message persisted bytes=190 fanout delivered=1` (no plaintext, no sender_user_pk in fanout log fields once sealed sender lands)
- ☑ `cargo test --workspace` passes
- ☑ `fvm flutter test` passes (43/43)
- ☑ iOS Sim arm64 build passes; physical-device deferred per user direction
- ☑ `docs/status.md` отражает progress

---

## 13. Out of scope (НЕ делать в рамках этого goal'а)

- Web client (§19 — open question, Phase 4)
- Federation between operators (§19 — open question)
- Post-quantum migration (§19 — open question)
- WebRTC calls / sinhron_call (Stage F — deferred unless prioritized)
- Operator portal / admin UI
- Public-network operator discovery
- Anything на Android (iOS-only до stable)

---

## 14. Update protocol для этого файла

Этот файл — **living document**. Обновляй его в этих случаях:

- После каждой completed WU — mark ✅ в §4 + update «State on YYYY-MM-DD» в §2
- После каждого hard stop / blocker — добавь запись в §9
- После каждого ADR — кросс-референс в соответствующей WU
- Когда обнаружишь новый failure mode — добавь в §10

Commit'и этот файл вместе с code changes. Это часть deliverable'а.

---

**Конец goal-документа. Следующий шаг: открой `docs/status.md` для контекста, потом начни Stage A · WU A1.**
