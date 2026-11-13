# Sinhron · план реализации звонков

> **Operator decisions (locked 2026-05-23):**
> - **Scope:** audio + video оба (не milestone-split).
> - **SDK:** `livekit_client` Flutter SDK (NOT raw WebRTC).
> - **Apple Developer Program:** НЕ покупается сейчас → **E2 (PushKit) DEFERRED** до приобретения cert. **E1 (CallKit) PARTIAL** — будет реализован для foreground-only сценариев; lock-screen incoming не работает без cert. Документируется как known limitation.
>
> **Назначение.** Подробный WU-breakdown для реализации 1:1 audio + video calls (спек-Фаза 7). Group calls (спек-Фаза 8) описаны отдельной секцией как **deferred follow-up** — структурно те же шаги + extra UI + key derivation для N>2 leafs.
>
> **Когда обновлять:** при закрытии WU — отмечать ✅ + дата + commit ref. При обнаружении нового risk / open-question — секция в конце. Большие переписки → ADR в `decisions.md`.
>
> **Источники правды:**
> - Спека звонков: `design_handoff_sinhron/spec/architecture.md` §10 (звонки) + §11 (медиа). 
> - SFrame: RFC 9605 §5.2 (key derivation).
> - LiveKit docs: [docs.livekit.io](https://docs.livekit.io) — E2EE + custom key provider.
> - Что построено: `docs/PROJECT.md` §2 + §2.5 (phase mapping).
> - Что НЕ построено: `docs/PROJECT.md` §3.

---

## 0. TL;DR

**Цель:** к концу этого плана Alice и Bob могут позвонить друг другу из мобильного приложения (iOS), увидеть/услышать друг друга, разговор шифруется E2E (LiveKit видит только SRTP-cipher, MLS видит только metadata).

**Scope (включаем):**
- 1:1 audio call
- 1:1 video call (front camera, no screen-share)
- Push notification "incoming call" (CallKit-style native iOS UI)
- E2EE через SFrame + MLS exporter
- Server-issued LiveKit JWT + TURN credentials
- Network resilience: TURN relay через coturn для NAT traversal

**Scope (НЕ включаем — deferred):**
- Group calls (≥3 leafs) — спек-Фаза 8, ~2-3 недели extra после 1:1
- Screen share — Apple WWDC 2024 ReplayKit, отдельный effort
- Recording (как server-side, так и client-side)
- Background calls в режиме PiP (iOS 14+ feature, отдельная работа)
- Android — мы iOS-only пока

**Estimate:** 6-8 недель solo-full-time. С учётом ревью / debug / network testing — **8-10 недель**. Совпадает с предыдущей грубой оценкой в tech-debt.md §4.1.

---

## 1. Что уже готово (foundations)

### 1.1. UI экраны звонков (Phase 1 — закрыта)

Из `docs/status.md` и `client_flutter/lib/features/`:

| Feature dir | WU | Что есть |
|---|---|---|
| `calls/` | WU 23 | **1:1 call screen** — 3 состояния (ringing / connected / ended) × 2 media (audio / video). Visual only — без real signaling. |
| `call_participants/` | WU 41 | Participants modal (для group, но visual готов) |
| `group_calls/` | WU 42 | Group call layouts (2×2 / 3×3 / spotlight) — visual only |
| `active_call_bar/` | WU 40 | Mini-bar overlay над ChatList с timer + Mute / End |
| `calls_list/` | WU 57 | Call history (фейк-данные) |

**Что значит:** все pixels уже нарисованы. Нужно wire-up real state.

### 1.2. Криптография + MLS (Phase 2 — закрыта)

- MLS-группы работают end-to-end (`examples/full_e2e.rs`)
- `sinhron_crypto::mls::*` — OpenMLS 0.8.1 обёртки
- `MLS exporter_secret` — доступен через openmls API (нужен для SFrame key derivation)
- 1:1 чат **= MLS-группа из 2 leafs** — её exporter_secret будет ключевым корнем звонка (спек §10.5)

### 1.3. Server infrastructure (Phase 2 — закрыта)

- Axum 0.8 + Postgres 16 + WS subprotocol
- docker-compose с server + postgres + caddy
- Rate limiting, metrics, structured logs
- Action-proof signatures (Ed25519 + monotonic timestamp — CRIT-1.4)

### 1.4. APNs payload contract (E3 — partial)

- `server/src/push.rs` имеет payload struct
- Реального APNs cert нет (требует Apple Developer Program). Это блокер для VoIP push — **частично** перекрывается LiveKit signaling, но lock-screen incoming call UX требует PushKit (см. Stage E2).

---

## 2. Архитектура (high-level)

```
┌──────────────────┐                                  ┌──────────────────┐
│ Alice's iPhone   │                                  │ Bob's iPhone     │
│                  │                                  │                  │
│ Flutter UI       │                                  │ Flutter UI       │
│  ↕               │                                  │  ↕               │
│ sinhron_call     │                                  │ sinhron_call     │
│  (Rust FFI)      │                                  │  (Rust FFI)      │
│  ↕               │                                  │  ↕               │
│ livekit_client   │◄─── SRTP (DTLS-encrypted) ───┐  │ livekit_client   │
│  (Flutter pkg)   │                              │  │  (Flutter pkg)   │
└──────────────────┘                              │  └──────────────────┘
        │                                         │           │
        │ WS sinhron.v1 (signaling)               │           │ WS sinhron.v1
        │  - CallInvite                           │           │
        │  - CallAccept                           │           │
        │  - CallEnd                              │           │
        ▼                                         ▼           ▼
┌──────────────────────────────────────────────────────────────────────┐
│ sinhron-server (Axum)                                                │
│  - POST /v1/call/token   → mint LiveKit JWT for room                 │
│  - GET  /v1/call/turn    → TURN creds (TTL 1h)                       │
│  - WS handlers for CallInvite/Accept/End                             │
│  - CallSession registry (in-memory)                                  │
└──────────────────────────────────────────────────────────────────────┘
        │                          │
        │ LiveKit API (HTTP)       │ no direct media — only metadata
        ▼                          │
┌──────────────────────┐           │
│ LiveKit SFU          │◄──── WebRTC media (SRTP) ────► Alice + Bob clients
│ (Go, docker)         │
│  - rooms             │
│  - participants      │
│  - SFRAME via custom │
│    key provider      │
└──────────────────────┘
        ▲
        │ ICE candidates (STUN/TURN)
        │
┌──────────────────────┐
│ coturn               │
│ (network_mode: host) │
└──────────────────────┘
```

### Trust model

- **LiveKit видит** только зашифрованные SRTP-пакеты + metadata (participant IDs, track types). НЕ видит plaintext audio/video.
- **sinhron-server видит** только signaling (CallInvite/Accept/End) + mints JWT. **НЕ видит** media. **НЕ видит** SFrame keys.
- **SFrame keys** генерируются клиентом из MLS exporter, который **сервер никогда не видел** (MLS encrypts group secrets E2E).
- **TURN credentials** — short-lived (1h), shared secret REST-API per RFC 5766 + coturn `--use-auth-secret`.

### Key derivation (спек §10.3)

```
MLS group (1:1 chat = 2 leafs Alice + Bob)
   exporter_secret  (rotates on every Commit = every member add/remove/update)
        │
        │ MLS-Exporter("SFrame 1.0 Base Key", "", 32 bytes)
        ▼
   sframe_epoch_secret
        │
        │ HKDF-Expand(sender_index, 32 bytes)
        ▼
   sender_base_key[i]    (per-participant)
        │
        │ HKDF-Extract/Expand per KID
        ▼
   sframe_key + sframe_salt   (passed to LiveKit setKey)
```

KID layout (Figure 8 RFC 9605): `(context << (S+E)) + (sender_index << E) + (epoch mod 2^E)` с `S=6, E=4` (16 epochs in keyring, до 64 active senders — overkill для 1:1, ready для group).

---

## 3. Stage breakdown

### Stage A — Infrastructure (~1 неделя)

LiveKit + coturn в docker-compose. Server endpoints для JWT + TURN creds. Без клиентских изменений.

| WU | Subject | Что строим | Зависимости | Effort |
|----|---|---|---|---|
| **A1** | docker-compose: livekit + coturn | Add `livekit/livekit-server:v1.11.0` + `coturn/coturn:4.6.3-r2-alpine` services. Configure LiveKit `dev` keys (overridable). coturn `network_mode: host` + UDP relay range 49152-65535. Healthchecks. | — | 4-6 ч |
| **A2** | Env + secrets contract | `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `LIVEKIT_HOST` (e.g. `http://livekit:7880`), `TURN_SERVER` (e.g. `turn:host.ip:3478`), `TURN_SHARED_SECRET`. Update `deploy-guide.md` § "Calls infrastructure". Operator must provision their own secrets (NEVER ship defaults). | A1 | 2-3 ч |
| **A3** | `POST /v1/call/token` endpoint | New `server/src/handlers/call.rs`. Verify action-proof. Mint LiveKit JWT via `livekit-api` crate (Rust) with claims: `room`, `identity` (user_pk), `metadata` (group_id), `ttl=1h`. Rate-limit (default 30/min per user_pk). Response: `{ token, livekit_url, expires_at }`. | A1, A2 | 6-8 ч |
| **A4** | `GET /v1/call/turn` endpoint | Generate TURN creds REST-API style per RFC 5766: `username = unix_ts + ":" + user_pk_hex`, `credential = HMAC-SHA1(shared_secret, username)`. TTL 1h. Response: `{ urls, username, credential, ttl }`. | A2 | 4-6 ч |
| **A5** | Smoke test infrastructure | `curl /v1/call/token` works (mock claim verification path). Manual: `lk-cli` from LiveKit's CLI tooling connects to the room. coturn `turnutils_uclient` allocate test passes. Document in deploy-guide. | A3, A4 | 3-4 ч |

**Stage A acceptance:** оператор может `docker-compose up`, увидеть `livekit/coturn` healthy, выполнить смок-тест без клиента.

---

### Stage B — Signaling protocol (~1 неделя)

WS frames для invite/accept/end. Server-side state machine. **Без media** — этот stage заканчивается возможностью logging "Alice invited Bob to call X, Bob accepted".

| WU | Subject | Что строим | Зависимости | Effort |
|----|---|---|---|---|
| **B1** | proto/sinhron.proto extensions | New oneof frames: `CallInvite { call_id, group_id, kind: AUDIO|VIDEO, livekit_room, ttl_secs }`, `CallAccept { call_id, accept: bool }`, `CallEnd { call_id, reason }`, `CallRing { call_id }` (server→clients ping for "still active"). Mirror в `server/proto/` + `client_flutter/rust/sinhron_net/proto/`. Bump version. | Stage A | 3-4 ч |
| **B2** | Server: handle_call_invite | New `ws.rs::handle_call_invite`. Verify: (1) caller is a member of group_id, (2) target group is 1:1 (membership = 2), (3) no other active call для этой группы. Generate `livekit_room = "sinhron-call-" + call_id`. Persist `CallSession` in-memory registry. Forward CallInvite to recipient user_pk (через `push_to_user`). Send Ack to caller. Rate-limit. | B1 | 6-8 ч |
| **B3** | Server: CallSession registry | `server/src/call_session.rs`. `Arc<RwLock<HashMap<Uuid, CallSession>>>`. Entry: `{ call_id, group_id, caller_user_pk, callee_user_pk, status (Ringing/Active/Ended), created_at, last_activity }`. GC idle sessions (> 60s without progress). Metrics: `calls_active`, `calls_total`. | B2 | 4-6 ч |
| **B4** | Server: handle_call_accept / handle_call_end | Auth: only caller or callee can change status. On Accept: status → Active, broadcast to both. On End: status → Ended, broadcast, remove from registry after 5s grace. | B2, B3 | 4-6 ч |
| **B5** | Server: ringing watchdog | If status=Ringing > 30s without Accept → auto-CallEnd reason="no_answer". Tokio task in `call_session::spawn_watchdog`. | B3 | 3-4 ч |
| **B6** | Server: tests | sqlx::test (если БД нужна) + plain unit tests for CallSession FSM. Cases: invite-accept happy path, invite-reject, invite-timeout, double-invite-rejected, non-member-rejected. **8 tests min.** | B2-B5 | 6-8 ч |

**Stage B acceptance:** через `sinhron_cli` (или curl-сценарий через WS) две инстанции могут invite/accept/end. В server logs виден полный lifecycle. Никакой media yet.

---

### Stage C — Rust call crate + SFrame keys (~1.5 недели)

Новый `sinhron_call` crate. Wire через FFI. **SFrame key derivation** — точная имплементация RFC 9605 §5.2 на Rust. Этот stage — самый чувствительный с точки зрения корректности.

| WU | Subject | Что строим | Зависимости | Effort |
|----|---|---|---|---|
| **C1** | `sinhron_call` crate scaffold | New workspace member. Deps: `openmls` (for exporter API), `hkdf`, `sha2`, `aes-gcm` (for AES-GCM-128/256 ciphersuites per SFrame spec). `Call` struct, FSM enum `CallState`. `CallEvent` for FFI. **Tests-only initially** — no production wiring. | Stage A | 3-4 ч |
| **C2** | SFrame key derivation impl | `sinhron_call::sframe::{epoch_secret, sender_base_key, sframe_key_pair}`. Inputs: `mls_exporter_output: &[u8; 32]`, `sender_index: u32`, `kid: u64`. Outputs: `{key: [u8; Nk], salt: [u8; Nn]}`. **Test vectors** from RFC 9605 Appendix A (если доступны) ИЛИ от LiveKit reference impl. **5+ tests.** | C1 | 8-10 ч |
| **C3** | MLS-Exporter binding | Connect `sinhron_sync::SyncClient::group_exporter(&group_id, label, context, length)` через openmls's `MlsGroup::export_secret`. Returns 32 bytes. Test: same group → same exporter for same (label, context, length). | C2 | 4-6 ч |
| **C4** | Call FSM | `Call::new(call_id, group_id, role: Caller|Callee)`. States: `Idle → Inviting → Ringing → Active → Ended`. Transitions via `handle_event(CallEvent)`. CallEvent: `RemoteAccepted, RemoteRejected, RemoteEnded, LocalEnd, NetworkLost, ConnectedToLiveKit, Timeout`. **10+ FSM tests** (happy paths + all error transitions). | C2 | 6-8 ч |
| **C5** | KID rotation on MLS Commit | When `sinhron_sync` applies Commit (epoch → epoch+1), notify `sinhron_call` for active calls in that group. Recompute `sender_base_key` for new epoch. Maintain overlap window (2 epochs in keyring) per spec §10.4. | C3, C4 | 6-8 ч |
| **C6** | FFI surface in `simple.rs` | `call_invite(group_id, video: bool) -> CallId`, `call_accept(call_id)`, `call_reject(call_id)`, `call_end(call_id)`, `call_next_event() -> CallEvent`, `call_get_livekit_token(call_id) -> String`, `call_get_sframe_keys(call_id) -> Vec<(KeyIndex, KeyMaterial)>`. FRB codegen. | C1-C5 | 6-8 ч |
| **C7** | sinhron_cli `call` subcommand | `sinhron-cli call invite <peer>` / `accept <call_id>` / `end <call_id>`. For integration testing без Flutter. Stays in `--no-media` mode (just signaling). | C6 | 4-6 ч |
| **C8** | End-to-end test (Rust-only) | `examples/calls_e2e.rs` — two SyncClients, Alice invites Bob, accept, exchange SFrame keys, end. Validates: keys match between Alice's "outgoing" and Bob's "incoming" derivation paths for the same epoch. No real WebRTC — just key + signaling check. | C7 | 6-8 ч |

**Stage C acceptance:** `cargo run --example calls_e2e` passes. Two MLS members derive identical SFrame keys for the same (epoch, sender, KID) tuple. FSM regression tests cover all 16+ transitions.

---

### Stage D — Flutter integration (~1.5 недели)

LiveKit Flutter SDK + permission requests + wire UI к real signaling.

| WU | Subject | Что строим | Зависимости | Effort |
|----|---|---|---|---|
| **D1** | `livekit_client` dep + iOS Info.plist | Add `livekit_client: =2.x.x` (latest stable at impl time) к pubspec.yaml (exact pin per §18.9). Update `ios/Runner/Info.plist`: `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`. Background mode `voip`. iOS-only Podfile updates. **Verify iOS Sim build passes** before D2. | Stage C | 4-6 ч |
| **D2** | Permissions service | `lib/core/services/permissions.dart`. Async API: `requestCamera() / requestMic() → Granted/Denied/Permanent`. Wire с `permission_handler` package (or `livekit_client` provides). UI shows "permission_denied" state for declined paths (Phase 1 WU 39 already has screen). | D1 | 3-4 ч |
| **D3** | Active call state (Riverpod) | `lib/features/calls/active_call_provider.dart`. `StateNotifier<ActiveCallState>`. States: `idle, outgoing (ringing), incoming (ringing), connected, ended`. Subscribes to `NetEvent` stream + `call_next_event` from sinhron_call. Holds: `room (livekit_client.Room?)`, `localParticipant`, `remoteParticipants`. | D2 | 6-8 ч |
| **D4** | Outgoing call flow | ContactInfo screen + ChatView → "Call" button → `activeCallProvider.invite(peer, video)` → CallInvite frame sent → navigate to call_screen.dart (ringing state). | D3 | 4-6 ч |
| **D5** | Incoming call flow | NetEvent `CallInvite` → push full-screen call_screen.dart in incoming state. Accept → `call_accept(call_id)` + connect к LiveKit room. Reject → `call_reject(call_id)`. | D3 | 4-6 ч |
| **D6** | LiveKit room connect + SFrame key install | When call → Active: fetch JWT via `POST /v1/call/token`, fetch TURN creds via `GET /v1/call/turn`. `Room.connect(url, token, RoomOptions(e2ee: E2EEOptions(keyProvider: SinhronKeyProvider(...))))`. SinhronKeyProvider reads from `sinhron_call::call_get_sframe_keys` via FFI. | D5 | 8-12 ч |
| **D7** | Active call UI wire-up | Phase 1 WU 23 screen now driven by `activeCallProvider`. Mute/unmute → `localParticipant.setMicrophoneEnabled(...)`. Camera flip → `localParticipant.switchCamera()`. Hangup → `room.disconnect() + call_end(call_id)`. Timer ticks. | D6 | 6-8 ч |
| **D8** | Active call bar overlay | Phase 1 WU 40 mini-bar — wire to `activeCallProvider`. Visible когда status ∈ {ringing, connected}. Tap → return to call_screen. | D7 | 3-4 ч |
| **D9** | Call history persistence | Append `calls(id, peer_user_pk, kind, status, duration_secs, started_at)` row on CallEnd. WU 57 screen (call history) reads from this. | D7 | 4-6 ч |

**Stage D acceptance:** iOS Simulator → second iOS Simulator (same Mac) — Alice calls Bob, Bob sees incoming, accepts, both see/hear each other через LiveKit room. End hangs up cleanly.

---

### Stage E — iOS native polish (~1 неделя)

CallKit, PushKit, audio session, locked-screen UX.

| WU | Subject | Что строим | Зависимости | Effort |
|----|---|---|---|---|
| **E1** | CallKit integration | iOS native plugin (Swift): `CXCallController`, `CXProvider`. On incoming CallInvite → `provider.reportNewIncomingCall(...)`. User accepts via lock-screen Apple UI → bridge calls back to Flutter via MethodChannel. **Hard prerequisite for production UX** — без CallKit incoming call в lock state не показывается. | D5 | 12-16 ч |
| **E2** | PushKit VoIP push | Apple Developer cert ($99/yr — operator responsibility). New `voip` push type. Server-side: when CallInvite recipient is offline → send PushKit notification (different cert from regular APNs). Client iOS handler → wakes app → triggers CallKit `reportNewIncomingCall`. **Without this:** incoming call работает только если app foreground. | E1, APNs cert | 10-14 ч |
| **E3** | Audio session config | iOS-specific: `AVAudioSession.setCategory(.playAndRecord, options: [.allowBluetooth, .defaultToSpeaker])`. Switch between earpiece/speaker on UI button. Handle interruptions (incoming SMS, alarm). | D6 | 4-6 ч |
| **E4** | Camera + screen rotation handling | Lock orientation in call screen (portrait). Front/back camera switch. Pre-call camera permission warm-up (so we don't pause for `Allow camera` mid-ringing). | D7 | 3-4 ч |
| **E5** | Network state handling | Network drop mid-call → show "Reconnecting" overlay → reconnect LiveKit room (built-in feature). If permanent drop > 30s → auto-end with reason="network". | D6, D7 | 4-6 ч |

**Stage E acceptance:** на физическом iPhone — incoming call поднимает CallKit UI на lock-screen с rington (Apple-default), tap accept → app opens to call_screen. Audio routes corrrectly через earpiece/speaker. Network drop survives < 30s outage.

---

### Stage F — Testing + docs (~3-5 дней)

| WU | Subject | Что строим | Зависимости | Effort |
|----|---|---|---|---|
| **F1** | 2-device manual test plan | `docs/evidence/calls-manual-test-plan.md`. Scenarios: same-LAN 2x iOS Sim, cross-LAN iOS Sim + physical (TURN exercise), airplane-mode interruption, both sides hangup race, mic/cam permission denied, locked-screen incoming. **All 12 scenarios documented + status.** | Stage E | 1-2 дня |
| **F2** | ADR-015 LiveKit + SFrame architecture | New ADR: why LiveKit (vs raw WebRTC, vs Daily, vs Twilio), why custom KeyProvider (vs SDK e2ee defaults), what's the failure-recovery story when SFrame keys drift. **~250 LOC ADR.** | Stage E | 4-6 ч |
| **F3** | Update PROJECT.md + tech-debt.md | PROJECT.md §2.5 — спек-Фаза 7 → ✅. tech-debt.md §4.1 — split: 1:1 calls CLOSED, group calls moved to spec-Фаза 8. Update §3 "Что НЕ построено" — calls 1:1 removed. | Stage E | 2-3 ч |
| **F4** | code-map.md updates | New `sinhron_call/` entries. New server `handlers/call.rs`, `call_session.rs`. New Flutter `features/calls/active_call_provider.dart`, etc. | Stage E | 1-2 ч |
| **F5** | onboarding.md — calls section | Add "How to test calls locally" section. `docker-compose up` includes LiveKit. Two simulators. | Stage E | 2-3 ч |

**Stage F acceptance:** documentation parity with the code. Next contributor может прочитать PROJECT.md → понять что calls 1:1 ✅.

---

## 4. Tech stack additions

**Server:**
- `livekit-api = "=0.4.14"` (JWT minting + room admin API)
- `hmac = "=0.12.1"` (TURN cred HMAC — already may be transitively)
- New: `livekit/livekit-server:v1.11.0` Docker image
- New: `coturn/coturn:4.6.3-r2-alpine` Docker image

**Rust client (`sinhron_call`):**
- `openmls` (workspace, already pinned)
- `hkdf = "=0.12.4"` (already in sinhron_crypto deps tree)
- `sha2 = "=0.10.9"` (already)
- `aes-gcm = "=0.10.3"` (already in sinhron_sync)
- **NO** `libwebrtc` Rust binding — оставляем media transport Flutter-side per спек §10.6

**Flutter:**
- `livekit_client = "=2.x.x"` (exact pin once we choose latest stable)
- `permission_handler = "=11.x.x"` (or whatever current pinned)
- iOS: CallKit + PushKit Swift integration — pure platform channels

**iOS Info.plist additions:**
- `NSCameraUsageDescription`
- `NSMicrophoneUsageDescription`
- `UIBackgroundModes`: `voip`, `audio`
- `NSFileProtectionComplete` (already from tech-debt 2.6 closure если closed)

**Все версии — exact pin per §18.9.** Когда choose `livekit_client` version — update PROJECT.md §4 (Tech stack pin) — единый SSoT.

---

## 5. Open questions / risks

### 5.1. LiveKit Flutter SDK e2ee maturity

🟡 LiveKit's Flutter `e2ee` API менее обкатан чем JS / Swift / Kotlin. Custom KeyProvider documented но examples primarily на JS. Mitigation: prototype в Stage D6 — если SDK не позволяет inject keys без modification, fallback на raw `BaseKeyProvider` через method channel + Swift.

### 5.2. PushKit + Apple Developer Account

🔴 Без Apple Developer Program ($99/yr) — нет PushKit push, нет CallKit production usage. **Без CallKit** — incoming call работает ТОЛЬКО когда app foreground. Это deal-breaker для production UX. Mitigation: Stage E1+E2 могут быть split — E1 (CallKit без push) можно сделать без cert; E2 (PushKit) ждёт оператора.

### 5.3. coturn UDP relay range

🟡 `network_mode: host` блокирует Docker Compose networking — coturn должен слушать прямо на host. Для production это нормально, но локальная dev environment (Mac → Mac) может работать без TURN — ICE host candidates сами по себе достаточны. Документировать в deploy-guide.

### 5.4. SFrame test vectors

🟡 RFC 9605 Appendix A test vectors exist но не все cipher suites покрыты. Mitigation: cross-validate с LiveKit's own Go test vectors (libsframe).

### 5.5. Group calls (Фаза 8) — что ломается при ≥3 leafs

🟢 Same MLS group → same exporter. KID encoding уже supports sender_index до 64. Real work: UI (group_call_layouts уже visual ready), CallSession registry (1:N forwards), key rotation under member churn during active call. **~2-3 недели extra после 1:1 ship.**

### 5.6. Network resilience during MLS Commit

🟡 Если во время активного звонка Alice добавляет Charlie в MLS-группу (Commit) — epoch меняется, SFrame keys ротейтятся mid-stream. Spec §10.4 описывает overlap window. Тест: ручной scenario — invite + accept + add member + verify all media still decryptable.

### 5.7. Background audio для locked-screen call

🟡 iOS требует `UIBackgroundModes: voip` AND active CallKit session для непрерывного audio после lock. Без этого audio cuts ~30s после lock. Покрывается Stage E1.

---

## 6. Acceptance criteria

**1:1 calls работают, если:**

1. ✅ Alice (iOS Sim) → Bob (iOS Sim) на одной WiFi:
   - Audio call: connect <5s, talk оба слышат друг друга, end clean
   - Video call: connect <8s, обе камеры видны, end clean

2. ✅ Alice (iOS Sim) → Bob (physical iPhone, cellular) — TURN-relay exercise

3. ✅ Bob declines incoming call → Alice видит "Call ended" → call history shows "Missed" entry for Bob

4. ✅ Network drop mid-call (airplane mode 5s) → auto-reconnect → continue

5. ✅ App backgrounded → audio continues (lock screen call active)

6. ✅ Caller hangs up → callee sees "Call ended" immediately

7. ✅ Server crash mid-call → both clients show "Connection lost" within 30s + auto-cleanup

8. ✅ MLS-group of 2 = 1:1 chat. NO new MLS group created для звонка — переиспользуется существующая

9. ✅ Two clients with same MLS state derive identical SFrame keys (Stage C8 example)

10. ✅ LiveKit logs show NO plaintext audio bytes (только SRTP)

11. ✅ Hangup → all SFrame keys for that call wiped from clients within 30s

12. ✅ Rate-limit: > 30 calls/min from same user_pk → 429

---

## 7. Dependencies + parallelization

```
Stage A (infra)  ───┐
                    ├──> Stage B (signaling) ───┐
                    │                            ├──> Stage D (Flutter)  ──> Stage E (iOS polish)  ──> Stage F (testing)
                    └──> Stage C (Rust + SFrame)─┘
```

- Stage A and B can be parallelized (different layers).
- Stage C depends only on Stage A (LiveKit creds contract).
- Stage D depends on **both** B and C.
- Stage E builds on D — but E1 (CallKit) can be prototyped early.
- Stage F is sequential at end.

If solo: roughly linear A → B → C → D → E → F. **~6-8 weeks calendar time.**

If two devs: A+B in parallel, C runs alongside B end, D starts after both. **~4-5 weeks.**

---

## 8. Что НЕ делаем в этом плане

| Что | Почему отложено |
|---|---|
| Group calls (≥3 leafs) | Спек-Фаза 8. Architecture готова, +2-3 недели extra UI/UX/testing. |
| Screen share | iOS ReplayKit — отдельный effort, ~1 неделя. |
| Recording (client or server) | Out of v1 scope. Security/legal implications. |
| Background → Picture-in-Picture | iOS 14+ feature, отдельный widget. |
| Android | Phase 2 client-side spec deviation — мы iOS-only пока. |
| Federated calls (cross-server) | §19 open question. |
| Encrypted call metadata (call_id, group_id leak) | Текущая impl: server видит group_id. Sealed-sender variant — отдельный effort. |
| 1080p+ video / spatial audio | LiveKit default 720p достаточно для v1. |
| Voice messages | Не calls per se. Это Фаза 6 (media) — отдельный effort. |

---

## 9. Update discipline

При закрытии WU:
1. Изменить `[ ]` → `[x]` в этом файле с датой
2. Сделать запись в `docs/status.md` (формат: WU описание + tests + результат)
3. Если новый компонент / endpoint — update `PROJECT.md` §2 "Что построено" + `code-map.md`
4. Если new ADR — `decisions.md`
5. **При закрытии Stage целиком** — `tech-debt.md` § 5 "CLOSED" entry

При обнаружении нового risk → § 5 этого файла. Если risk material — escalate владельцу.

**В commit message:** `WU CA1: docker-compose LiveKit+coturn` style.

См. `PROJECT.md §9 (дисциплина обновления)` для полного списка правил.

---

## 10. Связь с другими docs

- **Spec:** `design_handoff_sinhron/spec/architecture.md` §10 (звонки), §11 (media — для video frames), §12 (deploy), §13 (privacy invariants для calls)
- **Phase mapping:** `PROJECT.md` §2.5 — этот план closes спек-Фаза 7
- **Что-есть-сейчас:** `PROJECT.md` §2 (UI готов, MLS работает, server infrastructure готова)
- **Что-не-делаем-сейчас:** `PROJECT.md` §3 (calls deferred — этот план это меняет)
- **Architecture:** `docs/architecture.md` обновится новой секцией "Calls" после Stage F4
- **ADRs:** ADR-015 (planned) — LiveKit + SFrame architecture rationale

---

## 11. Phasing notes

**Если хочется ship asap minimal viable calls:**

Можно cut scope ещё раз и сделать **audio-only 1:1 как первый milestone (~3 недели):**
- Stage A: full (infra is full)
- Stage B: only AUDIO kind в proto (skip video field handling)
- Stage C: same (SFrame doesn't care about audio vs video)
- Stage D: audio-only UI (skip camera permission/preview/switching)
- Stage E1: CallKit minimal (audio only)
- Stage E3: audio session full

Затем video as +2 weeks on top.

**Если оператор хочет push-to-production faster:** make Stage E2 (PushKit) blocking only for "production-ready", not "feature-complete". Feature works на foreground без PushKit; lock-screen вызовы — следующий effort.

---

**Конец плана. Старт когда оператор approves.**
