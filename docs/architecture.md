# Sinhron · architecture deep-dive

> **Назначение.** Полное описание архитектуры текущего состояния. Что есть, как куски связаны, какой data flow. Это **не** спека (спека — `design_handoff_sinhron/spec/architecture.md`). Это README текущего кода с детализацией.
>
> **Когда обновлять:** при добавлении нового компонента / endpoint / data path. Точечные правки existing кода не требуют update.
>
> <!-- SYNCED FROM PROJECT.md §4 --> **Tech stack versions** упомянутые ниже (dependency tree, spec compliance table) — synced from [`PROJECT.md` §4](PROJECT.md#4-tech-stack-pin-точные-версии). Source of truth — там. При version bump обновляй PROJECT.md §4 + сюда параллельно.

---

## 1. Total system view

```
┌────────────────────────────────────────────────────────────────────────────┐
│                          USER'S iPhone (Sim или real)                       │
│                                                                              │
│   ┌────────────────────────────────────────────────────────────────────┐    │
│   │                       Flutter app (Dart)                            │    │
│   │  ┌──────────────┐    ┌────────────┐    ┌────────────────────────┐  │    │
│   │  │ UI screens   │ → │ Providers  │ → │ NetService event loop  │  │    │
│   │  │ 45 features  │    │ (Riverpod) │    │ (sync_init/start/recv) │  │    │
│   │  │ 18 ds widgets│    │            │    │                        │  │    │
│   │  └──────────────┘    └────────────┘    └─────────┬──────────────┘  │    │
│   │                                                    │ FFI            │    │
│   │                              flutter_rust_bridge 2.11.1            │    │
│   └────────────────────────────────────┼──────────────────────────────┘    │
│                                          │                                   │
│   ┌──────────────────────────────────────▼──────────────────────────────┐  │
│   │                       Rust client (sinhron_core cdylib)              │  │
│   │  ┌─────────────────────────────────────────────────────────────┐    │  │
│   │  │  src/api/simple.rs — FFI surface                            │    │  │
│   │  │   ┌──────────┐ ┌─────────┐ ┌─────────┐ ┌─────────────────┐  │    │  │
│   │  │   │ storage_*│ │ sync_*  │ │ net_*   │ │ identity / mls  │  │    │  │
│   │  │   │  (chats) │ │  (MLS)  │ │  (WS)   │ │  (crypto)       │  │    │  │
│   │  │   └─────┬────┘ └────┬────┘ └────┬────┘ └────────┬────────┘  │    │  │
│   │  └────────┼────────────┼────────────┼─────────────────┼─────────┘    │  │
│   │           ▼            ▼            ▼                ▼               │  │
│   │      sinhron_   sinhron_   sinhron_           sinhron_              │  │
│   │      storage    sync       net                crypto                │  │
│   │      (SQLCi-    (MLS-      (WS+TLS-           (BIP-39+              │  │
│   │       pher)     bridge)    pinning)           HKDF+MLS)             │  │
│   │       ↑              ↑              ↑                                │  │
│   │       │ uses         │ uses         │ uses                           │  │
│   │       └──────────────┴──────────────┘                                │  │
│   │             всё вверху ↑                                              │  │
│   │                                                                       │  │
│   │  Persistent local state:                                              │  │
│   │   • sinhron.db       (chats, messages — SQLCipher when keyed)         │  │
│   │   • sinhron-mls.sqlite (MLS group state — SQLCipher always)           │  │
│   │   • OS Keychain      (phrase — TODO; currently RAM-only)              │  │
│   └────────────────────────────────────┬──────────────────────────────────┘  │
└────────────────────────────────────────┼──────────────────────────────────────┘
                                          │
                            HTTPS (POST /v1/*) + WSS (/v1/sync)
                            ──────────────────────────────────
                            TLS 1.3 via rustls. Optional pinning.
                            Webpki-roots default; bundled CA opt-in.
                                          │
┌────────────────────────────────────────┼──────────────────────────────────────┐
│                        Operator's VM (Hetzner / DO / AWS)                     │
│                                          │                                    │
│   ┌──────────────────────────────────────▼────────────────────────────────┐  │
│   │                        Caddy 2.x (TLS termination)                    │  │
│   │                     /v1/* → reverse_proxy sinhron-app:8080            │  │
│   │                     Auto Let's Encrypt                                │  │
│   └──────────────────────────────────────┬────────────────────────────────┘  │
│                                          │                                    │
│   ┌──────────────────────────────────────▼────────────────────────────────┐  │
│   │                       sinhron-server (Rust + Axum)                    │  │
│   │  ┌──────────────────────────────────────────────────────────────┐    │  │
│   │  │  build_app(state)                                            │    │  │
│   │  │   ├── /_healthz, /_readyz                                    │    │  │
│   │  │   ├── POST /v1/identity      (handlers::identity::register)  │    │  │
│   │  │   ├── POST /v1/keypackages   (handlers::keypackages::upload) │    │  │
│   │  │   ├── GET  /v1/keypackages/consume                           │    │  │
│   │  │   ├── GET  /v1/keypackages/available (у кого их нет)         │    │  │
│   │  │   ├── POST /v1/groups        (handlers::groups::create)      │    │  │
│   │  │   └── GET  /v1/sync          (ws::ws_upgrade — WebSocket)    │    │  │
│   │  └────────┬────────────────────┬─────────────────────┬──────────┘    │  │
│   │           │                    │                     │                │  │
│   │     ┌─────▼────┐         ┌─────▼─────┐         ┌─────▼─────┐         │  │
│   │     │ Session  │         │  Push     │         │ Rate      │         │  │
│   │     │ Registry │         │  Client   │         │ Limiter   │         │  │
│   │     │ (in-mem) │         │  (Logging │         │ (token    │         │  │
│   │     │          │         │   stub /  │         │  bucket)  │         │  │
│   │     │          │         │   Apns)   │         │           │         │  │
│   │     └──────────┘         └───────────┘         └───────────┘         │  │
│   │                                                                       │  │
│   │                    ┌─────────────┐                                    │  │
│   │                    │  Retention  │  every SINHRON_RETENTION_SWEEP_SECS│  │
│   │                    │  worker     │  ─ drops old keypackages /         │  │
│   │                    │             │    messages / deliveries /         │  │
│   │                    │             │    pending_welcomes / disappearing │  │
│   │                    └─────────────┘                                    │  │
│   │                                                                       │  │
│   │   AppState: { pool, sessions, push, rate }                            │  │
│   └────────────────────────────────────┬──────────────────────────────────┘  │
│                                          │                                    │
│   ┌──────────────────────────────────────▼────────────────────────────────┐  │
│   │                        PostgreSQL 16-alpine                           │  │
│   │  Tables (14 migrations; full list — code-map.md):                     │  │
│   │   • users(user_pk, identity_pubkey, …)                                │  │
│   │   • devices(device_pk, user_pk, delivery_key, …)                      │  │
│   │   • keypackages(keypackage_id, device_pk, kp_bytes, …)                │  │
│   │   • groups(group_id, creator_user_pk, epoch, disappearing_after_secs) │  │
│   │   • group_members(group_id, device_pk)                                │  │
│   │   • messages(message_id, group_id, sender_device_pk, ciphertext, ts)  │  │
│   │            partitioned by RANGE(ts) per month                         │  │
│   │   • message_deliveries(recipient_user_pk, seq, message_id, delivered) │  │
│   │   • pending_welcomes(recipient_user_pk, group_id, welcome_bytes,      │  │
│   │                       enqueued_at, expires_at)                        │  │
│   │   • media (per-spec, not yet written)                                 │  │
│   │   • retention_state (per-spec, not yet written)                       │  │
│   └────────────────────────────────────────────────────────────────────────┘  │
│                                                                                │
│   docker-compose: caddy + sinhron-app + postgres + livekit + coturn (5 svc)   │
└────────────────────────────────────────────────────────────────────────────────┘
```

**Neighbour sites on the same VM (status 203).** Caddy owns 80/443; other projects on the server (e.g. another project, its own compose project) are served by it too: the Caddyfile ends with `import /etc/caddy/sites/*.caddy` (host folder `/etc/sinhron/caddy-sites`, read-only; empty = no change), and Caddy joins the external Docker network `edge` (created by `install.sh`), where neighbours attach their web containers. Neighbour site blocks land on the same `:8443` HTTP app behind layer4 (only the TURN SNI is split off) and get certificates via HTTP-01 like ours. They don't get `(security_headers)` — their headers are their job. Sinhron's own containers stay on `default`/`egress6`, unreachable from `edge` except Caddy. Runbook: deploy-guide §4.1.

---

## 2. Layer responsibilities

### 2.1. Flutter app (Dart)

**Responsibility:** UI rendering + user input + delegating всё что не-UI к Rust FFI.

**Не делает:** crypto, network, persistence, MLS. Только UI + state derivation.

**State management:** Riverpod 3.x — без code generation (см. ADR-009). Providers в `lib/core/providers/`:
- `bootDiagnosticsProvider` — overridden from main.dart с реальным `BootDiagnostics` snapshot
- `coreVersionProvider` — Rust version string
- `identityProvider` — `FutureProvider<StoredIdentitySummary?>` через `core.storageLoadIdentity()`
- `identityFingerprintProvider` — derived from identityProvider
- `chatsProvider` — `FutureProvider<List<StoredChatSummary>>` через `core.storageChatsList()`
- `messagesProvider.family<List<StoredMessageSummary>, String>` — мессаги per chat id

- `chatsRefresherProvider` — обновление списка чатов от входящих событий: одно чтение за раз, события во время чтения складываются в одно повторное (tech-debt 2.20)
- `peerNamesProvider` / `blockedPeersProvider` (`people.dart`) — имена участников из действий `profile` и локальная блокировка (хранилище v9); поверх имён — мои имена для людей (`contactAliasesProvider`, настройка `contact_aliases`, только на этом устройстве, никуда не уходят); их же берёт название личного чата в `chatsProvider` и баннер о сообщении
- `contactsProvider` / `peerBiosProvider` (`people.dart`, ADR-052) — контакты (свой список, хранилище v15) и «О себе» из `profile` (видно в «Инфо» личного чата, в профиле из «Контактов» и из списка участников группы)

**Long-running service:** `NetService` (singleton via `netServiceProvider`). Owns:
- WS event loop (`_runEventLoop` calls `core.netNextEvent()` in loop)
- Routing of inbound Push / Welcome / Ack frames (действия ADR-019, `profile`, `pin` → `MessageActions.onIncomingAction`; всё от заблокированного отправителя отбрасывается здесь)
- `startFromPhrase(phrase, url)` — bootstrap entire networking stack

**UI conventions:**
- 18 `Ds*` widgets в `lib/widgets/` — design system primitives
- 34 feature dirs в `lib/features/<name>/` — каждая = одна логическая фича
- Все routes из `lib/app/navigation.dart::AppRoot` — `_wireXxxBuilder()` pattern для DI
- ADR-076 — на iPad (≥ 700×500 pt) каждая вкладка — `AdaptiveSplit` (`lib/app/adaptive.dart`): список слева, свой навигатор справа; звонки, фото, шторки и меню — в навигаторе приложения (`rootNavigator`), поверх обеих колонок
- Tokens из `lib/app/theme/ds_theme.dart` — colors / spacing / radii / motion

### 2.2. Rust client (через FFI)

**Responsibility:** всё что не UI — crypto, network, persistence.

**Crate boundaries:**

| Crate | Знает про | НЕ знает про |
|---|---|---|
| `sinhron_crypto` | BIP-39, HKDF, Ed25519, X25519, openmls types | tokio, network, storage |
| `sinhron_storage` | rusqlite, SQLCipher, chat/message schema | crypto details, network |
| `sinhron_net` | tokio-tungstenite, rustls, .proto, WS frames, server address (DNS check / DoH, ADR-072) | MLS, chats |
| `sinhron_sync` | openmls flow, HTTP wire (reqwest), state backup | UI, raw transport details |
| `sinhron_core` (FFI) | всех вышеперечисленных | UI, Dart |
| `sinhron_cli` | всех client crates (bypass FFI) | Flutter |

**Our server's address (ADR-072).** Every connection to our hosts (API / WS, media, push registration; from Dart — LiveKit signalling and the APK download via `HttpOverrides.global`, `lib/core/server_dns.dart`) gets its address from `sinhron_net::dns::global()`: the system answer if a TLS handshake to it shows our certificate for our name; else an address checked before; else DNS-over-HTTPS (1.1.1.1, then 8.8.8.8, by IP), checked the same way. Only the address changes — TLS still runs with SNI and the certificate check for our host name. Checked addresses persist in the encrypted `settings` table (`net_dns_cache`); a DoH / kept one is re-checked in the background and dropped back to the system answer once that is right again. WebRTC resolves TURN on its own: plain `turn:` URLs get a copy with the checked IP, `turns:` can't (SNI).

**Singletons (внутри sinhron_core/api/simple.rs):**
- `NET_CLIENT: OnceLock<Mutex<Option<WsClient>>>` — один WS clt per process
- `SYNC_CLIENT: OnceLock<Mutex<Option<SyncClient>>>` — один MLS clt
- `sinhron_storage::DB: OnceLock<Mutex<Connection>>` — один SQLite handle

**Crypto invariants (см. `sinhron_crypto::identity::DerivedIdentity`):**
- BIP-39 phrase → `phrase_to_seed_hex_internal` → HKDF
- HKDF outputs 4 sub-keys: `ed25519_secret` (identity), `x25519_secret` (HPKE), `backup_key` (state backup AEAD), `storage_key` (SQLCipher)
- Все 4 — domain-separated через unique HKDF `info` strings (`sinhron-id-ed25519/v1`, `sinhron-id-x25519/v1`, `sinhron-state-backup/v1`, `sinhron-storage-key/v1`)
- Test invariant: pairwise differ (`sub_keys_are_domain_separated`)

### 2.3. Server (Rust + Axum)

**Responsibility:** message persistence + fanout + identity registry + push triggering. **Никогда** не видит plaintext (см. `docs/threat-model.md` T3).

**HTTP endpoints:** см. диаграмму выше или `server/src/lib.rs::build_app`.

**WS protocol (per `proto/sinhron.proto`):**

```
Client                              Server
  │                                   │
  │ ──── WS upgrade ──── /v1/sync ──→ │
  │                                   │
  │ ←── Hello { challenge, time } ─── │  Phase 1: server says hi
  │                                   │
  │ ──── Auth { sig of challenge } ─→ │  Phase 2: client signs challenge
  │                                   │
  │ ←── Ack { code 0 } ──────────── ─ │  Phase 3: server accepts
  │                                   │
  │   [authenticated session]         │
  │                                   │
  │ ──── Submit { group_id, ct } ───→ │  ← send message
  │ ←── Ack { acked, code 0 } ─────── │  ← server confirms
  │                                   │  ← fanout to other members
  │ ←── Push { ct, seq, msg_id } ──── │  ← incoming
  │                                   │
  │ ──── Resume { cursors } ─────────→ │  ← reconnect with last seen seq
  │ ←── Push * (replay) ─────────── ─ │  ← server replays missed
  │                                   │
  │ ──── Welcome { ct, group_id, recipient_pubkey } ─→ │  ← MLS invite
  │ ←── Ack ──────────────────────── │  ← forwarded или queued
  │                                   │
  │ ──── Heartbeat{next_within_secs} → │  ← keepalive, every 20 s (Android in background: 120 s)
  │ ←── Heartbeat{next_within_secs} ─ │  ← echo + the gap the server accepted
```

**Background heartbeat (2026-10-18, status 151).** Every heartbeat wakes the phone's mobile radio (~10 s at high power), so an Android phone with "always connected" (ADR-040) off screen asks for a longer gap: `BackgroundConnection` calls `netSetBackground(true)` (only with "always connected", never during a call — and never on iOS, where a frozen app must look offline soon), the client sends `Heartbeat{next_within_secs: 120}`, the server answers with the gap it accepts (`granted_heartbeat_gap`, ≤ 300 s) and stretches that session's watchdog to gap + half of it (`session_idle_secs`: 120 → 180 s); the client switches to 120 s only after that reply, so against an older server (reply 0) it stays at 20 s. With the long gap a dead link is caught by `Keepalive::reply_timeout` (30 s without any frame after a heartbeat). On screen or when a call starts: 20 s again with a heartbeat at once, and the next heartbeat asks for 0 (the server's default watchdog). Android's default-network callback (`NetworkWatch.kt`, channel `dev.sinhron/network` → `netNetworkChanged`) drops the socket and reconnects at once, also cutting a reconnect back-off short. Caddy's `/v1/sync` route has `read_timeout 10m` (the rest of `/v1/*` keeps 90 s), since Caddy's read timeout is the longest silence it allows from the server on a socket. Not measured on a phone.

**Android self-update (ADR-058).** An APK install (not a store, not iOS, not a dev build, signed with our key) reads `<server>/download/android.json` 30 s after start, every 6 h and from Settings → About; a newer `build` than `SINHRON_BUILD` shows a banner over Chats. On "Update" Dart downloads the APK for this CPU at the same bitness into `cacheDir/updates/`, checks its SHA-256, and `AppUpdate.kt` (`dev.sinhron/update`) reads the file's package, version code and signing certificate — it must be `com.sinhron.sinhron`, newer, and signed by `kApkCertSha256` — before handing it to the system installer through `UpdateFileProvider` (one "Install" tap). `scripts/android_release.sh` writes the manifest, `scripts/publish_android.sh` uploads APKs first and the manifest last.

**Keepalive (2026-10-13, tech-debt 2.10).** The client sends `Heartbeat` every 20 s (30 s until 2026-10-16; `sinhron_net::Keepalive`); the server closes a session silent for 45 s (`SINHRON_WS_IDLE_TIMEOUT_SECS`, min 15; 75 s until 2026-10-16 — a frozen iOS app looked online that long and got no push). Since 2026-10-16 the app also closes its connection when it goes to background (`BackgroundConnectionKeeper`, not during a call) and reopens it on return, so the server pushes at once. The client in turn drops a connection where *nothing* came from the server for 45 s (75 s until 2026-10-16; half-open TCP after a network switch), or where a heartbeat got no frame back for 30 s, and reconnects. Until this fix the client sent no heartbeats at all, so every quiet session was cut and re-established every 75 s. `WsClient::shutdown` sets a stop flag checked before every reconnect — earlier the reconnect loop ignored it and each restart left a zombie connection behind.

**Sealed delivery (ADR-023).** If every recipient has published a current delivery key (`GET /v1/sealed-keys`), the client sends `SealedSubmit{message_id, [{key_id, HPKE envelope}]}` instead of `Submit`. The server maps `key_id → user`, stores the envelope on that user's `message_deliveries` row (no `messages` row, no group id) and pushes it with `Push.sealed_key_id`; the recipient opens it, decrypts MLS and authenticates the sender in one call (`SyncClient::open_sealed`, inside `net_next_event`). Otherwise the ordinary `Submit` is used. ADR-082: each published key carries its owner's signature (identity key, or device key + device certificate); the sender checks it and seals a notification preview only to a signed key — an unsigned one (old app, or a key the server swapped in) gets the envelope without a preview.

**Push with names, the server none the wiser (ADR-056).** For every *urgent* sealed delivery the sender also seals a 689-byte preview (kind, first 320 bytes of text, group id, time, Ed25519 signature by its device key + certificate) to the same delivery key with HPKE (ChaCha20-Poly1305, info `sinhron-push-preview-v1`) — `SealedDelivery.push_preview` / `push_preview_b64`. A recipient with no live connection gets an APNs push that carries it unread (`p`, `mutable-content`). On the iPhone the Notification Service Extension (`ios/NotificationService`, pure Swift + CryptoKit, no Rust or database) opens it with the delivery keys the app left in the shared Keychain group `com.sinhron.shared`, verifies the signature and writes “<chat>” / “<sender>: <text>” from the names the app keeps there (`notificationContextProvider`), as Settings → Notifications show says; blocked senders become a silent “New message”. A PushKit token registers a per-phone `call_hint_key`; call pushes carry `h` = HMAC(key, call id ‖ group id) so `CallKitBridge` names the chat before the app connects. *Calls (ADR-090, 2026-11-04):* the hint only finds the chat — the server holds its key. The caller signs its `CallInvite` (`caller_proof`: ts, Ed25519 by its device key, identity key or device certificate, over call id, chat id and kind); the server passes it on in the invite and, sealed to the phone's hint key (AES-256-GCM, one size), as `s` in the VoIP push. Rust names the caller only for a fresh valid proof by a member of the chat (otherwise the call doesn't ring); CallKit shows a name only for a valid `s` (the chat's name for its own person in a personal chat, else the signer's name), else "Sinhron".

**Share into Sinhron (ADR-060).** Other apps' share menus reach the app without any crypto outside it. Android: `ShareActivity` (SEND / SEND_MULTIPLE) forwards the `content://` URIs with their read grant to `MainActivity` and closes; `ShareBridge` (`Share.kt`) copies them into `cache/share/<id>/` (HEIC / WebP → JPEG; no `file://`, none of our own providers). iPhone: the Share Extension (`ios/ShareExtension`, pure Swift, no Rust / database / network) copies items into the App Group `group.com.sinhron.sinhron` (`Share/<id>/share.json`) and opens `sinhron://share?id=…`; `Runner/ShareBridge.swift` hands it over. Both use channel `dev.sinhron/share` → `IncomingShareListener` → `handleIncomingShare` → the “Send to…” picker (`features/share_into`), which sends through the chat's own `sendPhoto` / `sendVideo` / `sendDocument` / text paths and deletes the copies when done.

**Notification taps and replies (ADR-066).** A tapped notification carries its chat id to Dart (`dev.sinhron/push` `opened` / `takeOpened`, kept until Dart acknowledges); `openChatFromNotification` waits for the navigator and the chat list, so a cold start lands in the chat, under the App Lock cover if it is on. "Reply" (Android `RemoteInput` → `ReplyReceiver`; iPhone `UNTextInputNotificationAction` in category `sinhron-message`, the app woken in the background) keeps the text encrypted on the phone (Keystore / Keychain) until Dart takes it (`reply` event or `takeReplies` at engine start); `NotificationReplier` opens the connection off screen, sends it through `MessageActions.sendText` — the ordinary MLS message — and reports `replyDone` (sent / queued / failed) so the native side clears or rewords the notification. Not offered with "show nothing", App Lock, requests or blocked chats.

**Android wake-up through Google, the content sealed (ADR-057).** An Android phone with Google services registers `fcm:<token>` with a 32-byte key of its own (`PUT /v1/push-token`, `call_hint_key_hex`); the server's Firebase ids reach the app on `GET /v1/push/info`, nothing is baked into the APK. When a person has no live connection, `push::RealPush` sends FCM a high-priority data message with one field `s` — the UnifiedPush JSON (+`ts`) padded to 128 bytes and sealed AES-256-GCM to that key (`server/src/fcm.rs`): messages and calls look the same to Google. The phone (`Fcm.kt` → `PushWake.kt`) rings a call at once, then opens the app's own connection for a few seconds (`lib/core/push_wake.dart`) — the server replays what waited, the app draws "name: text" itself — and closes it again before letting Android freeze the process, so the server goes back to pushing. Without Google push or ntfy the app turns "always connected" on by itself; with Google push it stays off (2026-10-19: the push wakes the app, no socket in the background).

**A new device is the same device (ADR-064).** My devices talk through my own-devices group (Saved messages, ADR-055: an MLS group of nobody but me), sealed only to my own delivery key; Rust accepts and sends there only when the sender is me and nobody else is in the group. *Transfer:* the device that adds a new one to that group packs its database (`sinhron_storage::transfer` → `sinhron_sync::transfer`: a header part with chats, contacts, people, calls, settings and sticker packs, then ~2 MB message parts, each encrypted like a media blob), uploads sticker pack files, parts and a manifest through `/v1/media`, and sends `Transfer` (envelope tag 40) with the manifest key; the new device downloads and merges part by part (wire-id dedup, clocks for settings), both sides keeping their job in the encrypted DB so it resumes. Media stay where they are — messages carry their refs and keys; the old device asks `POST /v1/media/touch` which blobs the server lost and uploads those from its local copies. *Ongoing:* local changes of contacts, blocked people, chat flags, sticker packs and synced settings are stamped in `sync_clock` (schema v16, `devsync`), sent as `DeviceSync` (tag 41) every 20 s while on screen, applied last-writer-wins. *0.12.0:* ADR-103 — everything for one's own devices (the letter with new account keys after a disconnect, transfer) is sealed to the generation-0 delivery key, which every own device always has (`SyncClient::own_devices_key`; after a generation change the generation-0 keys are published too, first — `sealed_keys_to_publish`). ADR-104 — the phone remembers the devices it disconnected (`device_revoked:<key>`, a `devsync` setting synced between own devices, not a server notice) and does not bring them back into chats, send them history or a transfer whatever the server lists; pairing the same key by QR clears the mark. ADR-105 — a cloud backup is untrusted by origin: after a restore the phone makes a new key generation, "verified" marks are not taken from the copy, clocks from the future are cut.

**Formatted text (ADR-070).** A text message (or a media caption, or an edit) carries its formatting as ranges beside the clean text: `TextEntity{kind, offset, length, url, language}` in UTF-16 units (Telegram's model) — bold, italic, underline, strikethrough, inline code, code block, spoiler, words-that-link, quote. `rich = true` says the ranges are the whole formatting, so a new app never reads markers; without it (0.6.0) the 0.6.0 markers are read on display (`FormattedText.legacy`). The receiver's Rust cleans every range (`clean_entities`: inside the text, on character boundaries, known kind, link only to https/http/mailto/tel) before Dart sees it as `NetPush.entities_json`; the local DB keeps it in `messages.entities_json` (v17). Search, the chat list, push previews and reply quotes see clean words. The composer (`RichTextController`) keeps a style per character and paints it while typing; Telegram markers convert when the closing one is typed.

**Unidentified sealed delivery (ADR-026).** Each person's 16-byte access key (derived from the account secret) is handed to chat partners inside MLS (`Access` envelope message); the server only stores its SHA-256 (published with the delivery keys). With every recipient's access key, the client posts the sealed envelopes to `POST /v1/sealed` **without authentication** (a fresh HTTP client); the server checks each access key and stores/pushes the envelope like `SealedSubmit`. Otherwise — or if anything is refused — the authenticated `SealedSubmit` is used.

**Block = revoke a per-contact access key (ADR-071).** The access key is now one per contact (`SyncClient::access_key_for` — derived from the account secret and the contact's identity, equal on all my devices). Before handing keys out, the app brings the server's set up to date (`PUT /v1/access-keys`: hashes for everyone in my accepted chats + me, and every block / unblock with its time — the later decision wins, so a device that hasn't heard of a block can't lift it); then each person gets their own key (a chat of two: an `Access` message in it; a group: one sealed to each member alone; blocked people and unaccepted requests: none). For someone in this mode the server: delivers `POST /v1/sealed` with an active key (push if urgent), **silently drops** one with a revoked key (same "accepted" answer, nothing stored, no push), refuses unknown / the old shared key; delivers keyless routes (WS `SealedSubmit`, plain `Submit`) **without push** and outside the badge, 60/min per sender→recipient; swallows a `CallInvite` whose `access_keys` hold only a revoked key, rings the open app only (no push) when there's no key. The key is deliberately not sent on the WS route: tied to a signed-in sender, its later revocation would reveal the block. The client sends per recipient: keyed ones anonymously, the rest over the WS. *Amended (status 177):* a request (urgent, keyless) also triggers a content-free `PushMessage::Request` (rate-limited per pair and per person) — an iPhone gets a **background** push with only the sealed preview and decides in `RequestNotice` (blocked → nothing; accepted chat → its usual notification; else one quiet "New message request"); Android gets `{"t":"req"}`, connects, and draws the quiet one itself. Call invites carry `sends_access_keys`; an invite without it (an app older than 0.7.0) still wakes the phone while `SINHRON_LEGACY_CALL_PUSH` is on, and Android's encrypted call push carries the caller's key so the phone never rings for someone it blocked.

**Invite links (ADR-043).** "Share" makes a signed link `https://<server>/join#<payload>.<signature>` (`sinhron_sync::invite`); it is shared short — `https://<server>/i/<id>#<key>`: the fragment is sealed under a random 16-byte key (AES-128-GCM, AD = `sinhron-short-invite-v1:` + id) and stored at `POST /v1/invites` (no account, a year, table `short_invites`). Opening: `GET /v1/invites/<id>` → decrypt → the long link, verified as before. The server never gets the key (it's after `#`). Can't store (offline, old server) → the long link is shared. `/join` and `/i/<id>` serve the same install page for phones without the app.

**QR pairing (ADR-027).** A new device makes its own device key and shows `sinhron-pair:2:<id>:<one-time HPKE key>:<device key>`; a device holding the account key scans it, signs a certificate for that device key and seals a *linked-device bundle* (identity public key, certificate, delivery/access roots — no identity key) to the HPKE key at `PUT /v1/pairing/{id}` (signed, 10-min TTL, write-once); the new device takes it once and signs in (a "taken" marker then stays 10 minutes: a later PUT or GET for that id gets 409, so the old phone warns that someone else used the code — ADR-091). It signs account-level requests and its WS login with its own key; the server accepts that key only while the device is active (`accounts::resolve_signer`) — revoking locks it out. Only the identity key can add or revoke devices.

**Per-device delivery details (ADR-025).** A WS connection is a device (devices with their own leaf log in with their device key); Welcomes carry `recipient_device_pks` and are pushed/queued for those devices only; `devices.last_seen_at` lets device sync skip long-silent installs; a revoked device's live connections are dropped; call participants are devices (LiveKit identity = device key, SFrame key from its leaf); groups keep 2 past epochs (`MAX_PAST_EPOCHS`) so a message sent next to a Commit still decrypts.

**Identity key on the first device only (ADR-027).** A device where the 24 words are typed later also keeps only a linked-device bundle built from the phrase for its own key (`linked_bundle_from_phrase`); account-key actions there (add / revoke devices) take the 24 words for that step only.

**Timers count from receipt (ADR-020).** `message_deliveries.received_at` is set when a delivery is pushed to a live session or replayed on Resume; a sealed delivery's `ttl_secs` becomes `expires_at` then, and a chat's stored ciphertext goes only once every recipient has had it for the chat's timer.

**SOCKS5 proxy (ADR-028).** Optional `host:port` (Tor via Orbot): the WS connects through a SOCKS5 tunnel (`tokio-socks`, remote DNS) and HTTP through `socks5h://` — the server doesn't see the phone's IP. Calls don't use it.

**Access-key rotation / sealed timer.** Access keys are versioned; the server keeps the newest version's hash (`users.access_version`) and tells older devices to catch up; "reset" in Privacy and every device revocation bump it. Sealed deliveries carry the chat's timer (`SealedDelivery.ttl_secs` → `message_deliveries.expires_at`). "Online" heartbeats and "typing" also carry `drop_after_secs` (120 s, tech-debt 2.53): the server sets `expires_at` when it stores them, so a contact who is away is not sent an hour of them on login; with a chat timer too, the sooner of the two wins.

**Message partitions (tech-debt 4.4).** `messages` is partitioned by UTC month: the retention sweep keeps a partition for the current and next month (moving rows that fell into `messages_default`) and DROPs whole months older than the retention window; a row DELETE trims only the straddling month and DEFAULT.

**Server-side chat timer (tech-debt 2.5).** `PUT /v1/groups/{id}/retention` (member, signed) sets `mls_groups.disappearing_after_secs`; the retention sweep deletes the chat's stored ciphertexts older than that. The app calls it whenever the disappearing timer changes.

**History for a new device (ADR-025).** After device sync adds our new device to a chat, the adding device sends the chat's last 200 messages from its local DB as `History` envelope messages — MLS messages in that chat, sealed only to our own delivery key, so only our devices get them. The new device stores them if its copy of the chat is still empty. Pushes that decrypt to an MLS state change (Commit, own echo) are surfaced as kind `control` and never stored.

**Several devices per person (ADR-025).** A linked device has its own MLS leaf key and an identity-signed device certificate as credential (`POST /v1/devices`); senders and members are resolved per person (`identity_of_leaf`: the credential counts only if it names the leaf's own signature key — the identity key itself, or a certificate for that key; a leaf that fails is nobody: not added, its Commit and Welcome refused, its messages have no sender). `Submit` membership is checked across all of the person's active devices; when ≥ 2 of them are in the group, the sender's own user is a recipient too (the sending device drops its echo). Inviting someone adds all their devices (`consume?per_device=true`); device sync adds one's own missing devices to every group with a pending Commit + Welcome to oneself and removes revoked ones.

**Commit ordering (ADR-022).** A Submit carrying an MLS Commit sets `is_commit` + `commit_epoch`. The server compare-and-sets `mls_groups.current_epoch` in the same transaction: the first Commit of an epoch wins, a racing one gets Ack 409 and is neither stored nor fanned out. The client keeps such a Commit pending (`invite_to_group_pending`) and only merges it on Ack 0; on 409 it discards it, applies the winner's Commit and retries. **ADR-092 (2026-11-04):** the server can't tell a garbage Commit from a good one, so "first Commit wins" let a member freeze a chat. Now every phone applies the first Commit of its epoch it can apply (the server fans a chat's Commits out one at a time, in order — `COMMIT_ORDER`, table `group_commits`), and the server takes a Commit for epoch E only from a device that names the Commit that brought it to E (`Submit.parent_commit_id`) and every Commit for E it has seen since and not taken (`refused_commit_ids`) — kept per chat in `sinhron_sync::commit_order::CommitLog` (setting `commit_log`). `is_commit` must match the MLS header (`ws::mls_commit_head` = `group::commit_epoch`); a sealed Commit is not applied; after a Commit it didn't take, a phone makes an empty one on the next device sync (`self_update_pending`) so the epoch and its card are an honest member's again.

**Retries of Submit.** A retry carries the same `message_id`; `message_deliveries (recipient_user_pk, message_id)` is unique, so it is delivered once. `messages` is partitioned by `ts` and can't have a unique index on `message_id` alone — a retry that delivered nothing new deletes the ciphertext copy it just stored (same transaction).

**Per-recipient sequence:** `message_deliveries.seq` — `BIGSERIAL`, monotonic per recipient. Resume cursor = `(stream_id, last_acked_seq)`. Sent down в `Push.sequence`.

**Client delivery guarantees (0.8.0, record 185).**
- **Outgoing:** a text sits in the persistent queue (`pending_actions`, `MessageActions`) from the moment it is sent until the server's Ack for its wire id. A send that "succeeded" only reached the connection's channel, so a dead connection, or one replaced on resume, lost it. On every connect (`onReconnected`), and on a back-off of 20 s → 30 min while unconfirmed, it goes again with the same id; the server (`ON CONFLICT … DO NOTHING`) and the receiver (`remote-<wireId>`) drop copies. It gives up after 7 days or 3 refusals; a 429 (busy) is not a refusal. Record 211: a stored media message or sticker goes on the same queue (`trackStoredOutgoing` with its media JSON; resent by `net_resend_media`, no new upload); one chat that can't send no longer holds back the others (the flush skips only that chat's later entries); a failed message shows a red "Not sent · Tap to retry" under it and a red "!" in the chat list (`retrySend` — same wire id).
- **Server ack (record 211):** `SealedSubmit` acks 0 only if the message reached another account (or was meant only for my own devices); nothing stored for anyone else → 404 (unknown keys) or 429 (request limit), so the sender sees "not sent", not a false ✓.
- **Receipts (record 211):** a delivery / read receipt counts as sent only with its server ack (`_receiptsOut`); until then its rows stay pending and go again with the chat's next message and on every reconnect (all chats). A repeat only raises a status already raised.
- **Deleted chat (record 211):** a message that decrypted for a group with no local chat row (the chat was deleted on this phone) re-creates the row (`_createChatRow`, the Welcome path) instead of being dropped — it can't be decrypted a second time. Not a request if the writer is in my contacts.
- **One personal chat per person (2026-11-03):** two personal chats with the same person (both started one, "Message" didn't see the first, or a deleted one came back next to a new one) are folded by `PersonalChats.tidy` after each device sync and when a deleted chat comes back: the lowest group id is kept (the same choice on every device of both people), but an accepted chat always before a message request, and folding never clears the request mark (status 231, critic:2), the other's messages move in (`storage_chat_merge_into`), its group stays and its pushes land in the kept chat (`personal_chat_former`, `formerPersonalRedirect`). It waits while this device can't post to one of them or one isn't named yet (a group of two looks personal until its name comes).
- **Incoming:** the backlog at login and the Resume replay can carry the same `sequence`. The Rust core takes each delivery once per run (`first_delivery`), before decrypting it; a second copy can't be decrypted (its MLS key is spent). A frame that still doesn't decrypt is logged and dropped, never shown.
- **Connect:** TCP + TLS + WebSocket upgrade are bounded together by `Keepalive::connect_timeout` (20 s), so a stalled TLS behind a VPN fails and is retried.

**Background tasks:**
- `retention::spawn(pool)` — sweeps every `SINHRON_RETENTION_SWEEP_SECS` (default 3600s)
- Drops: consumed KP, expired KP, old messages (per global + per-group TTL), old deliveries, expired pending_welcomes; `admin::sweep` — administrators' notices and report IPs older than 30 days (ADR-077)
- `admin::spawn(pool, push, sessions)` (ADR-077) — only when `SINHRON_ADMIN_IDENTITIES` lists someone. Once a minute: CPU / memory (`/proc`), WS sessions → load alerts (fixed thresholds 90 % / 90 % / 2000, the same one at most every 30 min) and "back to normal"; each new report at once (woken by `report_filed`), with both IPs. Writes `admin_notices`; an administrator without a connection gets a plain "new message" push. The app reads them with `POST /v1/admin/notices` (403 for anyone else) and shows the read-only "Server" row/chat.

**Metrics (Prometheus exposition):**
- `sinhron_ws_active_sessions` (gauge)
- `sinhron_messages_submitted_total` (counter)
- `sinhron_messages_fanout_total` (counter)
- `sinhron_http_requests_total{endpoint, status_class}` (counter)
- `sinhron_retention_rows_deleted_total{table}` (counter)
- `sinhron_rate_limit_hits_total{action}` (counter)
- `sinhron_http_request_duration_seconds` (histogram)

---

## 3. Data flow: critical paths

### 3.1. Onboarding (phrase entry)

```
User types phrase                                     storage_save_phrase(phrase)
   │                                                       │
   ▼                                                       ▼
createAccountFromPhrase (SaveAccessScreen, ADR-059)  sinhron_crypto::derive_identity
   │                                                       │  (HKDF → 4 sub-keys)
   │  fullPhrase = _phrase.join(' ')                       │
   │                                                       ▼
   ├──→ try {                                         storage::save_phrase
   │       fp = await core.storageSavePhrase(phrase)   (writes identities row)
   │       ref.invalidate(identityProvider)           │
   │    }                                              │
   │                                                       ▼
   │    try {                                        identityProvider re-fetches
   │       await netService.startFromPhrase(phrase, url)
   │    }                                                      │
   │                                                            ▼
   │                                              core.syncInitFromPhrase(phrase, mlsDbPath)
   │                                                            │
   │                                                            ▼
   │                                              SyncClient::new(SyncClientConfig)
   │                                                            │  (derives storage_key,
   │                                                            │   opens SQLCipher,
   │                                                            │   creates MlsIdentity)
   │                                                            │
   │                                              core.netConnectFromPhrase(url, phrase)
   │                                                            │  → WS Hello → Auth → Ack (retries with backoff
   │                                                            │    until the bootstrap below registered us)
   │                                                            │  → clock_drift::record(Hello.server_time)
   │                                                            │  → _runEventLoop starts polling netNextEvent
   │                                                            │
   │                                              core.syncBootstrapWithServer(url)  (≤ 15 s wait)
   │                                                            │  → HTTP register + publish KP
   │                                                            │  (corrected_now_secs timestamps)
   │                                                            ▼
   │                                              NetStatus.connected
   │                                                            │
   ▼                                                            ▼
   │   (ADR-059) then: saved to Passwords / on paper → AccountAccess.markSaved;
   │   "Later" → AccountAccess.keepForLater (Keychain `pending-phrase`)  │
   │   (SEED-2: keepForLater runs BEFORE createAccount — a crash in between
   │   can't leave an account without words; not kept → no account, stay)
   ▼
widget.onDone?.call()  → SettingUpScreen → ChatList
```

ADR-059: the phrase is generated on step 3 "Keep access to your account" (`SaveAccessScreen`). "Save to Passwords" →
`PasswordVault` (channel `dev.sinhron/passwords`: iOS — synchronizable Keychain item `dev.sinhron.words`, ADR-085 (an old Safari password is picked once via `ASAuthorizationPasswordProvider`, moved and deleted),
Android Credential Manager) *before* the account is made; "Write the words down" → `RecoveryPhraseScreen` (2-word check
or the recovery sheet); "Later" → straight on. Until saved, the words wait in the Keychain / Keystore (this device only);
Settings → Secret words (`AccountAccessScreen`) and the chat-list card (`AccessReminderCard`) ask again.

### 3.2. Send message Alice → Bob (within same group)

```
Alice's UI:                              Server:                          Bob's UI:
ChatViewScreen.onSend("hi")               │                                │
   │                                       │                                │
   ▼                                       │                                │
sendMessage(ref, chatId, "hi")             │                                │
   │                                       │                                │
   ├──→ storageMessageAppend (local)       │                                │
   │   (writes 'mine' row immediately)      │                                │
   │                                       │                                │
   │   chatId is MLS group_hex             │                                │
   │   (40+ hex chars detected)            │                                │
   │                                       │                                │
   ├──→ core.netSendEncrypted(             │                                │
   │       groupIdHex, "hi".bytes,         │                                │
   │       messageId                       │                                │
   │   )                                    │                                │
   │     │                                  │                                │
   │     ▼                                  │                                │
   │   SyncClient.encrypt(group_id, "hi")   │                                │
   │     │  → MLS PrivateMessage TLS bytes  │                                │
   │     ▼                                  │                                │
   │   WsClient.send(Submit { group_id,    │                                │
   │                          ciphertext,   │                                │
   │                          message_id,   │                                │
   │                          sealed=false  │                                │
   │                        })              │                                │
   │     │                                  │                                │
   │     ▼ WS frame on wire                 │                                │
   │     ──────────────────────────────────►│                                │
   │                                        │                                │
   │                                       handle_submit                     │
   │                                         │                                │
   │                                         ├ rate_limit check               │
   │                                         ├ validate inputs               │
   │                                         ├ membership check              │
   │                                         ├ BEGIN TX                      │
   │                                         │   INSERT messages (...,       │
   │                                         │     sender_device_pk = NULL)  │
   │                                         │   INSERT message_deliveries   │
   │                                         │     (recipient_user_pk, seq)  │
   │                                         │     for each member           │
   │                                         ├ COMMIT                        │
   │                                         │                                │
   │                                         ├ MESSAGES_SUBMITTED_TOTAL.inc  │
   │                                         │                                │
   │                                         │ // fanout                     │
   │                                         │ for each recipient:           │
   │                                         │   sessions.fanout(rid, Push)  │
   │                                         │     ─────────────────────────► │
   │                                         │                                │
   │                                         │ MESSAGES_FANOUT_TOTAL.inc(N)  │
   │                                         │                                │
   │                                         ├ for offline:                  │
   │                                         │    push.notify(deliv_key,     │
   │                                         │       PushPayload {           │
   │                                         │         group_id_hex,         │
   │                                         │         unread_total,         │
   │                                         │         summary: "New msg" }) │
   │                                         │                                │
   │ ◄──── Ack { 0, "submitted" } ────────  │                                │
   │     │                                  │                                │
   │     ▼                                  │                                │
   │   Alice's WS event "ack"               │                                │
   │   logged in NetService                 │                                │
   │                                        │                                │
   │                                        │                                ▼
   │                                        │                          Bob's WS event "push"
   │                                        │                              │
   │                                        │                              ▼
   │                                        │                          NetService._onPush
   │                                        │                              │
   │                                        │                              ├ chat by id (== group_id_hex)
   │                                        │                              │
   │                                        │                              ├ storageMessageAppend
   │                                        │                              │   (sender='Alice', body='hi')
   │                                        │                              │
   │                                        │                              ├ invalidate messagesProvider(chatId)
   │                                        │                              ├ invalidate chatsProvider
   │                                        │                              │
   │                                        │                              ▼
   │                                        │                          ChatView re-renders с bubble "hi"
```

**Note:** Submit's `ciphertext` is **MLS ciphertext** — server cannot decrypt. plaintext "hi" сидит только в Alice's local storage и в Bob's local storage после MLS decrypt.

### 3.3. Onboarding new member (Alice invites Bob via Compose)

```
Alice has Bob's identity_pubkey_hex (paste из QR / link / clipboard).

ComposeScreen → onInviteByIdentity(recipientHex, displayName)
   │
   ▼
createMlsChat(ref, recipientHex, displayName, httpBase) — в chat_providers.dart
   │
   ├──→ core.syncCreateGroup() → group_id_hex
   │
   ├──→ core.syncFetchKpAndInvite(httpBase, group_id_hex, recipientHex)
   │      │
   │      ▼
   │    HttpApi.fetch_device_keypackages(login_seed, recipientHex, [])
   │      → GET /v1/keypackages/consume?identity_pubkey_hex=...&per_device=true
   │        &signer_pk_hex=…&proof_ts=…&proof_hex=…   (ADR-087: подписано)
   │      ← KeyPackage bytes (base64)
   │      │
   │      ▼
   │    SyncClient.invite_to_group(group_id, kp_bytes)
   │      → GroupHandle.add_member  (MLS protocol)
   │      ← AddMemberOutcome { commit_bytes, welcome_bytes }
   │      │
   │      ▼
   │    HttpApi.announce_group(alice_device_seed, group_id, [alice, bob])
   │      → POST /v1/groups   (ADR-083: signed by Alice's device)
   │      (server creates groups + group_members rows so fanout works)
   │      │
   │      ▼
   │    InviteOutcome { commit_b64, welcome_b64 }
   │
   ├──→ core.netSendWelcome(recipientHex, group_id_hex, welcome_b64)
   │      │
   │      ▼
   │    WsClient.send(Welcome { recipient_identity_pubkey, group_id, welcome_bytes, sent_at })
   │      │
   │      ▼ on wire
   │      ───────────────────────────► Server
   │
   ├──→ core.storageChatUpsert (chats row, id=group_id_hex)
   ├──→ core.storageChatSetPeer (the row knows Bob from the start)
   ├──→ ref.invalidate(chatsProvider)
   │
   ▼
ChatList shows new chat → push to ChatView

Before all this, _startChatByIdentity asks PersonalChats.find(bobHex)
(storage, by the row's peer or by the group's MLS members): a chat with
Bob already here → it opens, no second group (owner, 2026-11-03).


Server-side:
  handle_welcome(...) →
    if recipient online: sessions.fanout to Bob's WS  → Ack
    else: INSERT pending_welcomes → 'queued' Ack
  0.12.0 (audit 04-server-ws): the Ack is one "welcome accepted" either way (does not say whether
  the person is online); the welcome queue is 8 MiB per person (was 64), `group_id` ≤ 255 bytes
  and counts in the quota; a Welcome without an addressee for a person with several devices is
  split into per-device copies; login reads at most 8 MiB of the queue (newest).

Bob's WS receives Welcome frame (live or via flush_pending_welcomes on reconnect):
  NetService._onWelcome(w)
   │
   ├──→ core.syncJoinViaWelcome(welcomeB64)
   │      → SyncClient.join_via_welcome (MLS protocol)
   │      ← group_id_hex
   │
   ├──→ core.storageChatUpsert (Bob's chats row, id=group_id_hex,
   │                            displayName="New chat"; members {me, X}
   │                            → storageChatSetPeer(X))
   ├──→ ref.invalidate(chatsProvider)
   │
   ▼
Bob's ChatList shows new chat
```

**Группа из нескольких человек (ADR-034).** «Новая группа» → `createMlsGroup(ref, name, memberHexes, httpBase)`:

```
core.syncCreateGroup() → group_id_hex
core.syncFetchKpsAndInvitePeople(httpBase, group_id_hex, [bob, carol, …])
   → SyncClient.fetch_kps_and_invite_people
       GET /v1/keypackages/available?identities=…   (у всех ли есть — ничего не забирает; 404 у старого сервера → дальше как раньше)
       for each person: GET /v1/keypackages/consume?…&per_device=true   (все устройства)
       invite_devices(group, all KPs)        → ОДИН Commit (никому не шлётся: в группе только создатель)
       announce_group(мой ключ устройства, group, [me, все устройства всех])   (подпись, ADR-083)
   ← InviteOutcome { welcome_b64 }  (+ устройства каждого человека запомнены)
for each person: core.netSendWelcome(person, group, welcome_b64)   → копия, адресованная его устройствам
storageChatUpsert(isGroup: true, displayName: name)
sendAction(group, {t: group_name, name})   → MLS-сообщение GroupName (tag 17)

Bob/Carol: _onWelcome → чат «Группа XXXX» (isGroup = участников > 2), запрос на переписку
           Push GroupName → MessageActions 'group_name' → storage::chat_set_group_name
                (группа — переименовать; чат с заглушкой — стать группой с этим именем)
```

Добавить позже — `addGroupMembers` → `sync_add_group_members`: `invite_devices_pending` → `Submit{is_commit, commit_epoch}` (ADR-022; Push доходит до всех участников) → по Ack 0 `confirm_commit` → анонс → Welcome новым → снова `group_name`.

Управление (ADR-035; админ записан в контексте группы MLS — ADR-088, `sync_group_admin`; ушёл — роль у самого раннего оставшегося, Commit с другой записью не применяется; нового человека Commit'ом приносит только тот, кто может управлять — `may_add_people`, иначе Commit не применяется, запись 231): 0.12.0, ADR-102 (правило «админа убирает только Commit после его „выхожу“» — CM-08 — сделано и откатано к поведению main, ждёт решения владельца): новый лист автора Commit / Update должен называть того же человека, иначе Commit не применяется; сообщение без подтверждённого отправителя не показывается.
- **Удалить** — `MessageActions.removeMembers` → `sync_remove_group_members` (`remove_identities_pending` → тот же `Submit{is_commit}` → Ack 0) → действие `removed` (тег 19, для старых приложений). Строки «X добавил(а) / удалил(а): Y» у всех пишет сам Commit: `IncomingMessage::Commit{added, removed}` + автор → `action_json` push'а `control` → `onGroupCommit` (запись 231).
Управление (ADR-035; админ = создатель = лист 0 MLS, `sync_group_creator`):
- **Удалить** — `MessageActions.removeMembers` → `sync_remove_group_members` (`remove_identities_pending` → тот же `Submit{is_commit}` → Ack 0 → `POST /v1/groups/{id}/remove`, ADR-083: сервер вычёркивает все их устройства из состава и выгоняет из звонка) → действие `removed` (тег 19) → строка у всех.
- **Удалить** — `MessageActions.removeMembers` → `sync_remove_group_members` (`remove_identities_pending` → тот же `Submit{is_commit}` → Ack 0 → `POST /v1/groups/{id}/remove`, ADR-083: сервер вычёркивает все их устройства из состава и выгоняет из звонка) → действие `removed` (тег 19, для старых приложений). Строки «X добавил(а) / удалил(а): Y» у всех пишет сам Commit: `IncomingMessage::Commit{added, removed}` + автор → `action_json` push'а `control` → `onGroupCommit` (запись 231).
- **Выйти** — действие `leave` (тег 18) → `sync_leave_group_server` (`POST /v1/groups/{id}/leave`, подпись) → чат удалён. У остальных: строка, затем через 0,3–2,3 с кто-то коммитит удаление вышедшего.
- **Удалённый** — после Commit'а (`control` → `onGroupCommit`) `sync_group_is_active` = false: строка «Вас удалили», вместо поля ввода — «Вы больше не участник», и тот же `leave` на сервере.
- **Переименовать** — `group_name` от того, кто может управлять (`GroupRole.canManage`).

### 3.4. Cold restart + identity recovery (ADR-021)

```
App launch:
  AppDelegate.didFinishLaunching:
    protectAppFiles()  // Data Protection: completeUntilFirstUserAuthentication
  main.dart:
    1. await RustLib.init()
    2. dbPath = '$docsDir/sinhron.db', mlsDbPath = '$docsDir/sinhron-mls.sqlite'
    3. openStorageAtBoot(path, fileExists, keys: Keychain, ops: FFI)   // lib/core/session.dart
         device key in Keychain?
         ├── yes, file exists → storageInit(path, key(deviceKey))
         │        └── Locked? → storageInit(path, '') (still plain) → storageRekey(key)   // seal now
         │                         └── Locked again → StorageBoot.locked (sealed with another key)
         ├── yes, no file   → stale key from an earlier install → delete it, open plain
         └── no             → storageInit(path, '')  → Locked? → StorageBoot.locked
         (never erases — StorageError::Locked instead of the old "self-heal" wipe)
    4. BootDiagnostics(storageLocked) → ProviderScope → SinhronApp

  AppRoot:
    storageLocked            → UnlockScreen(locked)        // phrase opens the DB
    identity row + device key → ChatList + Session.resume() // auto-connect, no phrase
    identity row, no key      → UnlockScreen(reconnect)     // phrase must match the identity
    no identity               → onboarding

Session.resume():
    deviceKey = Keychain.read()
    netService.startFromPhrase(deviceKey, serverUrl)   // Rust accepts phrase OR device key
      ├──→ syncInitFromPhrase(deviceKey, mlsDbPath)
      │      SyncClient::new → derive_identity(deviceKey) → storage_key → SQLCipher MLS DB
      │      MlsIdentity::from_phrase(provider, deviceKey) → same Ed25519 as the phrase
      ├──→ netConnectFromPhrase(url, deviceKey) → WS handshake → connected ✓
      └──→ syncBootstrapWithServer (idempotent; waited ≤ 15 s, after the WS —
           bug 2026-10-16: before it, a hung HTTP call after Wi-Fi → LTE left
           no connection at all, "net not connected" until a restart)
    Every HTTP client: connect 10 s / silence 30 s (Tor 30 / 60), idle pool 30 s.
    Settings → «Соединение / Переподключиться» calls resume(force: true).

Onboarding end (Session.establish(phrase)):
    deviceKey = device_key_from_phrase(phrase)   // BIP-39 seed, one-way
    Keychain.write(deviceKey); serverUrl saved
    start net with deviceKey; storageRekey(key(deviceKey))   // seal the chats DB
    phrase dropped from Dart memory

Unlock (Session.unlock(phrase)): validate → locked DB must open with key(deviceKey),
    or the stored identity's fingerprint must match → only then Keychain.write + resume.
Erase (UnlockScreen «Стереть и начать заново», Sign Out): syncShutdown, storage_erase(path),
    delete MLS file, Keychain.delete → onboarding.
```

### 3.5. State backup + restore — removed (2026-10-26)


### 3.6. Chat backup in the person's own cloud (ADR-073)

```
DAILY (BackupKeeper: 1 min after start, on background / resume, if 24 h passed)
  tag = chat_backup_tag(secret)                 // 16 hex: this device's prefix
  cloud = names "<tag>-*" in iCloud Documents/Backup  |  Drive appDataFolder
  loop:
    p = chat_backup_step(secret, staging, cloud, 32 MB)
        // ADR-064 ExportJob over DirTransport: parts / packs / media the cloud
        // lacks → staging/<sha>; at Upload→Offer also staging/root.sinhron
        // (manifest key, totals) sealed with cloud_backup_key (HKDF of backup_key)
    upload each "<tag>-<sha>", then "<tag>-root.sinhron" (root always last)
  until p.done
  delete "<tag>-<sha>" not in chat_backup_keep()   // what older runs left
  delete other devices' backups of this account older than 30 days (root first)
  chat_backup_mark(cloud, root.created_ts)       // ADR-090: server keeps the newest

RESTORE (right after the 24 words; or Settings → Backup)
  roots = every "*-root.sinhron" these words open → newest
  chat_backup_mark(cloud, 0) > newest root's time → "a newer backup is gone" (ADR-090)
  chat_restore_start(secret, root) → ImportJob from the root's offer
  loop chat_restore_step(staging): "need X" → download "<tag>-X" → again
  media = chat_restore_media() → download in batches of 20 → chat_restore_adopt
```

**Added back by contacts (ADR-074).** `sync_devices` has a second pass: for every chat this device is in and every *other* member, their active devices (`GET /v1/devices`, cached 10 min; registered ≥ 10 min ago, seen within 30 days) not yet in the chat → their KeyPackages → `add_devices_of_pending` (each package must carry a valid certificate of exactly that person, who already has a leaf) → one pending Commit → announce → one Welcome per person to their new devices; no history. The joining device sees `added_back_by_someone_else` (Welcome from another person + another of my leaves already there) → not a request. KeyPackages: a one-time stock of 20 after sign-in, one more after every Welcome. Saved messages restored from a gone phone → `SavedMessages.repair` (new group, notes moved) unless another own device was online within 48 h.

**Joining by the chat's card (ADR-075).** After every epoch change a member's device leaves the chat's MLS GroupInfo ("card": the tree's public keys, the epoch's external key — no messages, no names) on the server (`PUT /v1/groups/{id}/card`, signed by that device, stale epoch → 409). A device with a chat only from a backup (no MLS state) fetches the card (`POST /v1/groups/{id}/card` — only for an active device of a person who has, or had a cut-off, device in the chat) and joins by an external commit, ordered like any Commit; `join_by_card` refuses unless another leaf of the same person is already there, and members apply an external commit only from a person who already has a leaf. Device revocations carry the account key's signature (`devices.revoke_proof`, listed by `GET /v1/devices?revoked=1`); contacts' phones verify it themselves (`revocation_is_signed`) and remove those leaves, never a person's last one. A revoked first device is refused on WS (403). Right after the 24 words a sheet lists the other devices with "Disconnect" (the words are the only account key this device gets). *ADR-090:* a new chat starts at the epoch its creator announces (signed `epoch` in `POST /v1/groups`), Commits are ordered at exactly the current epoch, and the server keeps the device whose Commit won it (`epoch_committer_device_pk`): the epoch's first card stays; only that device replaces it. *ADR-093 (replaces that):* every device keeps its own card (`group_cards` keyed by device, the committer column is gone); the fetch returns each active member device's card with its person's identity key, and the phone (`card_choice::cards_to_try`) takes the content its own person left, else the one most people left (cards of one epoch differ only in the signer and signature; one person is one vote; only the two newest epochs count). *0.12.0, ADR-100 (replaces the vote):* `GroupHandle::join_by_card` takes a card only when it is signed by another device of the same person (the signer leaf is mine and is not this device) — a signature the server cannot forge; other people's cards, however many, are no reason to join, and the app passes only its own person's cards to the choice. Before anything is built or written: the card's chat id is the one asked for, the phone has no live state of this chat, and the card is not older than the dead copy of the chat on this phone. An expired lifetime of somebody else's leaf no longer blocks joining by Welcome or by card.

Keys: an account-key device derives `cloud_backup_key` from the words' seed; a linked device carries it in its bundle (`LinkedBundle::cloud_key`, 32 bytes more; the DB key ignores them). An older bundle without it → "Turn on backup here" → `chat_backup_unlock(words)`.

---

## 4. Cross-cutting concerns

### 4.1. Errors

**Lib code:** structured `thiserror` enums (см. `docs/tech-debt.md` § 3.2).

**FFI boundary:** all returns `Result<T, String>`. Stringify at the boundary (intentional — frb wants String).

**Server HTTP:** typed errors implement `IntoResponse`. Status code + JSON body. Например:
- `RegisterError::BadRequest(msg)` → 400 + `{"error": msg}`
- `RegisterError::RateLimited { retry_after_secs }` → 429 + Retry-After header
- `*::NoDb` → 503

### 4.2. Logging

`tracing` crate everywhere. RUST_LOG env var controls verbosity (`info,sinhron_server=debug,sqlx=warn`).

**Conventions:**
- Sensitive fields **must** be redacted: phrase (zeroized), private keys (never logged), plaintext bodies (never)
- `identity_pubkey` — semi-public, OK to log truncated (first 12 chars)
- All `error!` calls должны иметь structured field `error = %e`

**Per-request tracing:** `tower-http::SetRequestIdLayer` + `PropagateRequestIdLayer` (T2.5). Each HTTP req gets `x-request-id` UUID, spans propagate it, response carries it back. Log correlation via grep.

### 4.3. Metrics

In-process counters only (`server/src/metrics.rs`: rate-limit hits, messages, calls). The `/metrics` endpoint was removed 2026-10-26 — nothing scraped it.

### 4.4. Crypto domain separation

**All HKDF info strings + signature domains are namespaced** with `sinhron-` prefix + version suffix:
- HKDF: `sinhron-id-ed25519/v1`, `sinhron-id-x25519/v1`, `sinhron-state-backup/v1`, `sinhron-storage-key/v1`, `sinhron-delivery/v1`, `sinhron-access-root/v1`; from the backup key: `sinhron-cloud-backup/v1` (ADR-073)
- Hash domains: `sinhron-linked-storage/v1` (linked device DB key), `sinhron-backup-tag/v1` (cloud backup device prefix); AEAD AAD `sinhron-chat-backup-root-v1`
- Sig domains: `sinhron-register-v1:`, `sinhron-upload-kp-v1`, `sinhron-ws-auth-v1:`, … (all in `ALL_SIG_DOMAINS`)
- Server binding (ADR-086): everything the server checks (WS login, action proofs, registration) is signed as `sinhron-server-host-v1:` ‖ server host ‖ 0x00 ‖ message. The app takes the host from its server URL (`HttpApi::host`, `sinhron_net::url_host`), never from a DNS-fallback address; the server accepts only its own names (`SINHRON_PUBLIC_HOSTNAME`, `proof::public_hosts`). Unbound (old) signatures are refused.

**Invariant:** all sig domains pairwise-non-prefix. Test: `server/src/handlers/proof.rs::tests::signature_domains_are_pairwise_non_prefix`.

### 4.5. Timestamps

- **Local time** for UI display (Flutter `DateTime.now()`)
- **Server-corrected time** for action proofs (`sinhron_net::clock_drift::corrected_now_secs`) — Risk #4
- **UTC unix-seconds (i64)** for all proto fields, DB columns (`TIMESTAMPTZ`)
- **Monotonic** time for retry backoffs (`Instant::now`)

### 4.6. Concurrency model

**Client:**
- Single `tokio` runtime (provided by flutter_rust_bridge)
- All FFI async fns serialize через `tokio::sync::Mutex<Option<SyncClient>>` etc.
- Each crate maintains internal singletons (NET_CLIENT, SYNC_CLIENT, DB)
- `&mut self` pattern on SyncClient async methods to avoid Sync requirement (Risk #3)

**Server:**
- `tokio::main` multi-thread runtime
- `SessionRegistry: Arc<RwLock<HashMap<Uuid, Vec<...>>>>` — multi-task read/write
- `RateLimiter` uses `parking_lot::Mutex<HashMap>` per action
- DB pool: `sqlx::PgPool` (Arc internally, lock-free)
- Retention worker on own task spawned at startup

---

## 5. Protocol invariants summary

| # | Invariant | Test / mechanism |
|---|---|---|
| **Identity is deterministic from phrase** | Same 24 words = same DerivedIdentity (всегда) | `derive_identity_deterministic` test |
| **All 4 sub-keys pairwise differ** | HKDF info strings unique → outputs unique | `sub_keys_are_domain_separated` test |
| **Signature domains pairwise-non-prefix** | No prefix = no domain collision | `signature_domains_are_pairwise_non_prefix` test |
| **MLS state persists across restart** | SinhronProvider opens same SQLite file | `mls_state_survives_client_restart` regression test |
| **Local SQLite encrypted at rest** | PRAGMA key applied first thing на open | `sqlcipher_locks_db_against_wrong_key` test |
| **WAL mode on for crash resilience** | apply_migrations sets WAL | `migrations_enable_wal_journal_mode` test |
| **Stale-epoch MLS doesn't panic** | Typed IncomingMessage::StaleEpoch | `stale_epoch_frame_surfaces_as_typed_variant` test |
| **Server never sees plaintext message** | Submit.ciphertext is MLS PrivateMessage TLS bytes | Code review (no `decrypt` in `handle_submit`) |
| **Phrase never logged / sent** | Zeroize after use | Risk #6 audit |
| **State backup AEAD'd by phrase-derived key** | AES-256-GCM with backup_key | `wrong_phrase_cannot_decrypt` test |
| **Rate-limit enforced on /v1/identity** | RateLimiter::check_register | `rate_limiter_isolates_keys` test |
| **TLS pinning fail-closed in release** | release build panics on malformed PEM | cfg(debug_assertions) gate |

---

## 6. Что **НЕ** в архитектуре сейчас

См. `docs/tech-debt.md` § 4 для полного списка deferred items. Высокоуровневое:

- ~~**Calls** (LiveKit + coturn + SFrame)~~ — **реализовано** (Stages CA–CF, ADR-015). Остаётся только CE2 PushKit — cert-blocked. См. §10 в spec-compliance таблице ниже.
- ~~**Медиа в чате**~~ — **реализовано** (ADR-017: зашифрованные блобы, фото, голос, видео, документы)
- **Group calls** — сделаны в коде (ADR-024), не проверены на устройствах
- **Multi-device** — сделано (ADR-025, QR-привязка ADR-027, история последних 200 сообщений на новое устройство); не проверено на двух iPhone (tech-debt 4.2)
- **Sealed sender** — HPKE-конверты (ADR-023) и отправка без аутентификации (ADR-026); IP отправителя — вне протокола
- **APNs production cert** — server payload ready, operator must configure
- **Federation** — out of v1 scope
- **Web client** — out of v1 scope

---

## 7. Diagrams + dependencies

### Crate dependency graph

```
Flutter app (Dart)
    ↓ FFI
sinhron_core (cdylib)
    ↓ uses all of:
    ├── sinhron_crypto  ← stand-alone (only ed25519, x25519, hkdf, openmls)
    ├── sinhron_storage ← uses: rusqlite (with sqlcipher feature)
    ├── sinhron_net     ← uses: tokio-tungstenite, rustls, prost (own .proto)
    └── sinhron_sync    ← uses: openmls, reqwest, aes-gcm
                          └── depends on: sinhron_crypto, sinhron_net, sinhron_storage

sinhron_cli ← uses sinhron_sync + sinhron_net + sinhron_storage + sinhron_crypto
                (bypasses sinhron_core / FFI)

────────────────────────────────────────

sinhron_server (separate workspace) ← stand-alone, uses:
    axum, sqlx (postgres), prost (own .proto MIRROR of client),
    ed25519-dalek (mirror), tower-http, prometheus, parking_lot
```

### File dependency graph (within sinhron_sync — densest crate)

```
sinhron_sync/src/
├── lib.rs              ← re-exports all
├── identity.rs         ← MlsIdentity::from_phrase. Generic <P: OpenMlsProvider>
│                          uses: sinhron_crypto::identity::derive_identity
├── provider.rs         ← SinhronProvider (composite OpenMlsProvider)
│                          uses: openmls_rust_crypto, openmls_sqlite_storage, rusqlite
├── group.rs            ← GroupHandle (MlsGroup wrapper). Generic <P: OpenMlsProvider>
│                          uses: identity, openmls
├── http_api.rs         ← HttpApi (reqwest client)
│                          uses: sinhron_net::clock_drift (for timestamps)
├── client.rs           ← SyncClient (top-level handle). Owns SinhronProvider + identity + groups
│                          uses: provider, identity, group, http_api

                            uses: http_api, sinhron_crypto::identity, sinhron_net::clock_drift
```

---

## 8. Сравнение с спекой

Спека `design_handoff_sinhron/spec/architecture.md` — эталон. Где код отклоняется — задокументировано в ADRs.

| Спека § | Реализация | Отклонение / ADR |
|---|---|---|
| §5.2 Toolchain pins | Flutter 3.41.5, Rust 1.94.1, frb 2.11.1, axum 0.8.9, sqlx 0.8.6 | Pinned точно — `.fvmrc` = 3.41.5, ровно как в спеке (upstream на 2026-05-18 был 3.41.9; бамп сознательно не делали). Rust-тулчейн не закреплён (stable, не ниже 1.94.1). Полная сверка — `PROJECT.md` §4. |
| §5.2 SQLite client | Spec: sqlx. Реал: rusqlite | ADR-008: openmls_sqlite_storage требует rusqlite. Spec deviation documented. |
| §6.1 TLS pinning | TlsPinning struct, opt-in via env | ADR? (нет explicit, но WU B3 описал) |
| §6.2 Identity (BIP-39, HKDF) | derive_identity → 4 sub-keys | ✓ Per spec. ADR-014 (HKDF info changes when added sub-key). |
| §6.3 KeyPackages | publish/consume HTTP endpoints | ✓ |
| §6.4 MLS groups | openmls 0.9.2 (с 0.8.1 — status 251), ratchet_tree_extension | ✓. ADR? Use cipherusite via MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519. |
| §6.5 Multi-device pairing | 🟡 ADR-025 + ADR-027 | Лист и сертификат на устройство, `/v1/devices`, синхронизация, отзыв, QR-привязка (`/v1/pairing`), история на новое устройство; ключ личности только на первом устройстве — отзыв любого другого запирает его на сервере |
| §6.5 Sealed sender | ✅ ADR-023 + ADR-026 (без аутентификации, ключ доступа) | HPKE-конверт на еженедельный ключ доставки; сервер не видит группу; `SealedSubmit`, `/v1/sealed-keys`, `open_sealed` в одной функции |
| §6.6 Epoch lifetime / update policy | NOT EXPLICIT в client. openmls handles internally | Spec policy: 1 update/day if app msgs, иначе weekly. Не enforced — openmls default sufficient. |
| §6.7 Local secure storage (Keychain) | Phrase в RAM, never Keychain | Spec wants flutter_secure_storage. Deferred. |
| §6.8 Recovery phrase + state backup | ✓ T1.2 implemented | ADR-012 |
| §6.10 SQLCipher at rest | ✓ T1.1 implemented | ADR-011. Note: chats DB plain on first boot (tech-debt 1.1) |
| §7 Backend (Axum + sqlx + Postgres) | ✓ Stage A 12 WUs | ADR-001…010 |
| §7.4 Tables | 14 migrations (code-map.md) | Per spec; minor name differences (`state_backups` not `state_backup`) |
| §9 Message lifecycle | ✓ Submit + fanout + Resume | ADR-005 (per-recipient seq) |
| §9.3 Conflict resolution | Partial (graceful drop, no auto-retry) | T C5 base only |
| §9.4 Push notifications | Server payload contract ready | T E3. iOS cert deferred. |
| §10 Calls | ✓ 1:1 audio+video реализованы | LiveKit v1.11.0 + coturn 4.6.3 + SFrame (RFC 9605 §5.2) из MLS exporter. Stages CA–CF закрыты. ADR-015. Блоки — CE2 PushKit (нужен Apple Dev cert) и проверка на устройствах. Group calls — ADR-024 (сигналинг, ключи на каждого участника, видео-сетка). Плохая связь / слабые телефоны — ADR-041 (пресеты — с ADR-046 1080p/720p с гибким потолком по связи и нагреву, слабый Android 360p, H.264 где есть кодер, Opus speech + DTX + RED, полоски качества, авто-«только звук», `allow_pause` и список кодеков на сервере). Показ экрана — ADR-061 (вторая видеодорожка того же участника под тем же SFrame; iPhone — Broadcast Upload Extension + App Group, Android — MediaProjection + foreground service). |
| §11 Media handling | ✓ ADR-017 | Зашифрованные блобы (`/v1/media`), фото, голос, видео, документы. Стикеры (ADR-049) — фото с полем `sticker` (анимация отдельным блобом), наборы — зашифрованный объект `PackFile`; набор Telegram по ссылке сервер берёт ботом оператора (`/v1/stickers/telegram`, ADR-062). Не путать с §10 — медиа звонков идёт через LiveKit отдельно. |
| §13 Privacy invariants | Documented in threat-model.md + 10 invariants in proof.rs/Risk #6 | ✓ |

---

**Конец architecture.md.** Дальше — `docs/code-map.md` для file-level lookup, `docs/tech-debt.md` для known issues, `docs/decisions.md` для history of choices.
