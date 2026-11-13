# Sinhron · Architecture Decision Records (ADR)

Каждое решение — короткий блок: что решено, когда, почему, какие альтернативы рассматривались. **Решения здесь — не в спеке;** спека — это «состояние мира как оно есть». ADR — «как мы туда пришли».

---

## ADR-001 · Имя проекта = Sinhron, никаких кодовых

**Дата:** 2026-05-18
**Решение:** Имя `Sinhron` — единственное название продукта. «Citadel» (упоминавшийся в спеке как «внутреннее кодовое имя») больше не используется нигде — ни в коде, ни в комментариях, ни в документации.
**Почему:** Двойное имя создаёт путаницу + слабую брендовую идентичность. Эстетически и операционно одно имя проще.
**Импакт:** Все Rust-крейты переименованы `citadel_*` → `sinhron_*`, спека отредактирована глобально (33 правки).

---

## ADR-002 · §17.6 «Конструктивное возражение» добавлено в спеку

**Дата:** 2026-05-18
**Решение:** Claude Code **обязан** возражать архитектору, если видит, что предложенный подход хуже доступной альтернативы. Формат возражения — 4 пункта: что меняется, почему хуже, что вместо, цена миграции. Финальное слово — за владельцем.
**Почему:** Молчаливое подчинение приводит к плохому коду + поздним rework'ам. Архитектор хочет, чтобы исполнитель поднимал red flags.
**Не подлежит возражению:** §3 (непереговариваемые принципы), §18 (DO NOT list), стилистические мелочи внутри одного крейта.

---

## ADR-003 · Passkey-регистрация (WebAuthn) отклонена

**Дата:** 2026-05-19
**Решение:** Спека остаётся с challenge-response через Ed25519 (§6.1). Passkey/WebAuthn **не вводится** ни в каком виде.
**Почему:**
- MLS требует сотни подписей в секунду на active group → user-gesture per signature (Touch ID prompt) делает UX нерабочим
- iCloud Keychain Sync для passkey'ев нарушает §6.2 (каждое устройство = отдельный leaf, общий приватный ключ запрещён) и §3.2 (Apple/Google становятся third-party держателем ключа)
**Альтернатива (отложена):** «Explicit P-256 wrapper в Secure Enclave» с биометрической gateway — это правка §6.7, может быть введена позже, но не сейчас.
**Сейчас используется:** OS Keychain (iOS/macOS), Android KeyStore, Windows DPAPI — все они *внутри* используют Secure Enclave / StrongBox / TPM для at-rest wrapping. Это автоматически.

---

## ADR-004 · §6.8.1 «Owner-encrypted MLS-state backup» добавлено в 1.0

**Дата:** 2026-05-19
**Решение:** Recovery phrase теперь покрывает не только identity-ключ, но и **членство во всех MLS-группах**. Механика: локальное MLS-state (leaf private keys, group context, epoch secrets) сериализуется в CBOR, шифруется AES-256-GCM ключом, выведенным из BIP-39 фразы, заливается на сервер как одиночный blob (PUT-replace, не история). При recovery — фраза → ключ → blob → восстанавливаем leaf'ы → catch-up через серверные Commits.
**Почему:** Без этого при потере всех устройств юзер теряет все группы и должен быть «приглашён заново» каждым контактом. Это плохой UX, хуже WhatsApp. Спека до правки прямо признавала этот gap («сервер шифротекст не отдаёт, потому что новое устройство не входит ни в одну MLS-группу до явного re-invite»).
**Что НЕ покрывает:** История application-messages — она остаётся в локальной SQLCipher DB и теряется при recovery. Encrypted message history backup на S3 — отдельная 1.x фича (см. §19).
**Импакт на спеку:** §6.8 расширена, §6.8.1 новая, §6.8.2 (multi-device race) новая, §7.4 добавлена таблица `state_backups`, §13.1 расширена утечкой метаданных blob'а + recovery-phrase compromise, §19 переписана.
**Threat model:** Сервер видит размер blob'а + частоту обновлений (proxy для активности юзера). Содержимое не видит. Phrase compromise = полное вскрытие state. Митигация — padding-buckets — отложена на 1.x.

---

## ADR-005 · Phase 1 — UI-first вместо spec §16 Rust-Core-first

**Дата:** 2026-05-19
**Решение:** Откладываем строительство Rust Core (§16 Phase 1) — вместо этого в Phase 1 строим максимум Flutter-экранов на статических данных. Rust Core начнём после визуального MVP'а UI.
**Почему:** 
- Появился готовый design handoff с 74 экранами — пользователь хочет визуализировать продукт быстрее
- UI на статике можно валидировать без серверной части
- Дизайн-итерация быстрее без plumbing'а через FFI
- View-Model'и можно проектировать позже, когда понятно, что нужно UI'ю
**Цена:** Когда дойдёт до Rust Core, придётся переписать data flow с фейковых providers на frb-streams. Это ~один день работы на каждый feature, контролируемо.
**Откатываемо:** в любой момент. Структура `lib/features/*/` стабильна.

---

## ADR-006 · `client_flutter/` сохраняется, расширяется (не сносим)

**Дата:** 2026-05-19
**Решение:** Существующее `client_flutter/` (chat list работает, golden tests есть, iOS sim проверен) — **базовая точка для Phase 1**. Новые экраны добавляются в `lib/features/`. Сейчас существует `chat_list/` — будут добавлены `onboarding/`, `chat_view/`, `settings/`, и др.
**Почему:** Снос → день потерянной работы. Существующий код соответствует §8.5 (Ds*-виджеты, ноль Material defaults), Geist-шрифты установлены, fvm пин 3.41.5 работает, iOS build пройден.
**Что добавим к структуре:** `app/router.dart` (когда появится 2+ экранов), `core/ffi/` + `core/providers/` (когда подключим Rust), `l10n/` (когда подключим локализацию).

---

## ADR-007 · Документация на диске для пост-compact resilience

**Дата:** 2026-05-19
**Решение:** Создан каталог `docs/` со status.md, decisions.md, plan-phase1-frontend.md, design-handoff-index.md. Memory (`~/.claude/projects/.../memory/`) указывает на этот каталог как на source of truth.
**Почему:** При compact чата (или новой сессии) контекст разговора теряется. Файлы — нет. Любой ассистент, открывший проект, прочитает `docs/status.md` и поймёт где мы.
**Что НЕ дублируется:** Содержимое спеки и design handoff'а — это `design_handoff_sinhron/`. `docs/` — это **наши** заметки поверх + история решений.

---

## ADR-008 · Phase 2 kickoff — Rust Core layout via frb integrate

**Дата:** 2026-05-21
**Решение:** Для Phase 2 hello-world использован `flutter_rust_bridge_codegen integrate` с дефолтным layout'ом — Cargo crate в `client_flutter/rust/`, а не отдельный `core/` workspace на уровне проекта.

**Почему НЕ отдельный `core/`:**
- frb 2.11.1 `integrate` команда автоматически настраивает CocoaPods (iOS), gradle (Android), CMake (Linux/Windows/macOS) — все эти ссылаются на относительный путь `rust/`. Изменение пути требует ручной правки 5+ build-скриптов в `rust_builder/{ios,android,linux,macos,windows}/`.
- Сейчас в `rust/` лежит ОДНА крата `sinhron_core`. Когда добавим `sinhron_crypto`, `sinhron_storage` и т.д., конвертируем `rust/` в Cargo workspace (workspace `Cargo.toml` сверху + crates как поддиры). Все они будут collinked в одну `libsinhron_core.{a,dylib}` через re-exports в фасадной крате.
- Spec §5.2 говорит «workspace на клиенте» — не требует strict separation от `client_flutter/`.

**Структура сейчас:**
```
client_flutter/
  rust/                              ← Cargo crate (станет workspace)
    Cargo.toml
    src/
      lib.rs                         ← `mod api;`
      api/
        mod.rs                       ← `pub mod simple;`
        simple.rs                    ← core_version(), greet(), init_app()
  lib/
    src/rust/                        ← auto-generated Dart bindings (НЕ редактировать)
      frb_generated.dart
      frb_generated.io.dart
      frb_generated.web.dart
      api/simple.dart
  rust_builder/                      ← cargokit build glue (CocoaPods/gradle/CMake)
    ios/
    android/
    linux/
    macos/
    windows/
  flutter_rust_bridge.yaml           ← codegen config
  pubspec.yaml                       ← flutter_rust_bridge: 2.11.1
```

**Регенерация bindings:**
```bash
cd client_flutter
flutter_rust_bridge_codegen generate
```

**Цена:** Если пойдём в multi-crate workspace и не понравится layout — переезд на отдельный `core/` workspace = ~2 часа работы (правка cargokit configs + flutter_rust_bridge.yaml). Откладываем до момента когда станет реально мешать.

**Подтверждение работы:** iOS Simulator build (debug) = успешен. `main.dart` синхронно вызывает `coreVersion()` → возвращает `"sinhron_core 0.1.0 · frb 2.11.1 · rustc 1.94.1"`. OnboardingSplash рендерится после init. (Phase 2 trigger fired 2026-05-21.)

---

## ADR-009 · Riverpod 3.0 без codegen — single-file surface

**Дата:** 2026-05-21
**Решение:** Для state management на Phase 2+ берём `flutter_riverpod` 3.3.1 в hand-written варианте (без `riverpod_annotation` / build_runner). Все providers — top-level `final` constants в `lib/core/providers/`. ProviderScope оборачивает `SinhronApp` в `main.dart`.

**Почему Riverpod, а не альтернативы:**
- **vs Provider 6.x:** Riverpod — официальная эволюция от того же автора (Remi Rousselet); compile-time safety, нет BuildContext-dependency, можно читать providers вне виджет-дерева (важно для onboarding-flow logic).
- **vs Bloc:** Boilerplate в 3-4 раза выше для простых async-cached surfaces вроде `identityProvider`. Bloc силён для сложных event-driven UIs; у нас нет такого спроса в Phase 2.
- **vs InheritedWidget вручную:** Не масштабируется на десятки providers. Riverpod даёт `ref.watch` / `ref.invalidate` / `ref.listen` бесплатно.
- **vs GetIt + ChangeNotifier:** Service locator pattern ломает testability — нет нормального scope override без глобальных моков. Riverpod's `ProviderScope(overrides: [...])` для тестов — стандартный путь.

**Почему БЕЗ codegen (`riverpod_annotation`):**
- Phase 2 surface = 4 providers (`coreVersion`, `identity`, `identityFingerprint`, `unreadChatsCount`). build_runner добавляет в pipeline шаг `dart run build_runner build` после каждого изменения сигнатуры — overkill для такого размера.
- Hand-written providers читаются быстрее: видишь сразу `Provider<String>((ref) => core.coreVersion())` без слоёв сгенерированной обёртки.
- Можем переключиться на codegen позже без breaking changes — API провайдеров идентичен.

**Версии (§18.9 — exact pins):**
- `flutter_riverpod: 3.3.1` (latest stable как 2026-05-21)
- Без `riverpod_annotation`, `riverpod_generator`, `build_runner`

**Структура:**
```
lib/
  main.dart                            ← runApp(ProviderScope(child: SinhronApp()))
  core/
    providers/
      core_providers.dart              ← все Phase 2 providers (одним файлом)
```

Когда surface вырастет (5+ logical areas), разнесём по файлам: `identity_providers.dart`, `chat_providers.dart`, и т.д. — но пока 4 провайдера живут в одном файле для скорости навигации.

**Migration policy для глобальных переменных:**
- `coreVersionString` (mutable global in `main.dart`) — **оставлен** как compatibility cache до полной миграции. Новый код читает через `coreVersionProvider`.
- `persistedFingerprint` (mutable global) — **удалён**, источник правды теперь `identityFingerprintProvider`.

**Invalidation pattern:**
После записи в SQLite (например, `storageSavePhrase` в `RecoveryPhraseScreen`) вызывающий код обязан `ref.invalidate(identityProvider)` — иначе кэш FutureProvider'а сохранит старый `null` и downstream consumers (ProfileEdit и т.д.) не увидят обновление. Этот контракт документирован в doc-комменте провайдера.

**Подтверждение работы:** `fvm flutter analyze` = No issues. Все 43 widget-теста пройдены. ProfileEdit's safety-number row теперь читает реальный fingerprint из SQLite (после онбординга) или fallback `"9a3e 4d12 8b71"` (до).

---

## ADR-011 · SQLCipher для at-rest encryption локальных БД (2026-05-23)

**Контекст.** Спека §6.10 требует чтобы SQLite-файлы на устройстве (chats + MLS state) были зашифрованы на диске. Угроза: украденный разлоченный телефон → атакующий монтирует sandbox app data → читает plaintext chats / MLS keys.

**Альтернативы рассмотрены:**
1. **Application-level AES-GCM поверх pages** (упомянуто в спеке §6.7). Каждая запись/чтение SQLite — encrypt/decrypt в Rust. Сложно (page management) + нужно знать формат SQLite WAL. Отвергнуто.
2. **OS-level Keychain + plain SQLite**. Полагаемся на iOS Data Protection. Работает только пока iOS sandboxing держится; rooted/jailbroken/forensic mode — fail. Слабее.
3. **SQLCipher** (forked SQLite + AES-256-CBC encryption поверх pages, прозрачно). Industry-standard (Signal, WhatsApp use ditto). ✓ **Выбрано.**

**Решение.** `rusqlite` feature `bundled-sqlcipher-vendored-openssl` — статически линкует SQLCipher + OpenSSL в наш бинарник. iOS / macOS deploy = zero system deps.

**Ключ derivation.** PRAGMA key через 32-byte raw key из `DerivedIdentity::storage_key` (HKDF info `sinhron-storage-key/v1`). Тот же phrase → тот же ключ детерминированно (recoverable).

**Применено к:**
- `sinhron_storage` (sinhron.db: chats/messages) — переключаемая через FFI `storage_init(path, key_hex)`. Чат-БД пока открывается plain на boot (phrase ещё не известен); migration plain→encrypted via `sqlcipher_export()` — TODO.
- `sinhron_sync` SinhronProvider (sinhron-mls.sqlite: MLS state) — encrypted с момента создания, поскольку `SyncClient::new` имеет phrase в руках.

**Cost.** Бинарник вырос на ~5 MB (OpenSSL static). iOS first-build +90s (SQLCipher + OpenSSL compile). Subsequent builds кэшируются.

**Verified.** `sqlcipher_locks_db_against_wrong_key` regression test: open with key A, write row, close. Open with key B → read fails (file is not a database). Open with key A again → row present. Доказывает confidentiality guarantee на bytes-level.

**Спека compliance.** §6.10 ✓. ADR-008 (workspace layout) предусматривал rusqlite — feature swap не ломает архитектуру.

---

## ADR-012 · Owner-encrypted state backup на сервер (2026-05-23)

**Контекст.** Spec §6.8.1: пользователь должен иметь возможность восстановить чаты после смены телефона / переустановки приложения, имея только BIP-39 фразу. Без этого reinstall = все группы умерли.

**Угроза.** Operator-server compromised → атакующий читает все чаты всех пользователей.

**Решение.** Client-side encrypt (AES-256-GCM) под `DerivedIdentity::backup_key` (HKDF info `sinhron-state-backup/v1`). Server хранит **только ciphertext** + version_seq + updated_at; не имеет ключа, не может расшифровать.

**Wire format.** `[12B nonce][ciphertext][16B GCM tag]`. AEAD AAD = `sinhron-state-backup-v1` (доменное разделение от потенциальных future форматов).

**Версионирование.** Каждый PUT принимает `version_seq` (i64); сервер отклоняет stale (`< current`) с 409. Клиент инкрементит локально (на 1 после каждого успешного PUT).

**Plaintext.** Весь SQLite-файл MLS state byte-for-byte. Альтернатива (parse + re-encode logical struct) — отвергнута, добавляет version-skew risk если openmls_sqlite_storage поменяет schema.

**TTL.** Server cap 1 MB blob. На retention worker не дропается — пользователь полагается на наличие при recovery. (TODO: добавить "drop after 90d of inactivity" если придумаем live-ness signal.)

**Caller contract.** Перед backup MUST `sync_shutdown` так что WAL sidecar flushed и SQLite file представляет согласованное состояние.

**Verified.** 2 unit tests: round-trip (encrypt→decrypt = plaintext) и wrong-phrase-cannot-decrypt (security guarantee).

**Спека compliance.** §6.8.1 ✓.

---

## ADR-013 · WAL mode + synchronous=NORMAL для iOS resilience (2026-05-23)

**Контекст (Risk #1 в архитектурном аудите 2026-05-23).** iOS убивает приложение в любой момент (memory pressure, background timeout, system push). Default `journal_mode = DELETE` + multi-statement writes → kill в середине = corrupted SQLite на следующем запуске = группа/чаты потеряны.

**Решение.** В обоих connection-open сайтах (`sinhron_storage::apply_migrations` + `SinhronProvider::new_with_connection`):

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
```

**Почему WAL.**
- Writers не блокируют readers (concurrency win)
- Каждый commit атомарен через rename sidecar `-wal` файла
- Crash mid-write → автоматический rollback к pre-write snapshot на следующем open

**Почему `synchronous=NORMAL` (не FULL).** Default `FULL` делает `fsync()` после каждого commit — медленно на iOS flash. `NORMAL` fsync'ит только на checkpoint. С WAL это всё ещё safe: WAL — append-only, rename atomic, в худшем случае мы теряем последний uncommitted-to-page-cache write (не corrupting).

**Cost.** Zero on the dev path. Production gain: бесколичество "почему у меня пропали все чаты" support tickets.

**Verified.** 2 regression tests (`migrations_enable_wal_journal_mode`, `file_provider_enables_wal_journal`) — проверяют `PRAGMA journal_mode` возвращает `"wal"` после open.

---

## ADR-014 · sinhron_cli как канонический test harness (2026-05-23)

**Контекст.** Phase 2 client-side stress testing требует прогон сценариев (bootstrap, invite, send, listen) без UI. Flutter test framework не подходит — он driver'ит UI events, не Rust протокол напрямую.

**Решение.** Новый crate `sinhron_cli` (бинарь, не FFI). Зависит на тех же `sinhron_sync`, `sinhron_net`, `sinhron_storage`, `sinhron_crypto` что и Flutter app. Гарантирует **protocol compatibility by construction** между CLI и app.

**Per-phrase state.** `~/.sinhron-cli/<fingerprint>/mls-state.sqlite` — отдельный SQLCipher-encrypted DB на phrase. Параллельные Alice/Bob запуски не конфликтуют.

**Cmds:** `bootstrap`, `create-group`, `invite`, `send`, `listen`. Все принимают `--phrase`, `--server`. Минимально совместимы с docker-compose локально на 8080.

**Не делает CLI:**
- Не открывает iOS-specific paths (path_provider) — собственный home dir
- Не использует path_provider/Flutter — `dirs_home()` через `$HOME` env
- Не шарит state с Flutter app (по дизайну: тесты должны быть изолированы)

**Future:** `stress` subcommand (T4.1) — 100 chats × 1000 messages для load tests; нагрузка-на-сервер бенчмарк.


---

## ADR-015 · LiveKit + SFrame architecture для Phase 3 calls (2026-05-23)

**Контекст.** Phase 3 — 1:1 audio + video calls. Спека §10 фиксирует LiveKit + SFrame, но как именно совмещать MLS-derived ключи с LiveKit's E2EE infrastructure, какой scope включить в v1, что отложить — все эти решения принимались в течение iteration серии и оседали в коде. Этот ADR фиксирует их в одном месте.

### Решения

**A. Media SFU — LiveKit v1.11.0 (vs raw WebRTC vs Daily vs Twilio).**
- **LiveKit:** self-hosted, open-source (Apache 2.0), SFrame E2EE supported through custom KeyProvider, active development (релизы ~раз в 1-4 нед per spec §10.6), Go binary fits в docker-compose.
- **Raw WebRTC:** мы бы сами писали SFU (or использовали Janus / Mediasoup) — months of work + ongoing maintenance burden vs zero open-source competitive advantage.
- **Daily / Twilio:** managed SaaS, нарушает self-hosted spec invariant; платный.
- **Решение:** LiveKit v1.11.0 в docker-compose, pinned exact. Spec §5.2 pin authoritative.

**B. Custom BaseKeyProvider — keys из MLS exporter (vs shared key vs SDK default).**
- LiveKit's default `BaseKeyProvider.create(sharedKey: true)` — один shared key для всей room. Подходит для пользователей которые уже знают друг друга off-band.
- **Spec §10.3 явно требует** SFrame keys via MLS-Exporter (RFC 9605 §5.2), которые автоматически rotate на каждом MLS Commit (forward secrecy под членство-изменения).
- **Решение:** `BaseKeyProvider.create(sharedKey: false, ratchetWindowSize: 0)`. `ratchetWindowSize=0` отключает LiveKit's built-in ratchet — MLS handles rotation, второй ratchet поверх MLS = redundant и потенциально буфер-overflow opportunity. Initial key установлен через `setRawKey(Uint8List)` из `sframe_derive_key_pair()` FFI.

**C. SFrame key rotation strategy — poll group_epoch vs event-driven (vs LiveKit's built-in).**
- LiveKit's built-in ratchet (per-frame deterministic key advance) — отключено per B.
- Event-driven: subscribe к sinhron_sync's on-commit callback. **Не реализовано** — callback wiring требует threading-sensitive code между Rust async runtime и Dart isolate.
- **Решение (CC5 implementation):** 1-second poll Timer внутри `LiveKitCallEngine`. Calls `mlsGroupEpoch()` FFI; если epoch changed → re-derive own key + `setRawKey`. LiveKit's 16-slot keyring (matches our E=4 epoch-bits) handles in-flight frame decryption during transition. Trade-off: 1-second максимальное delay rotation, acceptable для VoIP жанра.

**D. Identity для action-proof signing — SyncClient singleton seed vs phrase re-derivation.**
- Spec §6.8: phrase NEVER persists локально (только hash).
- **Решение:** identity seed (Ed25519 secret bytes) stays Rust-side в `MlsIdentity.device_seed` after `sync_init_from_phrase`. FFI `call_request_livekit_token` / `call_request_turn_creds` читают из singleton instead of re-deriving from phrase. Phrase crossing FFI ограничено onboarding moment.

**E. Server-side LiveKit JWT mint vs клиент-issued.**
- LiveKit JWT signed via shared secret. If shared secret on client → can spoof identity / abuse other rooms.
- **Решение:** server-only signing. `LIVEKIT_API_SECRET` stays в server's `.env`, никогда не передаётся клиенту. Endpoint `POST /v1/call/token` принимает action-proof, mint'ит JWT с claims `{iss, sub, nbf, exp, video.{room, roomJoin, canPublish, canSubscribe}}`. Manual HS256 JWT построение в `handlers::call::mint_hs256_jwt` (no `jsonwebtoken` crate — saves ~5 deps).

**F. JWT TTL = 1h, TURN cred TTL = 1h.** *(TURN TTL → 24h в ADR-016: coturn перепроверяет креды на каждом refresh allocation, и звонок > 1h рвался.)*
- Trade-off between server load (frequent refreshes) and leak blast radius (long-lived creds).
- 1h matches industry standard for VoIP tokens. Client doesn't refresh mid-call (calls rarely > 1h); long calls would need re-fetch logic (deferred — not v1 concern).

**G. CallKit foreground-only без Apple Developer cert (CE1 partial).**
- Apple Developer Program ($99/yr) required для PushKit VoIP push.
- **Решение (operator decision 2026-05-23):** cert не покупается v1. CallKit реализован как foreground-only — incoming call shows native UI ТОЛЬКО когда app foreground. Lock-screen incoming requires PushKit + cert (DEFERRED to Stage E2 после cert acquisition). Документировано в `plan-calls.md §11`. CE1 (Swift platform channel) — ongoing work.

**H. KID layout — S=6 sender bits + E=4 epoch bits.**
- Per RFC 9605 §6.1 Figure 8. Spec §10.3 рекомендует "так чтобы `keyRingSize ≥ 2^E` соответствовал размеру keyring'а LiveKit".
- LiveKit default keyring size = 16 → E=4 is right.
- S=6 → up to 64 active senders. For 1:1 calls (size 2) overkill; для future group calls (Фаза 8) — достаточно (50+ participants редко в реальном usage).
- **Решение:** S=6 / E=4 hard-coded в `sinhron_call::sframe::Kid` constants.

**I. Network drop policy — 30s reconnecting watchdog (CE5).**
- LiveKit handles reconnect внутри (signaling + peer connection retry). Question — how long to wait before declaring permanent.
- Industry conventions: WhatsApp / Telegram ~30-45s grace. Below 30s → false-positive ends on transient drops. Above 60s → user impatient, calls feel hung.
- **Решение:** 30s Timer в `activeCallProvider._onLiveKitReconnecting`. Auto-end с reason="network_lost" если не recovered.

**J. Group calls — DEFERRED to спек-Фаза 8 ≈ 2-3 weeks extra after 1:1 ship.**
- Same MLS group → same exporter. KID encoding supports sender_index до 64.
- UI ready: WU 41 (participants modal), WU 42 (2×2/3×3/spotlight grids).
- Server: `handle_call_invite` enforces 1:1 (412 if ≥3 distinct user_pk). Future: drop the check, expand `CallSession` to handle N>2.
- **Решение:** Phase 3 v1 = 1:1 only. Group calls — отдельный milestone после Phase 3 production deploy + user feedback.

**K. iOS Data Protection class — not configured explicit (tech-debt 2.6).**
- Mentioned в tech-debt for SQLite files. Phase 3 doesn't change this; SFrame keys live in RAM only (LiveKit's keyring + our `setRawKey`), never persist.
- **Решение:** acceptable Phase 3 state. Future hardening pass может add `NSFileProtectionComplete` к sinhron-mls.sqlite.
- **Обновление 2026-10-13:** закрыто ADR-021 — класс `completeUntilFirstUserAuthentication` на всех папках приложения.

### Что отложено vs hard "no" (для clarity)

| Capability | Status | Why |
|---|---|---|
| Group calls ≥3 | Deferred Фаза 8 | UI ready; server check loosens trivially |
| Screen share | Deferred | iOS ReplayKit отдельный effort ~1 нед |
| Recording (server-side or client) | OUT v1 | Privacy + legal implications |
| Picture-in-Picture | Deferred | iOS 14+ feature; nice-to-have |
| Android | OUT v1 spec | iOS-only client per current scope |
| Federated calls (cross-server) | §19 open question | Federation not in v1 anyway |
| 1080p video / spatial audio | Deferred | LiveKit default (720p) sufficient |
| Voice messages | OUT — НЕ calls | Это спек-Фаза 6 (media), отдельный milestone |

### Consequences

**Положительные:**
- Phase 3 closes без extending the spec.
- LiveKit's E2EE custom KeyProvider works exactly as required (MLS-keyed).
- Server NEVER sees plaintext media or SFrame keys.
- Crash recovery during call: LiveKit handles reconnect; MLS state survives via openmls_sqlite_storage; call_id state in registry has 5s grace.

**Отрицательные:**
- LiveKit API changes between minor versions могут require code patches (`livekit_client` 2.5 → 2.6 etc.). Pin exact в pubspec.yaml.
- coturn `network_mode: host` имеет caveats на Mac (Docker Desktop) — same-LAN testing работает без TURN; cross-LAN требует Linux host.
- Без Apple Dev cert lock-screen incoming не работает — incoming calls limited к foreground app state.

### Связь с другими ADRs

- **Sealed sender** (T1.4, spec §6.5, tech-debt 2.2 — отдельного ADR нет; ADR-003 — про отказ от passkeys) — partial alignment. Calls bypass sealed-sender flag (LiveKit knows participant identities through JWT `sub` claim). Full E2EE metadata-hiding для calls = follow-up beyond v1.
- **ADR-008** (sqlx vs rusqlite) — N/A for calls (no DB-backed call state on client).
- **ADR-011** (SQLCipher) — covered; SFrame keys never touch disk.
- **ADR-013** (WAL + synchronous=NORMAL) — calls table v3 migration inherits.

**Дата принятия:** 2026-05-23 (during Phase 3 implementation iterations).

---

## ADR-016 · Production NAT traversal для звонков: TURN/TLS на 443 через Caddy layer4 (2026-10-13)

### Context
ADR-015 дал рабочие звонки на одной LAN, но продакшен-схема NAT traversal не работала: LiveKit-сигналинг не был доступен по `wss://` (в Caddyfile не было маршрута), coturn в bridge-сети без `external-ip` раздавал внутренние адреса, диапазоны портов не совпадали, TURN был только на 3478 (сети «только 443» — корпоративные, часть мобильных, DPI — звонок не соединялся). TURN-креды жили 1h без обновления, `/v1/call/token` выдавал токен без проверки членства в группе, compose не передавал серверу переменные звонков.

### Decision
- **TCP 443 делится по SNI** через Caddy + `caddy-l4` (свой образ `Dockerfile.caddy`, Caddy 2.11.7, caddy-l4 v0.1.2 — точные пины). `SINHRON_TURN_HOSTNAME` → Caddy снимает TLS → plain TURN-over-TCP в coturn:3478. Остальное → TLS passthrough + PROXY protocol v2 в HTTP-часть Caddy (`:8443`), чтобы сервер видел реальные IP клиентов. Тот же паттерн LiveKit рекомендует для своего встроенного TURN; мы оставляем coturn (spec §10.2).
- **Три имени:** API (`SINHRON_PUBLIC_HOSTNAME`), LiveKit (`SINHRON_LIVEKIT_HOSTNAME`, wss через Caddy, 7880 наружу не публикуется), TURN (`SINHRON_TURN_HOSTNAME`). Отдельный поддомен LiveKit вместо пути `/livekit` — так рекомендует LiveKit, и не зависим от того, как SDK склеивает путь.
- **coturn:** `network_mode: host`, обязательный `--external-ip` (`TURN_EXTERNAL_IP`, `public/private` за 1:1 NAT), relay 49152–49999/udp, `no-tcp-relay`.
- **LiveKit:** медиа на одном UDP-порту 7882 (+ ICE/TCP 7881) вместо диапазона.
- **Креды TURN:** TTL по умолчанию 24h; логин `<expiry>:<random nonce>` вместо identity (coturn пишет логины в лог).
- **`/v1/call/token`:** выдаётся только участнику группы (`group_members → devices → users`), иначе 403.
- Postgres публикуется только на `127.0.0.1`.

### Alternatives
- **Встроенный TURN LiveKit** вместо coturn — отклонено: расходится со спекой §10.2 и ADR-015; паттерн L4/SNI всё равно тот же.
- **coturn TLS на 5349** — не решает сети «только 443».
- **Второй публичный IP под TURN:443** — дороже и сложнее для соло-оператора.
- **Обновление TURN-кредов посреди звонка (ICE restart)** — сложнее и не проверяемо без реальных устройств; 24h TTL закрывает реальные сценарии.

### Consequences
- **+** Звонки проходят из сетей, где открыт только TCP 443; NAT traversal работает на стандартном Linux-VPS.
- **+** Меньше метаданных в логах coturn; чужие не попадают в комнату звонка.
- **−** Своя сборка Caddy (xcaddy) — обновлять пины осознанно.
- **−** Утёкший TURN-кред пригоден для relay до 24h (только на relay-трафик, rate-limit на выдачу сохраняется).
- **−** Hairpin coturn → LiveKit по публичному IP того же хоста на облаках с 1:1 NAT может не работать — рекомендован VPS с публичным IP на интерфейсе.
- Проверено: Caddyfile на собранном Caddy (маршрутизация SNI, TURN/TLS, PROXY protocol, редирект), compose-конфиги через `docker-compose config`, серверные тесты (включая membership на реальном Postgres). **Не проверено:** реальный звонок через NAT на развёрнутом сервере — приёмка в `deploy-guide.md` §6.5.

**Дата принятия:** 2026-10-13.

---

## ADR-017 · Медиа в чатах: envelope v1, файловое хранилище блобов (2026-10-13)

### Context
Спек-Фаза 6 (§6.9, §11): фото, голосовые, документы. Клиент шифрует файл до отправки (AES-256-GCM, случайный ключ), сервер хранит только шифротекст под именем `sha256(ciphertext)`, ключ едет внутри MLS-сообщения. Препятствия в коде: (1) MLS-plaintext был **голым UTF-8 без типа и версии** — медиа некуда положить; (2) таблица `media` хранила блоб inline в `BYTEA`; (3) нет ни одного media-эндпоинта.

### Decision
- **Envelope v1** (`sinhron_sync::envelope`): `0xFF · version · protobuf(AppMessage{Text|Media})`. `0xFF` невозможен в UTF-8 → однозначно отличает от legacy-текста (старые сообщения читаются как текст). Неизвестная версия → `Unsupported` («обновите приложение»), не мусор. Схема — prost-derive в Rust (клиент↔клиент, сервер её не видит); номера полей — контракт совместимости. Все входящие поля валидируются (длины ключей/хешей, waveform ≤256, имя ≤255 Б, текст ≤64 КБ) — пир может прислать что угодно.
- **Шифрование блоба** (`sinhron_sync::media`): новый ключ 32 Б + nonce 12 Б на каждый блоб, `blob = nonce‖ct‖tag`; при расшифровке сначала размер и sha256, потом AEAD. Превью — отдельный блоб ≤32 КБ (спек §11.2).
- **Сервер** (`handlers/media.rs`): `POST /v1/media` (сырые байты, заголовки `x-sinhron-identity/ts/proof/sha256`; подпись проверяется **до** чтения тела; потоковая запись во временный файл с хешированием; несовпадение хеша → 400 и удаление; лимит `SINHRON_MEDIA_MAX_BYTES`, по умолчанию 100 МиБ; повтор → 200 без записи), `GET /v1/media/{sha256}` (потоковая отдача). Доступ — любой зарегистрированный identity, знающий sha256: хеш неугадываем, содержимое без ключа бесполезно, а ACL «блоб ↔ группа» заставил бы сервер хранить связь медиа с чатами. Отдельный rate-limit `SINHRON_RATE_MEDIA_UPLOAD` (200/час).
- **Хранилище — файлы, не BYTEA**: `SINHRON_MEDIA_DIR/<aa>/<sha256>`, в Postgres только метаданные (миграция `20261013120000_media_on_disk.sql` удаляет колонку `blob`). Многомегабайтные строки раздували бы WAL и бэкапы и требовали бы держать блоб целиком в памяти. Отклонение от спеки §7.4 («inline для v1») — осознанное.
- **Retention**: 90 дней без upload/GET → удаление строки и файла (воркер retention). `ref_count` из спеки не используется: сервер не знает, какие сообщения ссылаются на блоб (они E2EE).
- **Клиентская БД**: `messages.media_json` (schema v4, SQLCipher) — ключи блобов хранятся только в зашифрованной локальной БД.
- **Фото (этап 2)**: каждое фото декодируется и перекодируется в Rust (`photo.rs`) — так гарантированно удаляются EXIF/GPS/XMP, ориентация применяется к пикселям; ≤2048 px, превью ≤32 КБ, BlurHash. Принимаются только JPEG/PNG (image_picker просим выдавать JPEG, HEIC не декодируем). Расшифрованное — только в RAM (`MediaCache`), временный файл image_picker удаляется сразу.
- **Документы / голос / экран медиа (этапы 3-5)** — где plaintext неизбежно касается диска, это ограничено по времени и задокументировано:
  - открыть/поделиться документом или фото: iOS работает только с файлами → свежий каталог в tmp, запись прямо перед share sheet, удаление сразу после закрытия (`document_share.dart`); на Android `share_plus` делает свою копию в `cache/share_plus/` — `sweepShareCopies` стирает её через 5 минут, при запуске и при выходе (`storage-devices:7`, 2026-11-04); имя файла от собеседника санируется (`safeFileName`);
  - запись голоса: `record` пишет AAC в tmp на время записи → по остановке читается в RAM и удаляется, по отмене удаляется;
  - file_picker копирует выбранный файл в свой tmp-кэш → `clearTemporaryFiles()` сразу после чтения;
  - «Сохранить в Фото» (`gal`) — единственный осознанный экспорт расшифрованного фото наружу, по явному нажатию;
  - проигрывание голоса — из RAM через `just_audio` `StreamAudioSource` (локальный прокси на 127.0.0.1); в `Info.plist` для этого только `NSAllowsLocalNetworking`, остальные правила ATS не ослаблены.
- **UX-решения**: подпись = текст в поле ввода на момент отправки (только к первому из нескольких фото); до 10 фото за раз; отправка медиа показывается пузырём «Sending…/Not sent — tap to retry» (`pendingMediaProvider`), без байтового прогресса — FFI-вызов атомарный.
- **Версии** (`pubspec.yaml`): `file_picker` 11.0.3 и `share_plus` 12.0.2 — более новые требуют `win32` 6, а `livekit_client` 2.7.0 держит `win32` 5; `record` 6.2.1 — 7.x требует Flutter ≥3.44.

### Consequences
- **+** Медиа без доверия к серверу; проверено сквозным тестом через реальный сервер (`examples/media_e2e.rs`).
- **+** Текст теперь тоже идёт в envelope → можно добавлять ответы/реакции без ломки формата.
- **−** Клиенты до envelope покажут новые сообщения как `<binary>` (продукт не выпущен — приемлемо).
- **−** Сервер видит размер блобов (с точностью до байта), время загрузки, загрузившее устройство и факт повторного скачивания. Дедупликация по sha256 даёт оракул «такой блоб есть» тому, кто уже знает его хеш.
- **−** Бэкап теперь = Postgres **+** том `sinhron_media`.

**Дата принятия:** 2026-10-13.

---

## ADR-018 · Превью ссылок — только на стороне отправителя, по умолчанию выключено (2026-10-13)

### Context
Превью ссылок ожидаемы в «премиальном» мессенджере, но наивная реализация (каждый получатель сам ходит на сайт) раскрывает IP и факт прочтения всем участникам чата — плохо для сценария с сервером в РФ.

### Decision
- Превью строит **отправитель** (как Signal): `link_preview::fetch` → заголовок, описание, картинка; картинка перекодируется (`photo::prepare`, EXIF удаляется) и шифруется как блоб 32 КиБ. Превью едет в `TextBody.link_preview` (envelope v1, поле 2 — совместимо).
- Получатель **никогда** не ходит на сайт; превью показывается, только если его URL дословно есть в тексте.
- Правила загрузки: https, без IP/localhost/*.local, ≤3 редиректа с повторной проверкой, 8 с, HTML ≤512 КиБ, картинка ≤2 МиБ, нейтральный UA.
- **По умолчанию выключено**; переключатель в «Конфиденциальность» (таблица `settings`, схема v5).
- Любая ошибка превью → отправляется обычный текст.

### Consequences
- **+** Получатели не раскрывают IP; отправитель решает сам.
- **−** Отправитель раскрывает свой IP сайту; DNS-rebinding на приватный IP не закрыт.
- Статус: Rust + FFI готовы и покрыты тестами (парсинг, правила URL, подмена превью); Flutter-UI — следующий шаг.

**Дата принятия:** 2026-10-13.

---

## ADR-019 · Действия над сообщениями внутри envelope: ответы, реакции, правки, удаление, квитанции, «печатает» (2026-10-13)

### Context
Премиальный чат (бэклог §3, п.22-26, 32) требует ответов, реакций, правок, удаления у всех, статусов доставки/прочтения и «печатает…». Сервер не должен видеть ничего из этого, а собеседник не должен иметь возможность править или удалять чужие сообщения.

### Decision
- **Всё внутри MLS-шифротекста**, envelope v1 (поля добавлены, номера не переиспользуются): `AppMessage.reply_to` (тег 8: id + отрывок ≤200 символов + тип), новые тела `Reaction` (3), `Edit` (4), `Delete` (5), `Receipt` (6: delivered/read + ≤200 id), `Typing` (7); `MediaKind::Video` (4) и `MediaBody.album_id` (12) — заготовка под видео и альбомы.
- **Адресация — wire UUID сообщения** (тот `message_id`, который сервер и так видит для дедупликации). Хранится в `messages.wire_id` (схема v7); у старых входящих восстанавливается из `remote-<uuid>`.
- **Авторство проверяется по MLS:** `decrypt_with_sender` отдаёт identity-ключ отправителя из MLS-credential (аутентифицирован MLS). Правка/удаление/реакция применяются, только если `sender_id` совпадает с автором исходного сообщения (`Author::Peer`) — проверка в SQL хранилища. Без аутентифицированного отправителя действия отбрасываются.
- **Удаление у всех** превращает строку в «надгробие»: текст, ключи медиа, цитата и реакции стираются.
- **Статусы:** отправляется → отправлено (ack сервера; `frame_id` = wire id) → доставлено → прочитано (квитанции). Статус только растёт. Квитанции принимаются только для моих сообщений в этом чате.
- **Отчёты о прочтении и «печатает»** — настройки (по умолчанию вкл.), **взаимные** как в Signal: выключил — не отправляешь и не видишь. Доставка подтверждается всегда. «Печатает» не чаще раза в 4 с, гаснет через 6 с.
- Невалидное (плохой id, текст вместо эмодзи, пустая правка, >200 id) отклоняется и при приёме, и **до отправки**.

### Consequences
- **+** Сервер не отличает реакцию от сообщения по содержимому; подделать правку/удаление чужого сообщения нельзя.
- **−** Квитанции и «печатает» — дополнительные зашифрованные сообщения: сервер видит больше трафика и его тайминг (метаданные). Будущий push-слой не должен будить/уведомлять ради них — решается на клиенте после расшифровки (tech-debt 2.22).
- **−** Правка/удаление не ограничены по времени; закрепление сообщения пока локальное.

**Дата принятия:** 2026-10-13.

---

## ADR-020 · Исчезающие сообщения: таймер внутри envelope, отсчёт от получения, удаление строки целиком (2026-10-13)

### Context
Бэклог §6 п.51: понятные исчезающие сообщения. Сервер не должен знать, какие чаты «исчезающие», а удаление должно быть настоящим, а не скрытием.

### Decision
- **Таймер чата** меняется зашифрованным действием `Timer { secs }` (envelope v1, тег 10 в oneof); у обеих сторон появляется системная строка «Сообщения исчезают через 1 день». Допустимо 0…4 недели.
- **Каждое сообщение несёт свой срок** — `AppMessage.expire_secs` (тег 9). Получатель соблюдает срок отправителя, даже если пропустил смену таймера.
- **Отсчёт:** у отправителя — от отправки, у получателя — от момента, когда сообщение дошло до телефона (не от прочтения: так проще и предсказуемо; отличается от Telegram/Signal, где отсчёт после прочтения — tech-debt 2.27).
- **Удаление:** строка удаляется полностью (текст, JSON медиа с ключами, цитата, реакции) — `storage::messages_expire`; превью чата пересчитывается. Проверка — при запуске, каждые 15 с и при возвращении в приложение.
- Схема хранилища v8: `chats.disappear_secs`, `messages.expire_at` (+ индекс).

### Consequences
- **+** Сервер не отличает исчезающие сообщения от обычных; ключи медиа пропадают вместе с сообщением (блоб на сервере без ключа бесполезен и удаляется по ретеншну).
- **−** Получатель может сохранить содержимое до удаления (скриншот, копия) — исчезающие сообщения защищают от утечки *потом*, а не от собеседника; это сказано в интерфейсе неявно, стоит объяснить в «Подробнее».

**Дополнено 2026-10-13 — сервер тоже считает от получения.** Серверный таймер чата (tech-debt 2.5) сначала удалял сохранённые копии через N секунд после *отправки* — офлайн-получатель терял сообщение. Теперь `message_deliveries.received_at` ставится, когда доставка ушла в живую сессию получателя или отдана при Resume; срок запечатанной доставки (`ttl_secs` → `expires_at`) начинается тогда же, а сохранённый шифртекст чата удаляется, только когда все получатели получили его и с тех пор прошёл таймер (миграция `20261014000000_delivery_received.sql`). Не доставленное ждёт общего срока хранения сервера.

**Дата принятия:** 2026-10-13.

---

## ADR-021 · Ключ устройства в Keychain: вход без фразы после перезапуска, база никогда не стирается молча (2026-10-13)

### Context
Фраза восстановления не хранится нигде (спека §6.8), а из неё выводятся ключ базы (SQLCipher), MLS-личность и вход на сервер. Поэтому после перезапуска приложение не могло ни открыть зашифрованную базу, ни подключиться. Хуже того, `sinhron_storage::open` без ключа «самолечился»: **удалял** зашифрованную базу, а `AppRoot` отправлял пользователя на онбординг, который выдавал **новую** фразу — то есть каждый перезапуск стирал чаты и создавал новый аккаунт (tech-debt 2.16, 2.4).

### Decision
- **Ключ устройства** = 64-байтный BIP-39 seed (фраза → PBKDF2-HMAC-SHA512, 2048 раундов — необратимо), строкой `sinhron-device-key:v1:<hex>`. `sinhron_crypto::identity::derive_identity` принимает и фразу, и ключ устройства; все ключи (Ed25519, X25519, бэкап, SQLCipher) выводятся из seed как раньше. Это «рабочая копия recovery-key в Keychain» из спеки §6.8 — сама фраза не хранится.
- **Хранение:** iOS Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (не в iCloud и не в бэкапах на другой телефон); канал `dev.sinhron/keychain` в `AppDelegate.swift`, Dart — `lib/core/session.dart`.
- **Запуск** (`openStorageAtBoot`): есть ключ → база открывается им (ещё не зашифрованная — открывается и шифруется); ключ есть, а файла нет (Keychain пережил переустановку) → ключ удаляется; ключа нет, база зашифрована → **заблокирована**, экран «Разблокировать фразой». Затем `Session.resume` подключается ключом устройства.
- **Ничего не стирается молча:** `StorageError::Locked` вместо удаления; стирание — только `storage_erase` по явному «Стереть и начать заново» (с подтверждением) или при выходе из аккаунта.
- **Разблокировка** проверяет фразу по данным телефона: заблокированная база должна открыться ею, а у открытой — совпасть отпечаток сохранённой личности. Только потом ключ кладётся в Keychain.
- **Файлы приложения** (tech-debt 2.6): класс защиты iOS `completeUntilFirstUserAuthentication` на папках Documents / Application Support / Caches — поверх SQLCipher. Не `.complete`: SQLite держит WAL открытым, а обработка push (позже) должна читать базу при заблокированном экране.

### Consequences
- **+** Перезапуск больше не теряет данные и аккаунт; переподключение — без фразы (Настройки → «Переподключиться»).
- **+** Новый телефон или стёртый Keychain — данные не пропадают, их открывает фраза.
- **−** Тот, кто получил разблокированный телефон с джейлбрейком или доступ к Keychain, получает ключ устройства — то есть всё, что даёт фраза, кроме самой фразы. Это обычная модель мессенджеров (Signal, WhatsApp держат ключи в Keychain); защита — код телефона, «Блокировка приложения» (Face ID) и Data Protection.
- **−** Проверено тестами и компилятором Swift; Keychain и защита файлов на настоящем iPhone не запускались (tech-debt 2.31).

**Дата принятия:** 2026-10-13.

---

## ADR-022 · Порядок коммитов в группе задаёт сервер: первый за эпоху побеждает (2026-10-13)

### Context
Tech-debt 2.3. Если два участника одновременно меняют группу (например, оба добавляют человека), оба делают Commit в одной эпохе. Раньше каждый сразу применял свой (`merge_pending_commit`) и отправлял — группа «раздваивалась»: у каждого своя эпоха N+1, чужой Commit отбрасывался как `StaleEpoch`, сообщения друг друга больше не расшифровывались. MLS (RFC 9420 §14) отдаёт упорядочивание сервису доставки.

### Decision
- **Протокол:** `Submit.is_commit` + `Submit.commit_epoch` (теги 5 и 6, обе копии `.proto`).
- **Сервер** (`ws::handle_submit`): compare-and-set `UPDATE mls_groups SET current_epoch = e+1 WHERE group_id = $1 AND current_epoch <= e` в той же транзакции, что и запись сообщения. Не прошло → Ack **409**, сообщение не сохраняется и не рассылается. Блокировка строки ставит гонщика в очередь, он видит новую эпоху и получает 409. `<=` даёт группам, созданным до того, как колонку начали вести, догнать её первым же Commit. Группа, не зарегистрированная на сервере, — как раньше, без упорядочивания.
- **Клиент** (`sinhron_sync`): `invite_to_group_pending` делает Commit, но **не применяет** его; Ack 0 → `confirm_commit` (merge), 409 → `discard_commit`, применить пришедший Commit победителя, повторить.
- Добавление в новую группу её создателем (единственный Commit в приложении сегодня) остаётся немедленным — гонке там не с кем случиться.

### Consequences
- **+** Группа не раздваивается при одновременных изменениях; проверено тестами: клиентский (4 участника, проигравший повторяет, все в одной эпохе и переписываются) и серверный (два Commit наперегонки на реальном Postgres → 0 и 409, проигравший не сохранён).
- **−** Участник группы может прислать Commit с завышенной эпохой и «увести» счётчик сервера вперёд, после чего коммиты остальных будут получать 409 до их догоняния. Это отказ в обслуживании изнутри группы (участник и так может её сломать); сервер не видит содержимого и не может проверить эпоху сам. *(2026-11-02: только эпоха группы ровно, без `<=`; 2026-11-04, ADR-090: и без «догона» чата с эпохой 0 — новый чат начинается с эпохи, которую объявил создатель.)*
- **−** Поток «добавить участника в существующую группу» в приложении ещё не сделан (нет интерфейса групп) — когда появится, он обязан идти через pending-API.

**Дата принятия:** 2026-10-13.

---

## ADR-023 · Sealed sender: HPKE-конверт на каждого получателя, сервер не видит чат (2026-10-13)

### Context
Tech-debt 2.2, спека §6.5. Обычная отправка (`Submit`) несёт `group_id`, сервер хранит шифртекст «при группе» и знает, в какой чат пишут. Флаг `sealed_sender` (T1.4) только прятал отправителя в базе и логах, сам чат оставался виден.

### Decision
- **Ключи доставки:** у устройства еженедельный ключ HPKE (X25519), выводится из ключа устройства (`DerivedIdentity::delivery_root`, HKDF `sinhron-delivery/v1` → неделя → `derive_hpke_keypair`), ничего не хранится. Публикуется текущая и следующая неделя (`PUT /v1/sealed-keys`, подпись `sinhron-sealed-keys-put-v1:`), открываются конверты текущей и двух прошлых недель. Сервер принимает только недели [−1, +2] и чистит ключи старше 4 недель.
- **Отправка:** MLS-сообщение → для каждого получателя `HPKE(pk, info="sinhron-sealed-v1", aad=key_id)` над `{group_id, mls}` → `SealedSubmit{message_id, [{key_id, envelope}]}` (тег 25). Если у кого-то из собеседников нет текущего ключа — обычный `Submit` (совместимость, ничего не ломается).
- **Сервер** (`ws::handle_sealed_submit`): `key_id → получатель`, конверт хранится прямо в его строке доставки (`message_deliveries.envelope`), строки в `messages` нет, `Push.group_id` пуст, `Push.sealed_key_id` указывает ключ. Resume отдаёт такие доставки так же. В логах только счётчики.
- **Получатель:** `SyncClient::open_sealed` — вскрытие, MLS-расшифровка и проверка отправителя в одной функции, без сериализованных промежуточных состояний (правило §6.5 после IACR 2026/484). В приложении это происходит внутри `net_next_event`; Dart получает уже готовое сообщение с группой.
- **Название:** таблица `sealed_keys`, а не «delivery_key» — `devices.delivery_key` уже занят токеном push-уведомлений.

### Consequences
- **+** Для сообщений, ушедших запечатанными, оператор не знает чат, не видит отправителя внутри MLS и не хранит шифртекст по группам; дамп базы не связывает сообщения с чатами.
- **−** WS-соединение аутентифицировано — сервер знает, *какое соединение* отправило конверт и кому. Полная анонимность отправителя требует неаутентифицированной отправки с токенами доступа (как «unidentified access» у Signal) — tech-debt 2.2 (остаток).
- **−** Сервер не может проверить членство в группе (он её не знает): защита — лимит отправки на соединение и MLS у получателя, который отбрасывает всё не от участника. Спам конвертами по известному ключу возможен в пределах лимита.
- **−** Ключи доставки по пользователю, а не по устройству: при нескольких устройствах (4.2) каждому понадобится свой ключ — схема это допускает (несколько строк на пользователя).
- **Проверено:** юнит-тесты HPKE и ротации, клиентский тест двух участников, серверные тесты на реальном Postgres (маршрутизация, повтор, Resume, публикация/подделка/далёкая неделя) и сквозной `examples/sealed_e2e.rs` через настоящий сервер.

**Дата принятия:** 2026-10-13.

---

## ADR-024 · Групповые звонки и ключи SFrame на каждого участника (2026-10-13)

### Context
Tech-debt 4.1/4.9. Сервер пускал звонки только в чатах на двоих (`handle_call_invite`: «ровно 2 пользователя»), `CallSession` знал одного собеседника. На клиенте `LiveKitCallEngine` ставил ключ SFrame через `setRawKey` **без `participantId`** в режиме ключей по участникам (`sharedKey: false`) — `livekit_client` сохранял его под пустым именем, и ни у своей, ни у чужих дорожек ключа не было (шифрование звонка не работало как задумано; на устройстве не проверялось). Экран звонка показывал только заглушку вместо видео.

### Decision
- **Сигналинг** (`call_session.rs`, `ws.rs`): `CallSession{invitees, joined, gone}`; приглашаются все остальные участники группы (≤ 32). Принять может любой приглашённый, пока звонит или идёт (поздний вход). Уход в группе не завершает звонок для остальных (LiveKit сам показывает уход); звонок кончается, когда остаётся один человек и никто больше не звонит, когда отказались все или звонящий отменил до первого ответа — тогда `CallEnd` всем, кто ещё в звонке или кому звонит. Принятие пересылается всем уже присутствующим. 1:1 ведёт себя как раньше.
- **Ключи SFrame** (`call_sframe_key_for(group, identity)` в Rust): идентичность LiveKit = hex ключа личности = учётные данные MLS → лист этого участника → экспортёр группы → ключ RFC 9605. Клиент ставит ключ себе и каждому в комнате под его идентичностью, слот = эпоха mod 16; при входе нового участника — ему; при смене эпохи MLS — всем, свой слот переключается `setKeyIndex`.
- **Видео** (`call_video.dart`): сетка удалённых камер (1 — во весь экран, 2 — друг над другом, 3–4 — 2×2, больше — 3 колонки), своя камера в углу; без видео — инициалы.

### Consequences
- **+** Звонки в группах; шифрование звонков устроено так, как требует MLS-SFrame (каждый отправитель со своим ключом из общего секрета).
- **−** Ни 1:1, ни групповые звонки не проверены на устройствах после исправления ключей — нужен LiveKit + два-три телефона (tech-debt 4.1). Тесты — серверные (сигналинг на реальном Postgres), Rust (лист по идентичности и общий секрет совпадают у участников), раскладка сетки.
- **−** Имена участников в сетке — инициалы ключа (сопоставление личность → контакт для звонка не сделано).

**Дата принятия:** 2026-10-13.

## ADR-025 · Несколько устройств у одного человека (2026-10-13)

### Context
Tech-debt 4.2. Один phrase = одно устройство: лист MLS подписывал ключ личности, сервер знал одно устройство на человека (`devices` — строка с `device_pk = identity_pubkey`), `handle_submit` проверял членство по одному (первому) устройству и не доставлял сообщение другим устройствам отправителя. Ввести тот же phrase на втором телефоне значило получить второй лист с тем же ключом — и путаницу в группах.

### Decision
- **Ключ устройства + сертификат.** Первое устройство остаётся как есть (ключ листа = ключ личности, учётные данные = 32 байта ключа). Связанное устройство получает **свой** Ed25519-ключ (случайный seed, хранится только на нём) и сертификат `"SDC1" ‖ identity_pub ‖ device_pub ‖ sig_identity("sinhron-device-cert-v1:" ‖ device_pub)` (132 байта) как MLS BasicCredential. `identity_of_credential` сводит оба вида к человеку: отправитель, список участников, ключи звонка, номер безопасности — по человеку, а не по устройству. KeyPackage с поддельным сертификатом в группу не попадёт (`add_members` отвергает учётные данные, не называющие личность).
- **Сервер** (`handlers/devices.rs`, миграция `20261013180000_linked_devices.sql`: `devices.certificate`, `devices.revoked_at`): `POST /v1/devices` — устройство регистрирует себя (сертификат + action-proof **своим** ключом, домен `sinhron-device-add-v1:`; не больше 8 связанных); `GET /v1/devices?identity_pubkey_hex=` — активные устройства; `DELETE /v1/devices/{pk}` — отзыв подписью ключа личности (`sinhron-device-revoke-v1:`): помечает `revoked_at`, удаляет его KeyPackage и строки `group_members`; отозвать можно любое, кроме последнего (в том числе потерянный первый телефон). `GET /v1/keypackages/consume?per_device=true[&devices=…]` — по одному KeyPackage с каждого активного устройства (или только с перечисленных). Загрузка KeyPackage отозванным устройством — отказ.
- **Доставка.** Членство при `Submit` — через любое активное устройство человека. Если в группе ≥ 2 его устройств, сообщение доставляется и самому отправителю (другим его устройствам); устройство-отправитель отбрасывает своё эхо (`IncomingMessage::OwnCommitEcho`). WS-сессии и так по человеку — живые сокеты всех его устройств получают Push; догон — по своему курсору на каждом устройстве. Welcome себе разрешён, если устройств ≥ 2; сервер не знает, для какого устройства Welcome (он зашифрован на KeyPackage), поэтому у человека с несколькими устройствами Welcome остаётся в очереди до TTL (7 дней) и уходит каждому — устройство берёт свой и игнорирует чужие (`NoMatchingKeyPackage`).
- **Приглашение** (`fetch_kp_and_invite`) добавляет **все** устройства приглашённого одним Commit (один Welcome на всех). **Синхронизация устройств** (`sync_devices` в FFI): для каждой группы — недостающие свои устройства добавляются (KeyPackage только с них, Commit в режиме ожидания ADR-022: `Submit{is_commit, commit_epoch}`, применяется только по Ack 0, при 409 — отбрасывается, повтор при следующей синхронизации; затем Welcome себе и анонс группы), листы отозванных — удаляются. `devices_revoke` = отзыв на сервере + синхронизация.
- **Sealed sender.** Ключи доставки выводятся из секрета аккаунта (`delivery_root`), поэтому одинаковы на всех устройствах человека: если в группе есть мои другие устройства, конверт запечатывается и на мой собственный ключ — его получают все мои устройства.
- **Ключи подписи запросов.** На связанном устройстве ключ личности (`identity_secret`) подписывает запросы уровня аккаунта (WS-auth, sealed-ключи, звонки, медиа, отзыв), ключ устройства (`device_seed`) — свои KeyPackage и регистрацию. На первом устройстве это один ключ.

### Отступления от спеки (§6.5 / §6.7)
- **Секрет аккаунта общий.** Связывание — вводом phrase на новом устройстве (QR-сопряжение без phrase — не сделано). Поэтому связанное устройство знает ключ личности: оно может подписывать от имени человека и само себе зарегистрировать новый ключ устройства. **Отзыв — кооперативный:** он убирает устройство из групп (MLS: новых сообщений оно не прочтёт) и с сервера, но владелец phrase всегда может связать устройство заново. Против украденного телефона с известным phrase помогает только новый аккаунт. В спеке ключ личности остаётся на первом устройстве, а новые получают только сертификат.
- **Звонки** — одно устройство за раз: идентичность в LiveKit = ключ личности, два устройства одного человека в одной комнате конфликтуют.

### Consequences
- **+** Телефон и второе устройство под одной личностью: оба получают все сообщения, пишут от одного человека, собеседники видят одного участника.
- **+** Потерянное устройство удаляется из всех групп (новые сообщения ему не читаются) и с сервера.
- **−** Welcome для человека с несколькими устройствами хранятся на сервере до 7 дней и приходят каждому его устройству (метаданные «кого куда пригласили» живут дольше).
- **История на новом устройстве (дополнено 2026-10-13):** MLS не даёт расшифровать прошлые сообщения, поэтому устройство, добавившее новое в чат синхронизацией, отправляет ему последние 200 сообщений чата из своей локальной базы — сообщением конверта `History` (тег 12, ≤ 50 в одном, текст и медиа-ссылки с ключами), MLS-сообщением в этом же чате, но запечатанным (ADR-023) **только на собственный ключ доставки** (он общий у устройств человека), так что собеседники его не получают (MLS пропускает это поколение у них без последствий). Принимается только от себя и только в чат, где на этом устройстве ещё нет сообщений. Исчезающие, удалённые и системные строки не передаются.
- **Дополнено 2026-10-13:** Welcome адресуется устройствам (`Welcome.recipient_device_pks`; сервер знает устройство каждого WS-соединения по ключу входа — устройства со своим листом входят своим ключом, `login_seed_bytes`; `pending_welcomes.recipient_device_pk`, доставленная копия удаляется); синхронизация не добавляет устройства, молчащие > 30 дней (`devices.last_seen_at`); история несёт имя чата; отправка ждёт своего Commit, а группы хранят ключи 2 прошлых эпох (`MAX_PAST_EPOCHS` — чуть меньше прямой секретности ради доставки сообщений, отправленных рядом с Commit); участник звонка — устройство (идентичность LiveKit = ключ устройства); отзыв сразу закрывает живые соединения отозванного устройства (`SessionRegistry::drop_device`).
- **Приложение:** «Войти по ключу» / «Связать устройство» → `RestoreScreen` (`Session.establishLinked`: случайный ключ устройства в Keychain `device-seed`, этим устройством и только им); синхронизация при подключении, раз в 5 минут и после нового чата (никогда не ждётся из цикла событий WS — она ждёт Ack из него же); «Устройства» — `GET /v1/devices` и отзыв; сообщения моего другого устройства сохраняются как мои. Повторный Welcome для уже имеющейся группы отвергается (`join_via_welcome`), поэтому очередь Welcome безопасна.

**Дата принятия:** 2026-10-13.

## ADR-026 · Sealed sender без соединения отправителя: ключ доступа («unidentified access») (2026-10-13)

### Context
Tech-debt 2.2, остаток ADR-023. Конверты sealed sender уходили по аутентифицированному WS: сервер не видел чат и текст, но видел, **какой аккаунт** отправил конверт и кому. Просто разрешить неаутентифицированную отправку нельзя — любой чужой мог бы анонимно засыпать человека конвертами.

### Decision
- **Ключ доступа** — 16 байт из секрета аккаунта (`SyncClient::access_key`, SHA-256 «sinhron-access-key/v1» ‖ identity secret), одинаков на всех устройствах человека. На сервер уходит только `SHA-256(ключа)` — вместе с ключами доставки (`PUT /v1/sealed-keys`, поле `access_hash_hex`, подписано вместе с ключами; `users.access_hash`, миграция `20261013200000_sealed_access.sql`).
- **Передача ключа** — только внутри MLS: новое сообщение конверта `Access` (тег 11, ADR-017-конверт). Клиент шлёт его в каждый свой чат раз за эпоху группы (`sync_share_access_key` — при подключении, вместе с синхронизацией устройств, и после вступления в чат); полученные ключи хранятся в зашифрованной локальной базе (`settings`, `access_key:<identity>`), свои — никогда.
- **Отправка** — если у отправителя есть ключи доступа всех получателей, конверты идут `POST /v1/sealed` **без аутентификации**, отдельным HTTP-клиентом без общего пула соединений (`submit_sealed_anonymous`); на каждую доставку — ключ доступа получателя, сервер сверяет хэш (сравнение за постоянное время) и кладёт конверт как при `SealedSubmit` (общая `ws::deliver_sealed`). Ограничение частоты — по ключу получателя. Если кто-то отказал (нет хэша, сменился ключ) или сети нет — тот же конверт уходит прежним аутентифицированным `SealedSubmit` (повтор уже принятых поглощается). Ack «отправлено» для анонимного пути клиент создаёт сам (локальная очередь событий, `push_local_ack`).

### Consequences
- **+** Когда ключи доступа разошлись по чату, сервер не знает ни чата, ни аккаунта-отправителя: только «конверт для ключа доставки K».
- **−** Сервер видит IP и время запроса (против этого — Tor/VPN, вне протокола); первые сообщения в новом чате, пока ключи не разошлись, идут аутентифицированным путём.
- **Смена ключа доступа (дополнено):** ключ — функция корня и версии; сервер хранит хэш только самой новой версии (`users.access_version`, миграция `20261013230000_access_version.sql`; более старая версия от другого моего устройства не откатывает, а сообщает ему текущую). Смена — «Сбросить ключ анонимной доставки» в «Конфиденциальности» и автоматически при отзыве устройства; новый ключ уходит в чаты при следующей раздаче (метка раздачи = эпоха + версия). Старый ключ сервер отвергает сразу.
- **Таймер чата и запечатанные доставки (дополнено):** конверт не называет чат, поэтому отправитель прикладывает к доставке таймер чата (`SealedDelivery.ttl_secs`, `ttl_secs` в `POST /v1/sealed`); сервер хранит срок (`message_deliveries.expires_at`, миграция `20261013220000_delivery_ttl.sql`), не отдаёт истёкшие при Resume и удаляет их уборкой. Видно значение таймера, но не чат.
- **−** Сообщения обычного (не sealed) `Submit` и звонки по-прежнему видят группу.

**Дата принятия:** 2026-10-13.

## ADR-027 · Привязка нового устройства по QR; ключ личности — только там, где ввели 24 слова (2026-10-13)

### Context
Tech-debt 4.2 (остаток ADR-025): новое устройство входило в аккаунт только вводом 24 слов, и любое связанное устройство знало ключ личности — отзыв был кооперативным.

### Decision
- **QR** (`sinhron-pair:2:<id>:<одноразовый HPKE-ключ>:<ключ нового устройства>`): новое устройство само создаёт свой ключ устройства и показывает его в QR вместе с одноразовым ключом X25519 и случайным id (`sinhron_sync::pairing::PairingOffer`, только в памяти); опрашивает `GET /v1/pairing/{id}` (раз в 2 с, новый код каждые 2 минуты, ключ устройства тот же).
- **Устройство с ключом аккаунта** (там, где вводили 24 слова) сканирует QR (нативная камера `QRScannerViewController`, канал `dev.sinhron/qrscan`; или вставка кода), спрашивает подтверждение, **подписывает сертификат для ключа из QR** и запечатывает **пакет связанного устройства** (`sinhron-linked:v1:…`: открытый ключ личности, X25519-открытый, сертификат, корни ключей доставки и ключей доступа — **без ключа личности**) на одноразовый ключ (HPKE X25519/HKDF-SHA256/AES-128-GCM, info `sinhron-pair-v1`, aad = id) и кладёт `PUT /v1/pairing/{id}` с подписью (домен `sinhron-pairing-put-v1:`). Сертификат в пакете обязан называть ключ из QR — пакет для чужого устройства не запечатается и не откроется.
- **Сервер** (`handlers/pairing.rs`, `pairing_mailbox`, миграция `20261013210000_pairing.sql`): одна запись на id, 10 минут, отдаётся один раз (после взятия остаётся отметка, следующий ответ или взятие — 409, ADR-091). Ключа HPKE сервер не видит.
- **Устройство без ключа личности** (`SyncClient` из пакета, `MlsIdentity::from_linked_bundle`): лист MLS — свой ключ + сертификат; запросы уровня аккаунта (вход WS, ключи sealed sender, звонки, медиа, таймер чата) подписывает **своим** ключом и шлёт его вместо ключа личности. Сервер (`accounts::resolve_signer`) принимает его, только пока это активное устройство с сертификатом этого человека, — **отзыв по-настоящему запирает такое устройство** (не войдёт по WS, не подпишет запрос). Добавлять и отзывать устройства оно не может (`has_account_key() == false`; отзыв сервер принимает только от ключа личности — иначе украденное устройство могло бы отозвать первое).
- **Вход вводом 24 слов на другом устройстве** (дополнено) тоже не оставляет ключа личности: фраза используется один раз — Rust строит такой же пакет связанного устройства с сертификатом для собственного ключа этого устройства (`linked_bundle_from_phrase`), и в Keychain ложится только пакет. **Ключ личности хранится только на первом устройстве** (где аккаунт создан). На остальных добавление и отзыв устройств просят 24 слова на этот шаг (`pairing_send_with_phrase`, `devices_revoke_with_phrase`; экран «Подтвердите 24 словами»), слова не сохраняются. Разблокировка такого устройства фразой пересобирает тот же пакет (детерминирован от фразы и ключа устройства — тот же ключ базы).

### Consequences
- **+** Ключ личности только на первом устройстве — вариант спеки §6.5. Отзыв любого другого устройства запирает его на сервере, не завися от его доброй воли.
- **−** Кто знает 24 слова, тот владеет аккаунтом: украденное устройство *вместе со словами* остаётся проблемой — это свойство фразы восстановления, не протокола.
- **−** Устройства без ключа аккаунта не делают резервную копию состояния (ключ копии выводится из секрета аккаунта); добавление и отзыв устройств там — с вводом 24 слов.
- **−** Социальная инженерия: кто уговорит отсканировать *свой* QR, получит доступ к сообщениям (но не ключ личности). Подтверждение прямо говорит «дать устройству доступ к аккаунту».
- **−** Камера на iPhone не проверялась (Swift проверен `swiftc -typecheck` под iOS 13; путь «вставить код» — тестами).

**Дата принятия:** 2026-10-13.

## ADR-028 · Прокси SOCKS5 (Tor) для всего обмена с сервером (2026-10-13)

### Context
Sealed sender (ADR-023/026) прячет от сервера чат и аккаунт отправителя, но не IP-адрес телефона — по нему отправителя можно связать с его соединениями. Скрыть адрес можно только сетью вроде Tor; протокол сам этого не даёт.

### Decision
- Настройка «Конфиденциальность → Прокси (Tor)»: `host:port` SOCKS5 (например, Orbot `127.0.0.1:9050`), пусто — напрямую. Применяется при каждом подключении (`NetService.startFromPhrase` → `net_set_socks_proxy`), сохранение переподключает.
- `sinhron_net::proxy` — одна настройка на процесс. WS: сначала туннель SOCKS5 (`tokio-socks`, имя хоста разрешает прокси — работают `.onion`), затем обычные TLS и WS поверх него. HTTP (`HttpApi`, анонимная отправка, превью ссылок): `reqwest` с `socks5h://`. Если прокси задан, но недоступен, — соединения нет (тихого прямого подключения нет).

### Consequences
- **+** С Tor сервер не видит IP телефона; вместе с ADR-026 — ни аккаунта, ни адреса отправителя.
- **−** Звонки (WebRTC / LiveKit) идут без прокси.
- **−** Сам Tor-клиент (Orbot) ставится отдельно; на iPhone не проверялось.

**Дата принятия:** 2026-10-13.


## ADR-029 · Имена участников самим участником (`profile`), закрепление для всех, локальная блокировка (2026-10-13)

### Context
В группах реакции, цитаты и сообщения атрибутировались только ключом личности — имени взять было неоткуда (сервер профилей не хранит и не должен). Закрепление жило только на своём устройстве. «Заблокированные» были макетом.

### Decision
- **Имя — действие в чате:** `AppMessage.Profile{name}` (tag 13) внутри MLS. Каждый сам сообщает своё имя в каждый чат: перед первым своим сообщением, при открытии чата и после переименования; один раз на имя (`chats.profile_sent`). Получатель хранит имя по ключу личности отправителя (MLS-аутентифицирован), `peer_names`. Имя чистится от управляющих, bidi и zero-width символов, 1..64 символа.
- **Закрепление:** `AppMessage.Pin{target, pinned}` (tag 14) рассылается в чат; чужое открепление снимает только названное сообщение.
- **Блокировка — только на устройстве** (`blocked_peers`): `NetService` отбрасывает всё от заблокированного до UI; приглашения на звонок в личном чате с ним отклоняются без звонка. Серверу не сообщается. Плюс общий переключатель «Входящие звонки».

### Consequences
- **+** Сервер не узнаёт ни имён, ни кого вы заблокировали.
- **−** Имя — заявление, не проверка: двое могут назваться одинаково; различает код безопасности (в группе — для каждого участника).
- **−** Заблокированный в группе остаётся участником и читает ваши сообщения; групповые звонки с ним не отклоняются (приглашение несёт только id группы).
- **−** Имя появляется у других только после того, как человек напишет в чат или откроет его с новой версией.

**Дата принятия:** 2026-10-13.

## ADR-030 · Сообщать о снимке экрана в чатах с исчезающими сообщениями (2026-10-13)

### Context
Запретить снимок экрана на iOS нельзя (система лишь сообщает о нём после факта). Tech-debt 2.27 оставлял «предупреждать при скриншоте» до решения, кого предупреждать и где.

### Decision
- Как в «секретных чатах» Telegram: **только в чатах с включёнными исчезающими сообщениями** (там люди ожидают, что переписка не сохранится). Снимок экрана, сделанный, пока такой чат открыт, даёт системную строку у меня («Вы сделали снимок экрана») и действие `screenshot` (envelope tag 15) всем участникам — у них «{имя}: снимок экрана».
- Обычные чаты — ничего: снимок экрана там нормальное действие, и сообщать о нём было бы неожиданно.
- Источник событий — плагин `screen_protector` 1.5.3 (`userDidTakeScreenshotNotification`), только iOS. Свой Swift-код не нужен.

### Consequences
- **+** Собеседник узнаёт о снимке в том чате, где это важно.
- **−** Это вежливость, не защита: изменённый клиент или второй телефон ничего не сообщат.
- **−** Решение принято без владельца (цель «без моего участия»); переключатель можно добавить, если понадобится.

### Дополнение (2026-10-13, ночной бэклог #5): запись экрана
- `screen_protector` сообщает о начале/конце захвата экрана (`UIScreen.isCaptured`: запись **или** трансляция — iOS их не различает) и даёт `isRecording()` на старте.
- Те же правила, что у снимка: пока экран захватывается, каждый открытый чат с исчезающими сообщениями сообщает об этом **один раз на запись** — и чат, открытый уже во время записи. У меня «Вы записываете экран», у остальных «{имя}: запись экрана».
- На проводе — то же действие `screenshot` (tag 15) с новым полем `recording = 1` (bool). Старый клиент поле не знает и покажет «снимок экрана» — тоже правда по сути; новый тег не понадобился.
- Трансляция экрана (AirPlay) тоже даст строку «записывает» — лучше лишнее предупреждение, чем пропущенная запись.

**Дата принятия:** 2026-10-13.

---

## ADR-031 · «В сети / был(а)» — только контактам и только по согласию (2026-10-14)

### Context
Tech-debt 2.22 (п.32): статуса «в сети» не было — нужен был дизайн с согласием. Владелец (2026-10-14): в настройках выбор; если включено — видят **только контакты**, если выключено — **никто**. Сущности «контакт» в приложении нет, сервер presence не раздаёт и не должен узнавать, кто кому виден.

### Decision
- **Контакт** = собеседник личного чата, который не «запрос на переписку» и не заблокирован. Группы presence не несут.
- **Выключено по умолчанию** (`show_online`, Конфиденциальность → «Показывать, что я в сети»). Не взаимно: выключив своё, человек по-прежнему видит статус тех, кто его показывает.
- **Сквозное шифрование, без сервера:** новое действие `presence` (envelope tag 16: `online`, `hidden`) уходит в каждый личный чат контакта, как «печатает…». Сервер видит только обычные зашифрованные сообщения и не знает, кому статус виден.
- **Когда шлётся:** приложение на экране → «в сети» сразу, повтор каждые 25 с и после переподключения; ушло в фон → «вышел» (один раз, соединение закрывается только после него). «В сети» у получателя действует 55 с от **серверного** времени сообщения (`delivered_at`; время впереди часов получателя считается «сейчас»), поэтому убитое приложение само превращается в «был(а)», а догнавшие после долгого офлайна старые сообщения ничего не включают (старее известного — игнорируется).
- **Выключение** шлёт `hidden`: контакты стирают «был(а)». Принимается presence только от собеседника своего личного чата (не из групп, не из запросов, не от заблокированных); своё эхо с других моих устройств отбрасывается.
- «Был(а)» хранится локально (настройка `presence_seen`), переживает перезапуск.

### Alternatives
- **Presence на сервере** (он и так видит соединения) с фильтром «контакты» — отклонено: серверу пришлось бы знать список контактов, т.е. социальный граф с намерением.
- **Взаимность как у Telegram** (скрыл сам — не видишь других) — не просили; легко добавить одной проверкой при показе.
- **Включено по умолчанию** — отклонено ради приватности.

### Consequences
- **+** Сервер не узнаёт, кто кому виден; статус может подделать только сам контакт (MLS-подпись).
- **−** Трафик: ~144 маленьких сообщения в час на каждого контакта, пока приложение открыто (было 12 при повторе раз в 5 мин); офлайн-контакт получит их пачкой при входе (лишние отбрасываются) — tech-debt 2.53.
- **−** Несколько моих устройств: «вышел» с одного гасит «в сети», пока другое не повторит (≤ 25 с).

### Amendment 2026-10-19 (запись 170) — «в сети» висело после ухода
Владелец: «Пишет, что собеседник в сети, хотя он уже давно вышел». Причины: (1) шапка чата, «Инфо» и профиль следили за объектом `PresenceSeen` через `select`; когда «в сети» истекало, карта переиздавалась с тем же объектом — экран не перерисовывался, пока чат открыт; (2) окно было 6 мин при повторе раз в 5 мин; (3) на iPhone соединение закрывалось в фоне сразу и «вышел» не успевал уйти; (4) старт без экрана (Android «Постоянное соединение», пробуждение push / звонком) считался «на экране» (`lifecycleState == null`) и мог говорить «в сети» с повтором. Теперь: экраны выбирают значение (`presenceShown` / подпись), карта переиздаётся при каждой смене подписи; 25 с / 55 с; закрытие ждёт «вышел» до 3 с; «в сети» — только при `resumed`. Сервер не менялся.
- **−** Сервер и так видит время соединений (как и раньше, §5 threat-model) — это не новая утечка, но и не скрытая.
- **−** Push (после аккаунта Apple) не должен будить ради presence — решает клиент после расшифровки, как для «печатает».

**Дата принятия:** 2026-10-14.

### Amendment 2026-10-19 (запись 176, tech-debt 2.53) — очередь у офлайн-контакта
- **Было:** «в сети» повторяется, пока приложение на экране (с записи 170 — каждые 25 с, ~144 сообщения в час на контакта); кто был не в сети, получал при входе их все (расшифровка, лишние отбрасывались).
- **Решение:** у запечатанной доставки флаг «выбросить, если не доставлено за N с» — `SealedDelivery.drop_after_secs` (proto, поле 6) / `drop_after_secs` в `POST /v1/sealed`. Сервер ставит `message_deliveries.expires_at = NOW() + N` **при записи** (таймер чата — от получения, ADR-020); вход и Resume уже фильтруют `expires_at > NOW()`, уборка удаляет. Если у чата ещё и таймер — при получении срок = меньший из двух. N ≤ 30 дней (как таймер чата).
- **Кто ставит:** отправитель после MLS-шифрования смотрит на свой plaintext — `envelope::drop_after_secs`: 120 с (`STALE_AFTER_SECS`) для «в сети» и «печатает». «Вышел» и `hidden` хранятся как раньше: их по одному на сеанс, а без них у офлайн-контакта не обновились бы «был(а)» и «забыть».
- **Совместимость:** старый сервер поле не знает и хранит как раньше; старый клиент поле не ставит. Обычная отправка (`Submit`, не sealed) флага не несёт — presence почти всегда уходит sealed.
- **−** Сервер видит, какие доставки «скоропортящиеся» (в личном чате это «в сети» или «печатает»); раньше он мог догадаться по размеру и ритму (не срочно, раз в 25 с). Чат и содержимое по-прежнему не видны.
- **−** Убил приложение без «вышел», пока контакт был не в сети, — он этот сеанс не увидит, у него останется прежнее «был(а)».

---

## ADR-032 · Адрес сервера выбирает человек (ввод или QR); установщик сервера одной командой (2026-10-14)

### Context
Адрес сервера был вшит в сборку (`--dart-define=SINHRON_WS_URL`, по умолчанию `localhost`): экран «Сервер» в онбординге был макетом (демо-адрес и поле «код приглашения», которого сервер не знает), введённое никуда не шло; звонки и «начать чат по ключу» тоже брали константу. Владелец: адрес добавляется вручную или по QR-коду, а сервер ставится скриптом на чистую Ubuntu.

### Decision
- **Первый шаг каждого пути** (новый аккаунт, вход по 24 словам, привязка по QR) — «Выберите сервер»: поле адреса и «Сканировать QR-код сервера». Принимается `домен`, `домен:порт`, `https://…`, `wss://…/v1/sync` и QR `sinhron-server:https://…`; всё приводится к `wss://host[:port]/v1/sync` (`lib/core/server_address.dart`). `http://`/`ws://` — только если набраны явно (тестовый сервер в LAN).
- **Проверка до сохранения:** `GET /_healthz` должен ответить `"service":"sinhron-server"`. Ответил не Sinhron — дальше нельзя; не ответил вовсе — сказать и дать «Всё равно продолжить» (сеть через прокси, сервер перезапускается).
- Адрес хранится в `server_url`; всё (WS, медиа, звонки, «начать чат по ключу», привязка) берёт его. `SINHRON_WS_URL` в dev-сборке только подставляет значение в поле. Поле «код приглашения» убрано.
- **Установщик** `server/install.sh` (bash; Ubuntu 22.04/24.04): вопросы **или** файл `/etc/sinhron/sinhron.conf` — ответы пишутся в тот же файл, результат одинаков. Сам ставит пакеты, Docker (официальный репозиторий), ufw (SSH — первым правилом, порт определяется), fail2ban, автообновления, swap при малой памяти; создаёт пароли/ключи один раз (`server/.env`, 0600) и сохраняет их при повторе; проверяет DNS трёх имён; собирает и запускает compose; ждёт `/_healthz` снаружи; ставит ночные копии; печатает адрес и QR. Повторный запуск = обновление. `--dry-run` показывает команды, ничего не меняя.

### Alternatives
- **Python для установщика** — отклонено: bash есть везде, а вся работа — вызовы apt/ufw/systemd/docker; надёжность обеспечена `set -Eeuo pipefail`, явными проверками и тестами (`server/scripts/install_test.sh`, shellcheck, CI на Ubuntu 22.04/24.04).
- **Список «известных серверов» в приложении** — отклонено: нет федерации/каталога (§6.1), и это была бы реклама чужих серверов.
- **Не проверять сервер** — отклонено: опечатка в адресе молча создала бы аккаунт «нигде».

### Consequences
- **+** Одна сборка приложения для любых серверов; оператор отдаёт людям адрес или QR из установщика.
- **+** Чистый VPS → работающий сервер одной командой; повтор безопасен.
- **−** QR или адрес может подсунуть злоумышленник: человек зарегистрируется на чужом сервере. Сообщения всё равно сквозь MLS, но метаданные увидит тот сервер — адрес нужно брать у того, кому доверяете (threat-model §5 п.18).
- **−** Установщик проверен юнит-тестами, shellcheck и `--dry-run` на реальной Ubuntu в CI, но полный боевой прогон (Let's Encrypt, звонки через NAT) — только на настоящем VPS с доменом.

**Дата принятия:** 2026-10-14.

---

## ADR-033 · Зашифрованная копия каждого медиафайла на устройстве (2026-10-15)

### Context
По ADR-017 телефон хранил только ключ блоба (в `messages.media_json`, SQLCipher), а сам блоб каждый раз скачивал заново: расшифрованные байты живут лишь в RAM (`MediaCache`), после перезапуска приложения — новая загрузка. Сервер удаляет блоб, который 90 дней никто не загружал и не скачивал (`handlers/media.rs`). Итог: без сети старые фото не открываются, а фото, которое три месяца никто не открывал, пропадает у всех навсегда. Владелец попросил хранить на телефоне зашифрованную копию.

### Decision
- **Каждый блоб, который это устройство отправляет или скачивает, сохраняется как есть — шифротекстом** (`nonce‖ct‖tag`, тот же, что на сервере) в `<файл БД>.blobs/<первые 2 hex>/<sha256>` рядом с `sinhron.db` (`sinhron_storage::blobs`). Ключ к нему по-прежнему только в SQLCipher-базе; расшифрованные байты на диск не пишутся (spec §8.6 не меняется).
- **Отправка:** копия пишется до загрузки на сервер (`media::upload_with_progress`, картинка превью ссылки — `link_preview::build`). **Открытие:** `media::fetch` сначала читает копию и проверяет её так же, как загрузку (sha256 и размер до AES-GCM); испорченная копия удаляется, файл берётся с сервера; скачанный блоб сохраняется. Запись — во временный файл и `rename`, имена — только 64 строчных hex (защита от обхода путей).
- **Срок жизни копии = срок жизни сообщения.** Удаление у себя, «удалить у всех», исчезающие сообщения, удаление чата, очистка чатов и замена превью ссылки удаляют файлы, на которые больше не ссылается ни одна строка (`blobs::drop_unreferenced`). При каждом открытии базы с ключом фоновая уборка (`blobs::gc`) удаляет всё, на что нет ссылок и что старше суток (не трогает отправку в процессе). «Стереть и начать заново» удаляет каталог вместе с базой.
- Без открытой базы (CLI, тесты, e2e-примеры) копия просто не ведётся — отправка и открытие работают как раньше.

### Alternatives
- **Хранить расшифрованные файлы** — отклонено: нарушило бы spec §8.6 (на диске только шифротекст), а для исчезающих сообщений оставляло бы содержимое на диске.
- **Держать копии в SQLCipher-базе (BLOB)** — отклонено по той же причине, что и на сервере (ADR-017): многомегабайтные строки раздувают базу, WAL и резервные копии и требуют держать файл целиком в памяти при каждом запросе.
- **Каталог кэша ОС (iOS `Library/Caches`)** — отклонено: система чистит его при нехватке места, и файл, уже удалённый сервером, пропал бы снова.
- **Продлевать срок на сервере** (клиент периодически «трогает» блобы) — отклонено: лишний трафик и метаданные «кто всё ещё держит файл»; локальная копия решает задачу без сервера.

### Consequences
- **+** Медиа открываются без сети и после перезапуска без новой загрузки; файл остаётся у тех, у кого он уже был, и после 90-дневной уборки сервера.
- **+** На диске нет ничего нового в открытом виде: шифротекст без ключа из SQLCipher бесполезен.
- **−** Место на телефоне растёт вместе с медиа в чатах; ограничения и экрана «Хранилище» пока нет (tech-debt 2.32).
- **−** Файлы, полученные до этого изменения, попадают в копию только при первом открытии; если сервер уже удалил блоб, вернуть его нельзя.
- **−** Каталог лежит рядом с базой в `Documents` и попадает в резервную копию iCloud (бесполезен без ключа базы, но занимает место) — исключение из бэкапа — tech-debt 2.32.

**Дата принятия:** 2026-10-15.

## ADR-034 · Группы из нескольких человек: один Commit на всех, имя — сообщением в группе (2026-10-15)

### Context
До сих пор настоящими были только личные чаты: `createMlsChat` создаёт MLS-группу и приглашает одного человека (`sync_fetch_kp_and_invite` → `invite_devices` со всеми его устройствами, ADR-025). Экран «Новая группа» показывал демо-контакты и ничего не создавал — его скрыли (status 68). Несколько человек скоро будут проверять звонки на тестовом сервере, нужны группы. Вторая половина вопроса — как участник узнаёт, что это группа, и её имя: Welcome имени не несёт, приглашённый создавал строку чата с заглушкой «Группа ab12cd34», а признак группы угадывал по числу участников (> 2).

### Decision
- **Создание — один Commit:** `SyncClient::fetch_kps_and_invite_people` — KeyPackage каждого активного устройства каждого человека (`fetch_people_keypackages`; себя и повторы пропускает), один `invite_devices` (все Add в одном Commit), один `announce_group` со всеми устройствами, один Welcome. Никто не добавляется, если у кого-то нет KeyPackage (ошибка с началом его ключа). FFI `sync_fetch_kps_and_invite_people` запоминает устройства каждого человека (`invited_devices`), и `net_send_welcome` шлёт каждому свою копию того же Welcome, адресованную его устройствам. Commit никому не отправляется: в новой группе, кроме создателя, никого нет. Личный чат (`fetch_kp_and_invite_devices`) теперь — частный случай с одним человеком.
- **Имя — новый тип конверта `GroupName { name }`** (ADR-017, тег 17; действие `group_name`). Создатель отправляет его сразу после Welcome — обычным MLS-сообщением в группу (сервер видит только шифротекст). Имя чистится как отображаемое имя (`clean_profile_name`: без управляющих и невидимых символов, ≤ 64 знаков). У получателя (`MessageActions.onIncomingAction`) → `storage::chat_set_group_name`: применяется к групповому чату (переименование) или к чату, у которого ещё заглушка (на любом из двух языков) — такой чат становится группой (группа из двоих иначе выглядела бы личной). Личный чат с уже известным именем не трогается — собеседник не может переименовать мой личный чат.
- **Добавить людей позже** (`sync_add_group_members`, «Добавить участника» в информации о группе): Commit ждёт порядка от сервера (ADR-022: `Submit{is_commit, commit_epoch}`, применяется только по Ack 0, при 409 — «попробуйте ещё раз»); тот же Submit доставляет его всем нынешним участникам. Затем анонс устройств, Welcome каждому новому и снова `GroupName`, чтобы новые увидели имя.
- **Экран «Новая группа»** выбирает из настоящих людей — принятые личные чаты с известным ключом (`ChatPreview.peerId`, имя из `peerNamesProvider`), без заблокированных и без уже состоящих (`groupCandidates`). Создание → чат группы; «Новый чат» уходит из стека.

### Alternatives
- **Имя в расширении GroupContext MLS** — отклонено: неизвестные расширения группы должны поддерживать все участники (capabilities в KeyPackage), а уже опубликованные KeyPackages их не объявляют; смена формата KeyPackage ради имени — несоразмерно.
- **Имя в кадре Welcome открытым текстом** — отклонено: сервер узнал бы имя группы.
- **Приглашать по одному (N Commit'ов)** — отклонено: N эпох вместо одной, N-1 Commit'ов надо доставлять уже вошедшим, и группа долго «собирается»; один Commit — то, что описано в spec §6.5.
- **Признак группы только по числу участников** — оставлен как первая догадка при Welcome, но не единственный: группа из двоих иначе неотличима от личного чата.

### Consequences
- **+** Группа из трёх и более человек — одна эпоха, один Welcome; проверено в процессе (`client::tests::three_person_group_everyone_reads_everyone`) и через настоящий сервер (`examples/groups_e2e.rs`: трое, имя, четвёртый добавлен позже — все читают всех).
- **+** Сервер не видит имя группы; членство (какие устройства в группе) он знал и раньше (`announce_group`, ADR-025).
- **−** Имя приходит отдельным сообщением: если оно потеряется (например, Push пришёл раньше, чем обработан Welcome), участник увидит заглушку до переименования. Аватар-градиент группы, выбираемый на экране, никуда не передаётся.
- **−** Если у одного из выбранных нет KeyPackage, создание падает, а KeyPackages остальных уже взяты с сервера (каждое устройство публикует новые при входе).
- **−** Выйти из группы, удалить участника, переименовать из интерфейса и права админа — не сделаны (tech-debt 2.34) → сделано в ADR-035.

**Дата принятия:** 2026-10-15.

## ADR-035 · Управление группой: выйти, удалить, переименовать; админ — создатель (2026-10-16)

### Context
ADR-034 сделал группы из нескольких человек, но из группы нельзя было выйти, удалить участника или переименовать её из интерфейса, и не было прав (tech-debt 2.34). Сервер не видит содержимое Commit'ов (ADR-022) и не знает, кто в группе главный; MLS не позволяет участнику закоммитить собственное удаление.

### Decision
- *Заменено ADR-088 (2026-11-04): админ записан в контексте группы MLS, правило «лист 0» неверно.* **Админ = создатель группы = лист 0 дерева MLS** (`MlsGroupState::creator_identity`). Все участники видят одно и то же дерево, поэтому согласны, кто админ, без нового поля и нового сообщения. Админ переименовывает и удаляет; «Добавить участника» показывается только ему. Когда создатель уходит, лист 0 пуст — админа нет, управлять может любой участник (группа не «застревает»). *Дополнено 2026-11-04 (запись 231, `docs/security-review-2026-11.md`, mls-identity:3):* нового **человека** (у кого не было листа) принимают только из Commit'а того, кто может управлять (`GroupHandle::may_add_people` — то же правило, что «Добавить участника»; читается из общего дерева, поэтому у всех один ответ); чужой такой Commit не применяется, а обычное приложение его и не собирает. Новые устройства уже бывших в чате людей (ADR-074) добавляет любой, как раньше. *Оговорка (mls-identity:8, исправлено в ADR-088):* лист 0 после ухода создателя пуст недолго — MLS кладёт следующего добавленного в самый левый свободный лист, и «админом» становился он.
- **Удалить участника** (`sync_remove_group_members` → `remove_identities_pending`: все листья этих людей, один Commit) — по порядку сервера, как добавление (ADR-022: `Submit{is_commit}` → Ack 0 → `confirm_commit`). Затем конверт `MembersRemoved{identities}` (тег 19, действие `removed`) — для старых приложений. *С записи 231* строки «Аня удалил(а): Борис» и «Аня добавил(а): Дима» пишет сам Commit: Rust возвращает, кто вошёл и кто ушёл совсем (`IncomingMessage::Commit{added, removed}`), и кто закоммитил (`action_json` push'а `control` → `onGroupCommit`); строка `removed` больше ничего не добавляет. Удаление того, кто сам сказал «выхожу», второй строки не даёт.
- **Выйти** — конверт `Leave{}` (тег 18, действие `leave`) в группу; получатели показывают «X вышел(а)» и через случайные 0,3–2,3 с один из них коммитит удаление (проигравшие получают отказ сервера по эпохе и ничего не делают). Сам вышедший подписывает `POST /v1/groups/{id}/leave` (домен `sinhron-group-leave-v1:`, тело — id группы; удаляет строки `group_members` всех устройств этой личности, идемпотентно) — сервер перестаёт слать ему сообщения группы — и удаляет чат у себя.
- **Удалённый** узнаёт об этом из Commit'а (`group_is_active` = false после обработки): строка «Вас удалили из группы», вместо поля ввода — «Вы больше не участник этой группы» и кнопка «Удалить чат», и тот же `leave` на сервере.
- **Переименовать** — прежнее действие `group_name` (ADR-034); новым именем считается только имя от того, кто может управлять (первое имя группы по-прежнему заменяет заглушку от любого участника).
- Системные строки хранятся кодами (`member-left:<имя>`, `member-removed:(me|by:<имя>):<имена>`, `member-added:by:<имя>:<имена>`, `group-renamed:…`, `you-removed`) и переводятся при показе (`systemLineText`).

### Alternatives
- **Роль админа в расширении GroupContext MLS** — отклонено по той же причине, что имя в ADR-034 (KeyPackages не объявляют расширение). Лист 0 даёт то же без смены формата. *Принято позже (ADR-088) на стандартном расширении `external_senders`, которое объявлять не нужно; лист 0 оказался ненадёжным.*
- **Самоудаление через MLS Remove Proposal** от уходящего, которое коммитит другой, — откладывается: нужно хранить и пересылать предложения; сообщение `Leave` + Commit от любого участника проще и даёт тот же результат.
- **Сервер проверяет права** — невозможно без раскрытия ему содержимого Commit'а; права соблюдают честные клиенты (как и раньше: сервер видит только шифротекст).

### Consequences
- **+** Выйти, удалить, переименовать — из «Информации о чате»; удалённый и вышедший не читают новых сообщений (проверено: `creator_removes_a_member_who_then_knows_and_reads_nothing_new`, `a_member_commits_the_leavers_removal_even_the_creators`).
- **−** Права админа соблюдают клиенты, а не криптография: изменённый клиент может закоммитить удаление (тот же путь у честного «выхожу»). С записи 231 все обновлённые увидят строку «X удалил(а): Y» с настоящим автором Commit'а; добавить нового человека не-админ не может — обновлённые телефоны такой Commit не применят (и отстанут от чата, а не впустят чужого) — модель угроз, раздел о группах.
- **−** Если удалённый никогда больше не откроет приложение, сервер продолжает класть ему шифротексты группы до срока хранения (он их не прочтёт). Удаление на сервере — только его собственной подписью.
- **−** Вышедший, пока никто из оставшихся не был в сети, формально остаётся в дереве (Commit сделают при первом получении `leave`); сообщения ему сервер уже не шлёт.

**Дата принятия:** 2026-10-16.

## ADR-036 · Базы и копии медиа не попадают в резервные копии iOS (2026-10-16)

### Context
Tech-debt 2.32: каталог копий медиа `sinhron.db.blobs` (ADR-033) лежит в `Documents` и уходил в резервную копию iCloud / компьютера вместе с базами `sinhron.db` и `sinhron-mls.sqlite`. Без ключа устройства (Keychain, `ThisDeviceOnly`, ADR-021) эти файлы бесполезны на другом телефоне, но занимают место в iCloud владельца. Хуже: состояние MLS из старой копии отстаёт от групп (эпохи ушли вперёд) — восстановленный из бэкапа телефон получил бы сломанные группы.

### Decision
При запуске и при уходе приложения в фон (`AppDelegate.excludeFromBackup`) все элементы `Documents/sinhron*` помечаются `isExcludedFromBackup`; каталог копий медиа создаётся заранее, чтобы файлы, записанные в него позже, были исключены вместе с ним. Восстановление — только 24 слова и синхронизация (spec §6.8), не бэкап.

### Alternatives
- **Оставить в бэкапе** — отклонено: место в iCloud и риск восстановить отставшее состояние MLS.
- **Перенести базы в `Library/Caches`** — отклонено: iOS может очистить кэш при нехватке места — пропала бы история.
- **Перенести в `Application Support`** — тот же бэкап, плюс миграция файлов; флаг проще.

### Consequences
- **+** Резервная копия iPhone не растёт вместе с медиа в чатах; нет восстановления устаревшего MLS-состояния.
- **−** Переезд на новый телефон через «Восстановить из копии» не переносит историю чатов — она не переносилась и раньше (ключ устройства не уходит в бэкап); путь — фраза из 24 слов.
- **−** Файл базы, созданный после запуска (WAL), помечается при следующем уходе в фон — до этого он мог бы попасть в копию, если бэкап случится раньше.

**Дата принятия:** 2026-10-16.

## ADR-037 · Удаление аккаунта, жалобы оператору, правила в приложении (2026-10-16)

### Context
App Store: правило 5.1.1(v) — аккаунт, созданный в приложении, должен удаляться из приложения; правило 1.2 (общение пользователей) — правила с нулевой терпимостью к недопустимому, жалобы с реакцией, блокировка, контакты. До этого «Удалить аккаунт» в release был макетом дизайна (подтверждение вводом «vera», выдуманная дата, ничего не удалялось), жалоб не было, правил в приложении не было. Сервер не видит переписку (MLS) и не знает «модератора».

### Decision
- **Удаление — сразу, без «7 дней на раздумье».** `POST /v1/account/delete`, подпись **самим ключом личности** (домен `sinhron-account-delete-v1:`, тело — ключ личности); привязанное по QR устройство спрашивает 24 слова (ADR-027) — устройство, у которого украли телефон без фразы, аккаунт не удалит. Сервер в одной транзакции удаляет человека: `users` (каскадом устройства, KeyPackages, членство в группах, ключи доставки, резервная копия состояния, ждущие Welcome), очередь доставки и push-токены; медиа, которые он отправил, остаются у получателей (`media.uploaded_by_device` → NULL). Живые соединения закрываются. Приложение: сначала `leave` во все группы (участники коммитят удаление), затем сервер, затем стирание телефона; если сервер отказал — ничего не стирается.
- **Жалоба — оператору своего сервера.** `POST /v1/reports` (домен `sinhron-report-v1:`, подпись покрывает ключ обвиняемого, причину и текст; привязанное устройство жалуется от имени своего человека): причина (`spam` / `abuse` / `illegal` / `other`) и **по выбору жалующегося** текст сообщения (≤ 4000 знаков). Таблица `abuse_reports` хранит ключи, не строки пользователей — жалоба переживает удаление аккаунта. Не больше 50 жалоб в сутки от одного человека. Из меню чужого сообщения («Пожаловаться») и из информации о чате / участнике; после отправки — предложение заблокировать. Оператор смотрит жалобы SQL-запросом (onboarding §6.7) и удаляет нарушителя тем же путём, что и сам человек (`DELETE FROM users …`).
- **Правила в приложении:** «Настройки → Правила и поддержка» — условия (нулевая терпимость, жалобы рассматриваются обычно в течение 24 часов, блокировка, сквозное шифрование), конфиденциальность (что знает сервер), помощь (сервер и как пожаловаться). На первом экране — «Продолжая, вы принимаете Условия использования» (открывает их).

### Alternatives
- **Отложенное удаление (7 дней)** — отклонено: дольше и сложнее (фоновая задача, отмена со всех устройств) ради редкого случая; Apple этого не требует. Фраза позволяет зарегистрироваться заново (без старых чатов).
- **Модерация на сервере по содержимому** — невозможна (E2E); только то, что жалующийся сам отправил.
- **Жалобы разработчику приложения, а не оператору** — отклонено: у каждого сервера свой оператор (self-hosted); для серверов владельца App Store это одно и то же лицо.

### Consequences
- **+** Требования 5.1.1(v) и 1.2 закрыты в коде; удалённый аккаунт исчезает с сервера за один запрос.
- **−** Жалобу с текстом оператор читает открытым текстом — так решил жалующийся (написано в листе жалобы).
- **−** Удалённый человек остаётся листом в MLS-деревьях групп, где его `leave` не дошёл (был офлайн) — сообщения ему сервер уже не доставляет; оставшиеся могут удалить его вручную (ADR-035).
- **−** Интерфейса оператора для жалоб нет — SQL (onboarding §6.7).

**Дата принятия:** 2026-10-16.

## ADR-038 · Push-уведомления: «срочный» бит от отправителя, токены APNs у сервера (2026-10-16)

### Context
Ключ APNs (.p8) у владельца есть (2026-10-15). Сервер умел только заглушку `LoggingPush`, а запечатанная доставка (ADR-023), которой идут почти все сообщения, push вообще не вызывала. Сервер не отличает сообщение от отчёта о прочтении, «печатает» или присутствия — всё шифротекст; будить телефон ради «печатает» нельзя (tech-debt 2.22).

### Decision
- **«Срочный» бит ставит отправитель:** `SealedDelivery.urgent` / `Submit.urgent` (proto, поля 4 и 7) — только для настоящего сообщения (текст, ссылка, фото / видео / голос / файл, или конверт новее нашего), не для своей копии на моих устройствах (`envelope::wakes_recipient`). Сервер хранит его в `message_deliveries.urgent`.
- **Кого будить:** получателя без живого соединения (`deliver_sealed` → `live = false`) — все его активные устройства с токеном; в фоне (`push::spawn_notify`), обработчик WS не ждёт Apple. Бейдж — число непринятых срочных доставок.
- **Что в уведомлении:** только «Новое сообщение» / «New message» на языке телефона и бейдж; `apns-collapse-id` — одно уведомление, заменяемое следующим (не видно и сколько сообщений). Ни текста, ни имени, ни чата (tech-debt 2.7).
- **Токены:** `PUT /v1/push-token` — подпись ключом самого устройства (ключ входа), тело `kind ‖ 0 ‖ token ‖ sandbox ‖ lang`; таблица `apns_tokens (device, kind alert|voip, token, sandbox, lang)`; пустой токен — снять; тот же токен с другого устройства переезжает. Мёртвый токен (410 / BadDeviceToken) удаляется после ответа Apple. `sandbox` приложение определяет по `embedded.mobileprovision` (`aps-environment` = development у сборок из Xcode; у TestFlight / App Store — production).
- **APNs:** HTTP/2 (`reqwest` + rustls) к `api.push.apple.com` / `api.sandbox.push.apple.com`, JWT ES256 (`p256`) из .p8, переиспользуется 50 минут. Включается только при `APNS_KEY_PATH` + `APNS_KEY_ID` + `APNS_TEAM_ID` (`APNS_TOPIC` по умолчанию `com.sinhron.sinhron`); иначе push выключен.
- **Ключ на сервере:** `/etc/sinhron/apns/AuthKey.p8`, владелец uid 10001 (пользователь контейнера), права 400, каталог монтируется только для чтения. (План был «root, 600» — тогда контейнер не смог бы его прочитать.)
- **Приложение:** переключатель «Уведомления о сообщениях» (по умолчанию вкл.) в «Звуки и вибрация»; при запуске спрашивает iOS один раз, регистрирует APNs и отправляет токен (повторно — при каждом подключении к серверу, если что-то поменялось). В открытом приложении системный баннер не показывается — есть свой. Нажатие на уведомление открывает приложение (какой чат — не знает никто, кроме телефона).

### Alternatives
- **Notification Service Extension, расшифровывающая сообщение** (текст в уведомлении) — отложено: отдельный target с доступом к базе и MLS-состоянию в App Group, переделка хранения ключей; ночью не делали. **Сделано иначе 2026-10-18 (ADR-056):** расширение вскрывает не сообщение, а запечатанное превью от отправителя — без MLS и базы.
- **Сервер решает сам по размеру** — ненадёжно и всё равно метаданные.
- **Localizable.strings + `loc-key`** — отклонено: нужно править проект Xcode; язык с токеном проще.

### Consequences
- **+** Закрытое приложение узнаёт о сообщениях; квитанции и «печатает» никого не будят.
- **−** Сервер узнаёт, какая доставка — «настоящее сообщение», а какая служебная (раньше все были одинаковы). Apple видит время уведомления и устройство (как и раньше в плане).
- **−** Текста в уведомлении нет — только «Новое сообщение». **Дополнено 2026-10-18 (ADR-056):** имя и текст пишет на телефоне расширение уведомлений из запечатанного превью.
- **−** Проверено только тестами (подписи, выбор получателей, бейдж, удаление мёртвых токенов) — живой push на iPhone после обновления сервера и установки сборки.

**Дата принятия:** 2026-10-16.

## ADR-039 · Входящий звонок при закрытом приложении: PushKit + повтор приглашения (2026-10-16)

### Context
Без PushKit звонок к человеку с закрытым приложением сразу отвечал «callee offline». iOS требует: каждый VoIP-push должен немедленно показать звонок в CallKit (иначе система перестаёт будить приложение). Сервер не знает имён и не должен сообщать Apple, кто звонит и в какой группе (tech-debt 2.7).

### Decision
- **Сервер:** приглашённым без соединения — VoIP-push (`apns-push-type: voip`, topic `<bundle>.voip`, срок 0) с телом только `{call_id, video}` на их токены `kind = voip`; если разбудить можно хоть кого-то, звонок звонит (`ack 0 ringing`), иначе «callee offline», как раньше. Устройство, вошедшее по WS, получает приглашения звонков, которые ещё звонят для него (`replay_ringing_invites`, `CallSessionRegistry::ringing_for`, оставшийся TTL).
- **iPhone:** `PKPushRegistry` создаётся при запуске; push → `CallKitBridge.shared.reportFromPush` сразу показывает «Sinhron · входящий» (имени ещё нет). Приложение подключается, получает приглашение, Dart вызывает `reportIncoming` — звонок «забирается» и получает имя чата. «Ответить» / «Отклонить», нажатые раньше, хранятся и передаются при забирании (отклонение — `decline`, не `hangup`). Не забранный за 45 с (звонок кончился) или отсеянный Dart'ом (заблокирован, запрос, входящие выключены — `dismiss`) — закрывается без звука.
- **Токен PushKit** — тот же `PUT /v1/push-token` (`kind = voip`), отправляется, пока включены «Входящие звонки»; выключили — токен снимается с сервера.
- `voip` в `UIBackgroundModes` остаётся (теперь используется).

### Alternatives
- **Имя звонящего в push** — отклонено: Apple узнала бы, кто кому звонит; сервер имён не знает.
- **Отдельный CXProvider для push** — отклонено: один провайдер на процесс (`shared`), созданный до Flutter.

### Consequences
- **+** Звонок до закрытого / заблокированного iPhone звонит на экране блокировки.
- **−** До подключения на экране «Sinhron», а не имя; если сервер недоступен телефону, звонок через 45 с закрывается. **Закрыто 2026-10-18 (ADR-056):** HMAC-метка чата в VoIP-push — имя сразу.
- **−** Звонок, отсеянный приложением (заблокированный человек), мелькнёт на экране, пока приложение подключается — iOS не позволяет не показать VoIP-push. **2026-10-18 (ADR-056):** по метке чата такой звонок завершается сразу после показа.
- **−** Проверено тестами сервера и разбором Swift; живая проверка — с iPhone после обновления сервера.

### Дополнение (2026-10-16, день) — ответ кнопкой в приложении
Владелец: звонят, приложение открыто — видно и наш экран звонка, и баннер iOS «Принять». Ответ кнопкой в приложении начинал звонок, но баннер iOS оставался; системная кнопка — всё правильно. Причина: Dart не сообщал CallKit об ответе (в канале не было такого метода). Теперь `accept()` от своей кнопки вызывает `answerCall` → `CXAnswerCallAction` (CallKit считает звонок отвеченным — то же состояние, что после системной кнопки); ответ CallKit на наш же запрос в Dart не возвращается (`answeredByApp`). Android: то же — `answerCall` убирает полноэкранное уведомление входящего.

**Дата принятия:** 2026-10-16.

## ADR-040 · Android без Google: UnifiedPush через свой ntfy, нативные уведомления, APK (2026-10-16)

### Context
Владелец (2026-10-15): Android-клиент — без Google Play Services / FCM, без Huawei, без платных магазинов. Flutter-код общий, но на iOS часть сделана нативно (Keychain, сканер QR, CallKit, APNs / PushKit), и этого на Android нет. Push на Android без FCM возможен только через стороннее приложение-дистрибьютор (UnifiedPush) или постоянное соединение.

### Decision
- **Push — UnifiedPush, дистрибьютор ntfy на сервере оператора** (`docker compose --profile ntfy`, поддомен `push.<домен>`, установщик `ENABLE_NTFY=yes`). Телефон даёт адрес (endpoint) вместо токена APNs — тот же `PUT /v1/push-token`, та же подпись; сервер (`server/src/unifiedpush.rs`) POST'ит туда `{"t":"msg","n":…}` или `{"t":"call","id":…,"v":…}` — без текста, чата, имени. **Только `https` и только хосты из `SINHRON_UNIFIEDPUSH_HOSTS`** (свой ntfy) — сервер не станет ходить по произвольным адресам (SSRF); редиректы не следуются; таблица токенов та же (`apns_tokens`, миграция `20261016020000` разрешает `https://…`).
- **Уведомления рисует Sinhron:** `SinhronPushService` (коннектор UnifiedPush 3.3.5) → «Новое сообщение» (каналы `messages`, `calls`, `ongoing_call`); звонок — уведомление CallStyle на весь экран блокировки с «Ответить» / «Отклонить» и тем же «забиранием» звонка, что ADR-039 (`Calls.kt`); на время звонка — foreground service (микрофон, камера для видео).
- **Ключ устройства** — AES-256-GCM-ключ в Android Keystore шифрует значение в SharedPreferences (`SecureStore.kt`); бэкап выключен (`allowBackup=false`, `data_extraction_rules.xml` — как ADR-036).
- **QR** — CameraX + ZXing core (без ML Kit).
- **Раздача** — подписанный APK (ключ подписи вне git) + Obtainium; позже F-Droid.

### Alternatives
- **FCM** — отклонено владельцем (Google видит время сообщений каждого, нужен Google-аккаунт / Play Services).
- **Постоянное соединение (foreground service с WS)** без дистрибьютора — позже, как запасной путь: значок в шторке всегда, батарея.
- **Чужой ntfy (ntfy.sh)** — возможно через `SINHRON_UNIFIEDPUSH_HOSTS`, но по умолчанию только свой.
- **Шифрование тела (WebPush RFC 8291)** — сначала отложено; сделано в тот же день (дополнение 2).

### Consequences
- **+** Android-клиент без Google; push и звонки на экране блокировки.
- **−** Нужно поставить ntfy на телефон и указать в нём свой сервер (`push.<домен>`); без него — только когда приложение открыто (в настройках подсказка).
- **−** Отклонение звонка из уведомления, пока приложение не запущено, серверу не уходит — звонящий услышит «нет ответа».
- **−** Проверено только сборкой APK и тестами; на телефоне — после установки (владелец).

### Дополнение 1 (2026-10-16, день) — «Всегда на связи» без ntfy
Запасной путь для телефонов без дистрибьютора — **переключатель «Всегда на связи»** (только Android, `android_keep_connected`, по умолчанию выкл.): `KeepAliveService` (foreground service `remoteMessaging`, тихое уведомление в шторке), один Flutter-движок на процесс (`SinhronApplication` кладёт его в `FlutterEngineCache`, `MainActivity` берёт его), `BackgroundConnection` не закрывает соединение в фоне. Уведомление о сообщении рисует само приложение из расшифрованного сообщения (`maybeShowBanner` → `showMessage`): имя чата и текст, или только «Sinhron», если «Показывать текст» выключен; заглушённые и архивные — молчат. После перезагрузки / обновления — `KeepAliveBootReceiver`: Android поднимает движок **без экрана**, поэтому каналы, которым экран не нужен (keychain, push, callkit), регистрируются на движке до старта Dart (`SinhronApplication.attachHeadless`; когда экран закрывается — снова они, без ссылки на Activity), а соединение открывает `main` (`connectWithoutScreen`) — без экрана виджеты не строятся. Разрешение на уведомления спрашивается после первого соединения с сервером, не на первом экране. Проверено на эмуляторе (Android 15): Home и Back — соединение живо 60+ с, процесс в состоянии foreground service.

### Дополнение 2 (2026-10-16, день) — тело UnifiedPush зашифровано (RFC 8291)
Телефон присылает с адресом свои ключи Web Push (`p256dh`, `auth`, base64url — их даёт коннектор UnifiedPush); они входят в подпись `PUT /v1/push-token` (`… ‖ 0 ‖ p256dh ‖ 0 ‖ auth`) и хранятся в `apns_tokens.webpush_p256dh` / `webpush_auth`. Адрес без ключей — 400; старый адрес без ключей при первой отправке удаляется (приложение зарегистрирует его заново). Сервер шифрует тело (`server/src/webpush.rs`: aes128gcm, свежий эфемерный ключ и соль на каждый push; совпадает с примером RFC 8291 Appendix A) и шлёт `Content-Encoding: aes128gcm`; коннектор на телефоне расшифровывает, **нешифрованные push телефон отбрасывает**. Попутно: Rust-клиент больше не переводит адрес в нижний регистр (путь ntfy-топика чувствителен к регистру — push бы не дошёл).

### Дополнение 3 (2026-10-18) — «Всегда на связи» и батарея
Владелец спросил, не сажает ли режим батарею (Samsung Galaxy A40). Главный расход — heartbeat раз в 20 с: каждый будит радио мобильной сети (~10 с на высокой мощности), три раза в минуту весь день. Теперь вне экрана и без звонка приложение просит у сервера промежуток **120 с** (`Heartbeat.next_within_secs`, поле 2), сервер соглашается (не больше 300 с) и держит такую сессию 180 с без данных; клиент переходит на 120 с только после ответа сервера (старый сервер отвечает 0 — остаётся 20 с). Мёртвая связь в фоне видна через 30 с после heartbeat без ответа; смена сети (Wi-Fi ↔ мобильная) — переподключение сразу (`NetworkWatch.kt`). На экране и в звонке — 20 с, первый heartbeat сразу. iPhone не меняется (там соединение в фоне закрыто). «В сети» из фона и раньше не повторялось — теперь это закреплено тестом; проверка устройств раз в 5 мин в фоне выключена. Цена: сервер может до 180 с (вместо 45) считать умершую фоновую сессию живой и не слать на телефон push. Не измерено на телефоне. Подробно — status 151, tech-debt 2.44.

**Дата принятия:** 2026-10-16.


---

## ADR-041 · Звонки на плохом интернете и слабых телефонах (2026-10-16)

### Context
Владелец спросил, как звонки переживут плохой интернет и слабые телефоны, особенно Android. Ревью (2026-10-16): клиент публиковал камеру и микрофон с умолчаниями livekit_client 2.7.0 — 720p / 30 к/с / до 1,7 Мбит/с VP8 (программный на iPhone и многих Android), Opus 48 кбит/с; ни показателя качества связи, ни перехода на «только звук», ни облегчённого режима для слабых телефонов. На сервере TURN over TLS на 443 **уже был** (ADR-016: Caddy layer4 → coturn TCP 3478, `turns:<turn-хост>:443` в `TURN_URLS`); `no-tcp-relay` в coturn касается только TCP-relay к пиру (RFC 6062), а не подключения клиента по TCP/TLS — WebRTC он не нужен.

### Decision
- **Явные настройки публикации** (`client_flutter/lib/features/calls/call_quality.dart`, применяются в `livekit_engine.dart` через `RoomOptions`): обычный телефон — захват 540p, 24 к/с, верхний слой 700 кбит/с, слои simulcast 180p/120 кбит/с и 360p/350 кбит/с; **слабый Android** (`isLowRamDevice`, ОЗУ ≤ 4 ГБ — `totalMem` ≤ 4608 МБ, ≤ 4 ядер или Android < 9; через `device_info_plus` 12.4.0, уже был в lock) — 360p, 15 к/с, 350 кбит/с, один слой 180p (на кодер меньше). Голос — Opus + DTX + RED (явно); **с 2026-10-16 — потолок голоса по качеству связи** (`callAudioBitrateFor`: отлично 40 кбит/с, хорошо 32, плохо 20, потеряна 14; старт 32; меняется на лету через `RtpSender.setParameters`, без пересогласования), фильтр низких частот захвата включён (гул, ветер, стук), на iPhone — выбор режима микрофона («Изоляция голоса») из звонка.
- **Кодек:** H.264, если он есть в списке кодеров WebRTC этого телефона (`getRtpSenderCapabilities('video')`; на Android он там только при аппаратном кодере, на iOS — VideoToolbox), иначе VP8. Выключатель `kCallPreferH264`.
- **Резервный кодек (backup codec) выключен.** livekit_client 2.7.0 вешает SFrame-шифратор только на основной sender дорожки; копия резервным кодеком (её шлют по запросу SFU) ушла бы на сервер **незашифрованной**. E2EE важнее совместимости.
- **Сервер:** `livekit.yaml` — `congestion_control.allow_pause: true` (SFU ставит на паузу *видео* подписчика, которому не хватает канала, звук идёт дальше; по умолчанию было `false`); `room.enabled_codecs` — только `opus`, `red`, `vp8`, `h264`, `rtx` (AV1 Dart-SDK не шифрует — сервер его теперь не примет; VP9/H.265/PCM приложение не шлёт; RTX — повторы потерянных пакетов). `/v1/call/turn` чистит `TURN_URLS` (пустые, повторы, не `turn:`/`turns:`/`stun:` — с предупреждением) и один раз пишет в лог, если нет `turns:` (нет пути через 443).
- **Качество связи на экране:** три полоски у таймера (`ConnectionQuality` LiveKit для меня) и строка «Слабая связь» / «Слабая связь у собеседника».
- **Автоматически «только звук»:** моя связь `poor`/`lost` 8 с подряд при включённой камере → камера выключается, строка «Слабая связь — камера выключена, чтобы не пропадал звук» (`AudioOnlyFallback`). Включил камеру сам — следующий раз только после 30 с плохой связи.

### Alternatives
- **Встроенный TURN LiveKit (TLS)** вместо coturn — отклонено: 443 уже занят Caddy layer4 и работает (ADR-016), второй TURN — лишняя поверхность.
- **Включить TCP-relay в coturn** — не нужно (см. Context), только расширило бы злоупотребления.
- **Резервный VP8 при H.264** — отклонено из-за утечки нешифрованного видео (см. Decision); вернуть, когда SDK начнёт шифровать дополнительные кодеки.
- **Спрашивать перед выключением камеры** — нет: на плохой связи диалог сам по себе мешает; кнопка «Видео» возвращает камеру одним нажатием.
- **Прятать чужое видео при моей плохой связи** — делают adaptiveStream/dynacast и `allow_pause` на сервере.

### Consequences
- **+** Меньше трафика и нагрузки (540p/700 кбит/с вместо 720p/1,7 Мбит/с; слабые Android — 360p/15 к/с), голос дешевле и устойчивее к потерям; аппаратный H.264 там, где есть. *(2026-10-18: пресеты 540p заменены на 1080p / 720p с гибким потолком — ADR-046.)*
- **+** Человек видит, у кого плохая связь; звонок сам уходит в «только звук», а не рассыпается.
- **−** Подписчик без декодера H.264 не увидит видео (резервного кодека нет). У всех iPhone и практически всех Android декодер H.264 есть; при проблемах — `kCallPreferH264 = false`.
- **−** Пороги (8 с, 4608 МБ, битрейты) выбраны без замеров на телефонах; проверено тестами, на устройствах — нет. Что проверить: звонок Android ↔ iPhone в обе стороны с видео (H.264 + E2EE), слабый Android (2–4 ГБ, MediaTek), ограничение канала (сеть 3G / «Network Link Conditioner»), сеть только с 443 (TURN/TLS).
- **−** `livekit.yaml` вступит в силу только после деплоя сервера (не сделан — с разрешения владельца).

**Дата принятия:** 2026-10-16.

---

## ADR-042 · Резервный путь звонков: только через TURN/TLS на 443 (2026-10-16)

### Context
Друг владельца в России: звонок «соединялся», затем рвался каждые ~10 с (28 переподключений за 3 минуты, ни звука, ни видео); логи LiveKit — его путь шёл напрямую через домашнего провайдера (Билайн) мимо VPN «по правилам»; без VPN оба его звонка закончились `livekit_failure`. TURN через TLS на 443 у сервера уже был (ADR-016: Caddy layer4 → coturn; `turns:turn.<домен>:443` в `TURN_URLS`), но за сутки логов им не воспользовался ни один звонок: WebRTC выбирает путь, который «выглядел рабочим» (UDP напрямую к SFU), и не уходит с него, когда тот подвисает. Владелец: «чтобы звонки работали всегда — резервные пути, маскировка».

### Decision
- **Резервный путь** = медиа только через наш TURN по TLS на 443 (`iceTransportPolicy: relay`, только `turns:` из `/v1/call/turn`). Снаружи — одно TLS-соединение на HTTPS-порт с сертификатом Let's Encrypt; звук и видео внутри остаются со сквозным шифрованием (SFrame), сервер видит то же, что и раньше.
- **Когда** (`client_flutter/lib/features/calls/call_path.dart`, `active_call_provider.dart`):
  1. Настройки → Сеть → «Звонки через резервный путь» — всегда;
  2. обычный путь не подключился (ошибка или 15 с — `kCallConnectTimeout`) — сразу ещё раз через резерв, а не конец звонка;
  3. звонок рвётся (LiveKit «переподключение» дважды за 30 с или одно дольше 8 с) — выход из комнаты и вход заново через резерв на лету; на экране — «Связь рвётся — переключаемся на резервный путь…»;
  4. резерв понадобился за последние 24 ч — следующие звонки сразу с него.
- **Проверено снаружи:** с Mac — TLS 1.3 на `turn.chat.777400777.xyz:443`, TURN Allocate → 401 → с учётными данными → ретранслятор выделен.

### Alternatives / дальше (по убыванию отдачи)
- **Второй резервный узел в другой сети** — TURN/TLS на 443 у хостинга, до которого соединения из России доходят (сервер в России или TURN-сервис вроде Cloudflare): для клиента — ещё один `turns:` в `TURN_URLS`, код не нужен. Решение и затраты владельца.
- **Прокси приложения с маскировкой** (как у Telegram / Signal): весь трафик Sinhron — и сообщения, и сигнализация звонка, и TURN/TLS — через узел, похожий на обычный сайт. Большая работа.
- **Только резерв для всех** — нет: лишний круг через ретранслятор и нагрузка на сервер там, где прямой путь работает.

### Consequences
- **+** Сети, где UDP режут или «замораживают», а TLS на 443 проходит, — звонок поднимается или переезжает сам.
- **−** Не помогает, если блокируют всё направление к адресу сервера (тогда нужен второй узел); канал управления LiveKit (`wss://livekit.<домен>`) идёт тем же адресом.
- **−** Через ретранслятор — чуть больше задержка и трафик сервера.
- **−** На телефонах не проверено: нужен звонок с человеком в такой сети (у друга — включить «Звонки через резервный путь»).

**Дата принятия:** 2026-10-16.

---

## ADR-043 · Ссылка-приглашение: одно нажатие — сервер выставлен, пригласивший в контактах (2026-10-16)

### Context
Владелец: родителям после установки приходится вручную вводить длинный адрес сервера, затем вставлять ключ — неудобно. Нужно: «я жму Поделиться, они жмут ссылку — сервер выставился, я у них в контактах», безопасно и с защитой от подделки.

### Decision
- **Ссылка** `https://<сервер>/join#<base64url JSON>.<base64url подпись>`; JSON — `{v, h: сервер, k: ключ личности, n: имя, t: время, c?: сертификат устройства}`; подпись Ed25519 над `sinhron-invite-v1:` + JSON — ключом личности, а на устройстве без него (ADR-027) — ключом устройства с сертификатом устройства. Всё после `#` остаётся в телефоне (браузер не шлёт фрагмент) — сервер не узнаёт, кто кого пригласил.
- **Проверка в приложении** (Rust `sinhron_sync::invite::parse_link`): подпись; хост ссылки = сервер внутри; иначе — «изменена или подделана», ссылку не открываем. Подпись не доказывает правдивость имени — показываем сервер и начало ключа; сверка — код безопасности.
- **Открытие:** iOS — universal link (`applinks:chat.777400777.xyz`, сервер отдаёт `apple-app-site-association`), Android — App Link (`autoVerify`, сервер отдаёт `assetlinks.json` с отпечатком сертификата подписи), плюс `sinhron://join#…`. Нет приложения — страница `/join` на языке телефона: как установить (кнопки из `SINHRON_IOS_INSTALL_URL` / `SINHRON_ANDROID_INSTALL_URL`) и «Открыть в приложении» (один встроенный скрипт копирует `#…` в `sinhron://`; CSP по хешу).
- **Что видит человек:** аккаунта нет — «{имя} приглашает вас» (сервер, «на связи», ключ) → «Принять» (сервер проверен и сохранён) → имя → 24 слова → сразу «Добавить {имя} в контакты» → чат. Аккаунт на том же сервере — сразу «Добавить в контакты». Своя ссылка / другой сервер — строкой. «Мой QR-код» → «Поделиться» шлёт ссылку (если подписать не вышло — ключ текстом, как раньше).

### Alternatives
- **Ключ и сервер в пути / параметрах** (`/join/<данные>`) — нет: попадали бы в журналы сервера и Caddy.
- **Одноразовый токен на сервере** — нет нужды: ссылка — не секрет и не учётные данные (как QR-контакт), а сервер не должен знать, кто кого пригласил.
- **Общий домен проекта для ссылок** (как signal.me) — позже: сейчас ссылка ведёт на сервер оператора; домен другого оператора требует его сборки приложения (entitlement / манифест).

### Consequences
- **+** Родителям — установить, нажать ссылку, «Принять», имя, 24 слова — и чат с сыном открыт; ни адреса, ни ключа.
- **−** iPhone без App Store: приложение ставится через TestFlight — владелец добавляет их в тестировщики (или публичная ссылка TestFlight → `SINHRON_IOS_INSTALL_URL`).
- **−** Universal link на iPhone и App Link на Android заработают после выкладки сервера (файлы на домене) и сборки с entitlement (TestFlight — нужна возможность Associated Domains у App ID; автоматическая подпись обычно включает её сама). До того — страница `/join` и «Открыть в приложении».
- **−** Проверено тестами и на симуляторе до системного вопроса «Открыть в приложении»; на телефонах — нет.

**Дата принятия:** 2026-10-16.

### Дополнение 2026-11-03 — короткая ссылка (владелец: «вариант 1»)
Длинная ссылка (сотни знаков, у iPad — ещё и сертификат устройства) в WhatsApp выглядела как мусор. Теперь делится **короткая**:
- `https://<сервер>/i/<id>#<ключ>`: `id` — 10 случайных букв/цифр (выбирает приложение), `ключ` — 16 случайных байт (base64url, 22 знака). Приложение делает подписанную длинную ссылку как раньше и шифрует её фрагмент (`<данные>.<подпись>`) этим ключом — AES-128-GCM, случайный nonce впереди, связанные данные `sinhron-short-invite-v1:` + id — и оставляет на сервере (`POST /v1/invites {id, blob_b64}`, без входа — приглашение не привязано к аккаунту; id занят → ещё раз с новым). Открывающий телефон берёт блоб (`GET /v1/invites/<id>`), расшифровывает и дальше проверяет **ту же длинную ссылку** (подпись, хост) — ничего в проверке не меняется.
- **Что видит сервер:** что приглашение создано и когда; кто и когда его открыл (IP, время). **Не видит** — кто приглашает, имя, ключ: ключ после `#`, браузер его не шлёт, блоб открыть нельзя. Id рядом с IP в журнал не пишется.
- **Срок** — год (`expires_at`, удаляет фоновая чистка); дальше — «Ссылка устарела — попросите новую».
- **Запасной путь:** нет сети, старый сервер, id занят дважды — делится длинная ссылка, как раньше; старые длинные ссылки открываются как прежде. Ограничения: создание — 30 в час с одного IP, получение — 120 в час.
- Страница `/i/<id>` — та же, что `/join`; её кнопка ведёт в `sinhron://i/<сервер>/<id>#<ключ>`. iOS (`/i/*` в `apple-app-site-association`) и Android (`pathPrefix="/i/"`, `sinhron://i`) открывают такие ссылки в приложении.
- **Не до нажатия** (`app-surface:3`, 2026-11-04): короткая ссылка на чужой сервер выдала бы ему IP телефона в момент открытия. Мой сервер — сразу; с аккаунтом на другом — строка «другой сервер», без сети; без аккаунта — окно «Вас пригласили на сервер Sinhron / <сервер>» → «Открыть ссылку». В сервере ссылки — только буквы, цифры, `.`, `-`, `:`.
- Отозвать выданную короткую ссылку пока нельзя (живёт год) — как и длинная, она не секрет: даёт только «добавить меня в контакты».

---

## ADR-045 · Видео в звонке как FaceTime: H.265 там, где все могут, без потери сквозного шифрования (2026-10-16)

**Контекст.** Владелец: «самое качественное видео даже на плохом интернете — как FaceTime». FaceTime шлёт H.265 (HEVC): у iPhone с A10 аппаратный кодер, картинка ~на 40 % лучше H.264 при том же трафике, без нагрева. У большинства Android с ~2017 года он тоже аппаратный. Обычный путь LiveKit — «запасной кодек» (вторая копия в H.264 для тех, кто не принимает H.265) — в livekit_client 2.7.0 уходит **без SFrame** (шифратор ставится только на основной поток; ADR-041). AV1 в 2.7.0 не шифруется вовсе (`e2ee_manager.dart` пропускает AV1-дорожки) — исключён.
**Решение.**
- **Сервер** включает `video/h265` в `livekit.yaml` и сообщает список видеокодеков в ответе на токен звонка (`TokenResponse.video_codecs` = `CALL_VIDEO_CODECS`; тест держит их равными и проверяет, что AV1 нет). Старый сервер не сообщает — клиент остаётся на H.264 / VP8.
- **Телефон** спрашивает ОС, что кодирует аппаратно: iPhone — открывается ли аппаратная HEVC-сессия VideoToolbox (на iOS нет программного HEVC-кодера), Android — `MediaCodecList` (`isHardwareAccelerated`). Канал `dev.sinhron/media`.
- **Участники договариваются** (`call_codecs.dart`, `CodecNegotiator`): каждый сообщает, что декодирует (сообщение данных LiveKit, тема `sinhron.codecs`, повтор при каждом входе); промолчавший — старая версия — считается «H.264 / VP8». Отправитель выбирает лучший общий (`pickVideoCodec`): H.265 — если его берёт сервер, телефон кодирует аппаратно и все декодируют; иначе H.264; иначе VP8. Начинает с H.264 / VP8, переходит, когда все высказались (новичку — 3 с), — перевыпуск камеры (~0,5 с без моей картинки); при уходе / приходе — пересчёт.
- **Самозащита:** если у получателя кадры идут, а не декодируются 6 с — он шлёт `codec_bad`, отправитель исключает этот кодек до конца звонка.
- Диагностика звонка показывает видеокодек («codec: opus · video h265»).

**Последствия.**
- **+** Качество FaceTime для iPhone ↔ iPhone и большинства Android, без нагрева; всё зашифровано (SFrame на H.265 — livekit_client ≥ 2.5.3).
- **+** Совместимо со старыми приложениями и сервером: они просто остаются на H.264.
- **−** SFU видит список декодеров участников (сообщение данных) — не секрет, но метаданные (модель возможностей телефона).
- **−** При переходе на H.265 — ~0,5 с без картинки у собеседников. Запасного потока нет (он был бы незашифрован): собеседник, который не принимает H.265, удерживает весь звонок на H.264.
- **−** Работает только после выкладки сервера (`livekit.yaml` + ответ токена). Проверка — на реальных телефонах (iPhone ↔ iPhone, iPhone ↔ Android, старый Android без H.265).
- AV1 — когда livekit_client начнёт его шифровать.

**Дата принятия:** 2026-10-16.

---

## ADR-046 · Видео до 1080p: гибкий «потолок» по телефону, связи и нагреву (2026-10-18)

### Context
ADR-041 ограничил видео 540p / 24 к/с / 700 кбит/с (слабые Android — 360p) ради плохой связи. Владелец: «насколько крутое качество можно, если интернет хороший и телефон мощный? Сделай 1080 и 720, чтобы всё гибко было». Узкое место не железо и не шифрование (аппаратный H.264/H.265, SFrame на 3 Мбит/с — копейки, SFU только пересылает), а связь, трафик и нагрев. 4K и 60 к/с на экране телефона не видны, только трафик и нагрев.

### Decision
- **Классы телефонов** (`call_quality.dart::classifyCallDevice`): `high` — iPhone 11 и новее (`iPhone12,x`+, A13), iPad с `iPad13,x`; Android с ≥ 8 ГБ (`totalMem` ≥ 6900 МБ), ≥ 8 ядер и Android 11+. `standard` — остальные. `low` — слабый Android (как в ADR-041). Модель iPhone — `device_info_plus` `utsname.machine`.
- **Захват и верхний слой:** `high` — 1080p / 30 к/с / 2,5 Мбит/с, слои 540p (0,8 Мбит/с) и 180p; `standard` — 720p / 30 к/с / 1,5 Мбит/с, слои 360p (0,45) и 180p; `low` — 360p / 15 к/с (без изменений).
- **Гибкий потолок верхнего слоя** (`videoCeilingFor`): минимум из трёх — телефон (1080 / 720), связь (отлично → 1080, хорошо или ещё не измерено → 720, плохо / потеряна → 540) и нагрев (`thermalState`: серьёзный → 720, критический → 540, как у FaceTime). Применяется к слою `f` через `RtpSender.setParameters` (`scaleResolutionDownBy`, битрейт, к/с — `topLayerFor`): без пересогласования и без пропадания картинки; dynacast LiveKit меняет только `active` и эти поля не трогает. Вниз — сразу, вверх — после 10 с устойчивой цели (`VideoCeilingController`), раз в 5 с перепроверка (нагрев, новый отправитель после смены кодека или повторного включения камеры).
- **Нагрев:** канал `dev.sinhron/media` → `thermalState`: iOS `ProcessInfo.thermalState` (0–3), Android 10+ `PowerManager.currentThermalStatus` → та же шкала (нет / лёгкий → 0/1, умеренный → 2, сильный и выше → 3), старые Android — 0.
- **Получатель** берёт подходящий слой сам (adaptiveStream + dynacast): на плохой связи — 540p / 360p / 180p, звонок не ломается. Авто-«только звук» (ADR-041) не меняется.
- **Диагностика** («i» в звонке): строка `video ↑ 1920×1080 · 30 fps · ↓ 1280×720` — лучший отправляемый слой и принимаемая картинка из WebRTC-статистики.

### Alternatives
- **Всегда 1080p** — отклонено: трафик (~1–1,5 ГБ/ч на человека), нагрев, плохая связь собеседников в России.
- **4K / 60 к/с** — отклонено: на экране телефона не видно, трафик и нагрев ×3–4.
- **Менять разрешение захвата (перезапуск камеры)** — отклонено: ~0,5 с без картинки при каждом шаге; масштаб слоя меняется на лету.
- **Выключать верхний слой (`active = false`)** — нет: этим полем управляет dynacast, они бы спорили.

### Consequences
- **+** На мощных телефонах и отличной связи — 1080p, как FaceTime; на хорошей — 720p; на плохой и при нагреве — само вниз, без обрывов.
- **−** Больше трафика у отправителя (~3,5 Мбит/с всех слоев в 1080p) и на сервере (звонок вдвоём в 1080p — ~2 ГБ/ч).
- **−** Пороги (8 ГБ / 8 ядер, 10 с, битрейты) выбраны без замеров; Swift/Kotlin части (`thermalState`) собираются только на Маке / в CI; проверка — звонком на двух телефонах (tech-debt 2.39).

**Дата принятия:** 2026-10-18.

## ADR-047 · «Отменить отправку»: текст без связи и медиа во время загрузки (2026-10-18)

### Context
Владелец: «должна быть возможность отменить отправку, пока идёт загрузка или нет интернета». Сообщение с часиками (нет связи или сервер ещё не подтвердил) и фото / видео / файл, пока шифруются и загружаются, отозвать было нельзя — только ждать или удалить уже после отправки.

### Decision
- **Где:** долгое нажатие на своё сообщение со статусом «отправляется» или «не отправлено» → «Отменить отправку» (первый пункт, красный); у пузыря загрузки медиа — × справа (у «не отправлено» × убирает его).
- **Стоп в ядре:** `net_cancel_send(message_id)` (Rust, синхронно) кладёт id в набор отменённых; отправка проверяет его перед загрузкой (`net_send_media`) и перед шифрованием + отправкой (`net_send_encrypted`) — последней точкой, после которой сообщение может попасть на сервер — и падает с `send cancelled`. Набор ограничен 256 id.
- **Текст** (`MessageActions.cancelSend`): убирается из очереди `pending_actions`, отправка в пути останавливается, строка удаляется на этом телефоне. Если статус ещё «отправляется» и в очереди его не было (ушло на сервер, подтверждения нет) — следом «удалить у всех» (как любое изменение, ждёт связи в очереди): если сообщение всё же дошло, у собеседника оно исчезнет. Отменённая отправка не помечается «не отправлено» и не попадает в очередь; запись очереди после flush перечитывается, чтобы отмена (или новое изменение) во время flush не потерялась.
- **Медиа** (`PendingMediaNotifier.cancel`): пузырь исчезает сразу, Rust получает отмену для wire id попытки (или сразу, как только задача его сообщит); упавшая из-за отмены задача не превращается в «не отправлено». Если отправка уже прошла точку невозврата — сообщение отправлено и остаётся.

### Alternatives
- **Прерывать саму загрузку на середине** — нет: `upload_with_progress` (sinhron_sync) не умеет прерываться; лишние байты на сервере (зашифрованный, никому не адресованный объект) безвредны, сообщение всё равно не уходит.
- **Только убирать строку локально** — нет: сообщение «в пути» потом дошло бы до собеседника.

### Consequences
- **+** Сообщение, которое ещё не дошло, можно отозвать; у собеседника — максимум «сообщение удалено», если оно успело дойти.
- **−** Альбомы целиком пока не отменяются (пункт скрыт); загрузка, уже идущая, докачивается до конца впустую.

**Дата принятия:** 2026-10-18.


---

## ADR-052 · Контакты — свой список (не «личные чаты»); «О себе» видно собеседникам (2026-10-18)

### Context
Владелец: «зачем нам сейчас отдельная вкладка с контактами? Если я удаляю чат с кем-то, то и контакт тоже удаляется. Разве такая должна быть логика? В Телеграме, ВКонтакте, Signal это не так. Мою био никто не видит.»
До этого вкладка «Контакты» строилась из принятых личных чатов (`contactEntries(chats, names)`): удалил чат — человек пропал; «Избранное» было только в демо; «О себе» из профиля хранилось на телефоне и никуда не уходило.

### Decision
- **Контакт — отдельная запись на этом устройстве** (хранилище v15, зашифрованная база): `contacts(peer_id, name, favourite, added_ts)`. `name` — как я узнал человека (имя из его QR / ссылки, имя чата) — показывается, пока он сам не пришлёт своё. Миграция делает контактами все уже принятые личные чаты с известным собеседником — никто не пропадает при обновлении.
- **Когда человек становится контактом:** я добавил его сам — QR, ссылка-приглашение, ключ (`_startChatByIdentity`), «Принять» в запросе на переписку (`ChatActions.acceptRequest`), «Добавить в контакты» в «Инфо» чата или в профиле; или старый принятый чат впервые узнаёт, кто в нём (первый `profile` в чате без `peer_id`). Запрос на переписку и участники моих групп — не контакты. Ответ в запросе (неявное принятие) — тоже нет: как в Telegram, переписка ≠ контакт.
- **Удалить чат — контакт остаётся;** «Удалить из контактов» — отдельно (спрашивает, переписка остаётся). Повторный `profile` не возвращает удалённого из контактов (добавление — один раз, когда чат узнал собеседника).
- **Написать контакту без чата** — «Написать» начинает новый зашифрованный чат по его ключу (как QR). Звонок, код безопасности и «Медиа» требуют чата — без него их кнопок нет.
- **Вкладка остаётся и становится полезной** (как в Telegram / ВК; в Signal контакты — в «Новом чате»): поиск по имени и ключу, моя карточка (→ мой QR), «Пригласить друзей» (ссылка ADR-043), «Избранное» (звёздочка — настоящая), «Проверенные», все А–Я с буквами справа; трубка в строке звонит (если есть чат); нажатие — **профиль человека**: фото (во весь экран), имя, ключ, «в сети», «О себе», Написать / Позвонить / Видео, код безопасности, медиа, общие группы, в избранное, удалить из контактов, заблокировать. «Новый чат», «Новая группа» и «Новый звонок» берут людей из контактов (группа — и контакты без чата: ключ известен).
- **«О себе» (bio)** уходит в том же действии `profile`, что имя и фото (`AppMessage.Profile`, поле 3, сквозное шифрование MLS; старые версии поле игнорируют): одна строка, ≤200 символов, невидимые / управляющие символы вырезаются и на отправке, и на приёме (`clean_profile_bio`; длинное обрезается, не ломая имя). Получатель хранит по ключу личности (`peer_bios`), показывает в профиле и «Инфо» чата. Профиль — целиком: без поля «bio» старое у получателя стирается.
- **Доходит до всех (2026-10-19, запись 171):** «уже сказано» — на чат **и состав участников**; вступивший позже получает профиль сразу (Commit → `ensureShared`). «О себе», попавшее на телефон со старой сборкой без этого поля, там терялось и больше не уходило — `People._profileRound` (сейчас 2) заставляет каждый чат услышать профиль ещё раз; поднимать его при каждом новом поле профиля. Проход по всем чатам — после правки профиля и при каждом подключении.
- **Блокировка:** заблокированному профиль не уходит вовсе (`ensureShared` пропускает); в момент блока ему уходит профиль только с именем — у него пропадают и фото, и «О себе» (`People._goQuiet`). Запросы на переписку моего «О себе» не получают.

### Alternatives
- **Убрать вкладку, контакты — только в «Новом чате»** (как Signal): меньше экранов, но владелец просил логику Telegram / ВК, а «Избранное», «Проверенные», приглашение и профиль без чата некуда деть.
- **Контакты на сервере** (синхронно на всех устройствах): сервер узнал бы граф знакомств — против модели угроз. Позже — через синхронизацию между моими устройствами (ADR-025), зашифрованно.
- **«О себе» — только контактам:** профиль сейчас один на чат, и в группах его видят все участники (так же как имя и фото); отдельная настройка видимости — если владелец захочет (open-items).

### Consequences
- **+** Удалённый чат не уносит человека; вкладка не дублирует список чатов; «О себе» наконец видно.
- **+** Миграция и запись идемпотентны (`CREATE IF NOT EXISTS`, `INSERT OR IGNORE`) — номер схемы можно сдвинуть при слиянии с параллельной веткой.
- **−** Контакты — на этом устройстве: на втором моём устройстве список свой (собирается из его чатов и действий). Отметка «проверен» — по чату: у контакта без чата её нет, пока чат не появится.
- **−** «О себе» видят все, с кем я в одном чате (включая группы) — как имя и фото.
## ADR-055 · «Избранное»: чат с самим собой на всех моих устройствах (2026-10-18)

### Context
Владелец: «почему нет избранных сообщений, типа то, что ты сам себе пишешь, то, что синхронизируется между устройствами?». Нужен аналог Saved Messages из Telegram: всегда на месте, туда можно отправить что угодно, «Сохранить» из меню сообщения — одним нажатием; заметки видны на всех моих устройствах. Сервер не должен хранить открытый текст и не должен узнать, что это «заметки». Готовой «группы моих устройств» в коде не было — устройства добавлялись только в уже существующие чаты (синхронизация устройств, ADR-025).

### Decision
- **Это обычная MLS-группа, в которой только мои устройства.** Создаётся при первом использовании (`sync_create_saved_group`: `create_group` + `announce_group` с одним этим устройством — иначе сервер не примет отправку туда); её id — в локальной настройке `saved_chat_id` (зашифрованная база). Строку чата делает приложение (`SavedMessages.ensure`, по одной за раз). Дальше всё как в любом чате: **синхронизация устройств (ADR-025) добавляет мои другие устройства**, и тех, что связаны позже; сообщения моих устройств приходят им как мои.
- **Как новое устройство узнаёт, что это «Избранное».** История для нового устройства (конверт `History`, ADR-025) получила флаг `saved` (поле 4). Для «Избранного» история уходит, даже если заметок ещё нет (пустая, с флагом). Устройство принимает флаг, только если он **от меня** (MLS-отправитель — моя личность) и в группе **нет никого, кроме меня** (`SyncClient::is_own_devices_group`) — по одному составу нельзя: личный чат, из которого собеседник ушёл, тоже «только я». Если на двух устройствах успели сделать каждое своё «Избранное» до встречи, оба выбирают одно (меньший id); второе остаётся обычным чатом. Старые версии приложения отвергают пустую историю и читают непустую как обычную.
- **Welcome в группу, где только я,** — от моего же устройства: не «запрос на переписку».
- **Тихий чат.** Нет квитанций доставки и прочтения, «печатает», «в сети», строк о снимке экрана, моего имени/фото (`profile`) — некому. Реакции, закрепление, правка и удаление уходят (их видят мои другие устройства). Кнопок звонка нет; шапка ведёт сразу в «Медиа и файлы» (поиск по сообщениям работает как везде).
- **В списке** «Избранное» всегда первое во вкладке «Все» (выше закреплённых), с закладкой на синем круге; пока группы нет — заглушка, нажатие создаёт её и открывает чат. Его нельзя заглушить, архивировать или удалить смахиванием; в других папках его нет. «Сохранить» в меню сообщения пересылает копию туда (медиа перешифровываются, как при пересылке, ADR-019); «Переслать» тоже предлагает его первым.

### Consequences
- **+** Сервер хранит только шифротекст; он видит группу, все участники которой — устройства одного человека (членство он знает и для любого чата, ADR-025) — и ничего о содержимом.
- **+** Никакого нового серверного API и схемы базы: группа, синхронизация устройств и история — существующие.
- **−** **Старые заметки на новом устройстве** — только то, что даёт история ADR-025: последние 200 сообщений из базы устройства, которое его добавило (без исчезающих и удалённых). Более старых новое устройство не увидит — MLS не расшифрует прошлое.
- **−** Создание требует связи с сервером (объявить группу); без связи — «Не удалось открыть «Избранное»», ничего не создаётся.
- **−** Удалить «Избранное» из списка нельзя; если строки чата не станет (сброс базы и т. п.), при следующем использовании создаётся новая группа, старая остаётся на сервере пустой.
## ADR-048 · Видеосообщения-«кружки», как в Telegram (2026-10-18)

### Context
Владелец попросил круглые видеосообщения, как в Telegram: та же кнопка, что у голосового, по нажатию переключается в камеру, удержание — запись с фронтальной камеры (можно перевернуть), влево — отмена, вверх — закрепить, до 60 с; у получателя — круг, который сам играет без звука, а по нажатию — со звуком и чуть крупнее. Важно: старые версии приложения не должны ломаться на новом сообщении.

### Decision
- **Не новый тип, а флаг видео.** `MediaBody.round` (protobuf, тег 13) и `"round":true` в `media_json`; `MediaKind` остаётся `Video`. Старое приложение пропускает незнакомый тег и показывает обычное видео (тест `round_video_roundtrips_and_old_apps_see_a_video`); тип строки в базе — `video`, поэтому «Медиа и файлы», пересылка, передача истории новому участнику, ответы и отмена отправки (ADR-047) работают без изменений. `round` разрешён только у видео (иначе envelope отклоняется); у кружка нет подписи.
- **Запись** — плагин `camera` 0.12.0+2 за швом `VideoNoteRecorder`: 480p с фронтальной камеры, ~1 Мбит/с H.264 (аппаратно) + AAC 64 кбит/с, ориентация съёмки фиксируется той, что была в начале; камера переключается без остановки записи (`setDescription`). Разрешения камеры и микрофона — `permission_handler`; отказ → понятная строка над полем ввода.
- **Квадрат** — платформой, аппаратным кодеком: iOS `AVAssetExportSession` с `AVMutableVideoComposition` (центр кадра, 480×480, Medium quality), Android Media3 Transformer (`Presentation` 480×480 с обрезкой, H.264 1 Мбит/с); канал `dev.sinhron/media` → `squareVideo`. ~~Не вышло — уходит исходный клип~~ — **с 2026-10-19 (status 172) так нельзя**, см. «Приватность кружка» ниже.
- **Отправка** — тот же конвейер, что у видео: `prepareVideoNote` (квадрат → кадр-постер → чтение в память → удаление всех файлов открытого текста) → `sendVideo(round: true)` → `net_send_video(round)`: постер в зашифрованную миниатюру + BlurHash, шифрование и загрузка в Rust. Прогресс, «Не отправлено — повторить» и «Отменить отправку» — как у любого медиа; пузырь загрузки пишет «видеосообщение».
- **Кнопка:** нажатие на микрофон переключает голос ⇄ видео (подсказка на 2,5 с; режим запоминается, пока приложение запущено), удержание пишет в текущем режиме. Во время записи — затемнённый чат, живая картинка в круге, кольцо заполняется к 60 с, кнопка «перевернуть»; второй палец (на «перевернуть») не заканчивает удержание. Короче 1 с — не отправляется; на 60 с — отправляется сама.
- **Показ** — `VideoNoteBubble`: круг 200 pt без пузыря, время на нём; на экране (через 350 мс, не при «уменьшить движение») расшифровывается в RAM и играет без звука по кругу через `RamMediaServer` (только loopback), смешиваясь с музыкой пользователя; нажатие — с начала со звуком, круг 248 pt и кольцо прогресса, ещё нажатие — пауза; в конце — снова без звука. Со звуком играет только один кружок, голосовое при этом останавливается.

### Alternatives
- **Новый `MediaKind::VideoNote`** — нет: старые приложения отклоняют незнакомый вид медиа («unknown media kind») — сообщение бы пропало.
- **Отправлять 4:3 без обрезки** — проще, но файл на треть больше и не квадрат; был запасным путём до 2026-10-19 — убран (приватность, ниже).
- **Обрезка в Rust / ffmpeg** — нет: тяжёлая зависимость и программное кодирование вместо аппаратного.

### Consequences
- **+** Кружки работают у всех: у новых — круг, у старых — обычное видео; никакой новой метаинформации для сервера (флаг внутри MLS-шифротекста).
- **+** Минута кружка ≈ 6–8 МБ.
- **−** Пока идёт запись и обрезка, клип лежит открытым текстом во временной папке приложения (как видео с камеры, tech-debt 2.24) — удаляется сразу после чтения в память.
- **−** В списке чатов последнее сообщение подписано «Видео», а не «Видеосообщение» (превью знает только тип строки); вкладка «Фото» в «Медиа и файлах» теперь показывает и видео.
- **−** На Android +~1 МБ к APK (Media3 Transformer).

### Обновление 2026-10-19 (status 172) · Приватность кружка: никогда больше круга
**Что нашёл владелец:** в «Медиа и файлах» / галерее чата кружок открывался обычным прямоугольным видео, «как будто оно даже не обрезано». Это нарушает приватность: записывающий видит только круг и может поймать по краям то, что показывать не хотел. Две причины: галерея рисовала любое видео целиком (16:9-плеер), а при неудачной обрезке уходил весь кадр камеры.

**Решение — с обеих сторон:**
- **Отправитель никогда не отправляет больше круга.** Запасного пути «уходит оригинал» больше нет: `prepareVideoNote` пробует обрезку дважды (`kVideoNoteCropAttempts`), потом бросает `VideoNoteCropFailed` — ничего не отправляется, файл камеры удаляется, над полем ввода «Не получилось обрезать видео в кружок, поэтому оно не отправлено. Запишите ещё раз.» «Квадрат», совпадающий с файлом камеры, тоже отказ.
- **Углы квадрата — чёрные.** Платформа сразу закрашивает всё вне вписанного круга: iOS — `AVVideoCompositionCoreAnimationTool` с чёрным слоем-маской (чётно-нечётная заливка: квадрат минус круг) поверх видео; Android — Media3 `OverlayEffect` с `BitmapOverlay` (чёрный 480×480, круг вырезан `PorterDuff.CLEAR`) после `Presentation`. Так файл содержит ровно то, что записывающий видел в круге превью (превью тоже обрезка центра по кругу), — даже если файл когда-нибудь попадёт наружу.
- **Получатель никогда не показывает больше круга.** Один виджет `VideoNoteCircle` (`lib/features/video_note/video_note_circle.dart`: наибольший круг в коробке, картинка — cover-обрезкой, вне круга ничего не рисуется) — в пузыре, в сетке «Медиа и файлы» (плитка-круг), в ленте миниатюр галереи, на странице галереи (круг ≈ 86 % меньшей стороны экрана, ≤ 520 pt; постер и видео — оба в круге) и в полёте Hero (`_RoundShuttle`). Старые кружки, ушедшие необрезанными, тоже показываются кругом — по флагу `round`, а не по размеру файла.
- **«Поделиться» и «Сохранить в Фото» у кружка нет** (кнопки скрыты, `shareGalleryItem` / `saveGalleryItem` отказывают): в старом файле может быть больше круга, а отличить новый (с чёрными углами) от старого нечем. «Переслать» остаётся — пересланный кружок остаётся кружком (`round` сохраняется) и у получателя тоже рисуется кругом.

**Альтернативы:** убрать кружки из галереи совсем (как Telegram — во «Голосовые») — проще, но владелец ищет их в «Медиа»; экспортировать при сохранении заново обрезанный круг — можно позже, если попросят (платформенный экспорт уже есть). Прозрачные углы вместо чёрных — H.264 не хранит прозрачность.

**Последствия:** **+** ни при каком сбое кадр камеры не уходит; **+** файл = круг. **−** Если на каком-то телефоне платформенная обрезка не работает вовсе, кружки с него не отправить (раньше уходил оригинал) — видно по ошибке; проверить на Galaxy A40 и старом iPhone (tech-debt 2.40). **−** Чёрный край круга после сжатия H.264 может быть чуть «ступенчатым» — у получателя его закрывает маска круга.
## ADR-049 · Стикеры и эмодзи: форматы, встроенные наборы, свои наборы и обмен ими (2026-10-18)

### Context
Владелец: «сделай, чтобы были стикеры и эмодзи, прям такие хорошие, и возможность добавлять паки стикеры/эмодзи». Стикеров не было вовсе; панель эмодзи — без поиска и оттенков кожи. Сервер не должен видеть ни стикеров, ни наборов; старые версии приложения должны показывать что-то понятное.

### Decision
- **Форматы** (по первым байтам, не по имени файла — `sticker::format_of` / `stickerFormatOfBytes`): `png`, `webp` — неподвижные (анимированный WebP играет сам); `tgs` — Lottie JSON в gzip (открытый формат Telegram; простой Lottie `.json` при импорте сжимается в `.tgs`); `webm` — VP9-видео. Пределы: стикер ≤ 1 МБ, превью ≤ 64 КБ PNG, набор ≤ 200 стикеров и ≤ 64 МБ (у Telegram 64 / 256 / 512 КБ — наши свободнее, чтобы любой файл человека поместился).
- **Отрисовка:** пакет `lottie` 3.6.1 (MIT, xvrh, чистый Dart, без нативного кода; самая новая версия для Flutter 3.41 — 3.4–3.5 требуют 3.44). Разбор анимации — один раз на стикер (`LottieCompositions`, 96 последних), кадры с частотой самой анимации; вне экрана (прокрутка) и при «Уменьшить движение» — пауза на первом кадре. В сетке панели — неподвижные кадры (десятки анимаций разом съедают батарею), долгое нажатие — стикер крупно и в движении. `webm`: на Android — беззвучное видео по кругу через loopback-сервер из памяти (как видеосообщения); на iPhone AVPlayer не умеет WebM — показывается превью или эмодзи стикера (tech-debt 2.43).
- **Сообщение-стикер — новый вид, понятный старым:** это `MediaBody` вида **Photo** с новым полем `sticker` (тег **14**; тег 13 — «кружок», ADR-048): эмодзи, формат, ссылка на анимацию (`animation`) и на набор (`PackRef`). Для неподвижного стикера `file` — сама картинка; для анимированного — неподвижный кадр PNG 512 px, а движущийся файл — `animation`. Миниатюра ≤ 32 КБ PNG есть всегда. Старое приложение не знает поля и показывает **фото** стикера; новое хранит строку вида `sticker`. В локальном JSON и в пакетах истории (ADR-025) вид остаётся `photo` (старое приложение отвергло бы весь пакет с незнакомым видом), новое восстанавливает `sticker` по полю (`stored_kind`). Битая информация о стикере отбрасывается, сообщение остаётся фото; битый набор — отбрасывается, стикер остаётся.
- **Шифрование:** каждый стикер при каждой отправке шифруется заново свежими ключами (как пересылка, ADR-019) — сервер не может понять, что в двух чатах один и тот же стикер.
- **Встроенные наборы** (ассеты приложения, у всех одинаковые, передаются по id `sinhron.…` без файла): «Эмоции» (45) и «Жесты и праздник» (27) — **Animated Noto Emoji** (Google, **CC BY 4.0**, страница googlefonts.github.io/noto-emoji-files; каждый Lottie скачан по одному и сжат gzip, сами анимации не менялись); «Зверята и вещи» (36) — **Fluent Emoji 3D** (Microsoft, **MIT**; PNG 256 px перекодированы в WebP). Авторство и лицензия — в листе набора и в `assets/stickers/NOTICE.md` (полный текст MIT). Скрипт сборки — `client_flutter/tool/sticker_packs.py`. Анимации Noto также оживляют одиночный эмодзи в сообщении: играет один раз, нажатие — ещё раз (как у Telegram).
- **Свои наборы:** «+» в панели стикеров → «Из файлов» (.tgs / .json / .webp / .png / .webm / .zip с ними; превью делается на телефоне, эмодзи берётся из имени файла) или «Вставить код набора». Набор — один файл `PackFile` (protobuf, «SNSP» v1), хранится **зашифрованным** AES-256-GCM как медиа-объект в `<db>.stickers/<sha256>` (`sinhron_storage::stickers`), ключ и список — в зашифрованной БД (настройка `sticker_packs`). Отдельно от копий медиа: «Очистить копии» и сборщик мусора их не трогают; стирание БД удаляет и их.
- **Обмен:** первый отправленный стикер из своего набора выгружает набор на сервер зашифрованным (один раз; повторно — если прошло 60 дней, сервер чистит объекты через 90) и кладёт `PackRef` с ключом в сообщение → у получателя нажатие на стикер → лист набора → «Добавить N стикеров». «Поделиться набором» / «Скопировать код» — код `sinhron-stickers:<base64url(PackRef)>`, который вставляют в панели; код находится и внутри текста.
- **Telegram:** приложение **не скачивает и не перебирает** наборы Telegram (права авторов и условия Telegram). _(Пересмотрено ADR-062: набор по ссылке, которую человек дал сам, берёт сервер через Bot API.)_ Импортировать файл, который у человека уже есть (например, свой экспорт `.tgs`), — его право; ответственность за права на чужие стикеры — на том, кто импортирует и делится.
- **Эмодзи:** поиск по названиям на английском и русском (Unicode CLDR, Unicode License v3; `emoji_names.dart`, генератор `tool/emoji_names.py`) — при вводе панель сжимается до поля и строки результатов над клавиатурой; оттенки кожи — долгое нажатие на руку / человека (121 эмодзи с `Emoji_Modifier_Base`), выбранный оттенок запоминается для этого эмодзи (`emoji_tones`); внизу — «Эмодзи | Стикеры». В панели стикеров — недавние (20), вкладки наборов, ряд эмодзи-фильтров (поиск по эмодзи без клавиатуры).

### Alternatives
- **Новый `MediaKind::Sticker`** — нет: старое приложение отбрасывает незнакомый вид как «invalid», стикер пропал бы бесследно.
- **Один и тот же зашифрованный объект для стикера во всех чатах** (как Telegram) — нет: экономит трафик, но сервер видел бы, что в разных чатах шлют одно и то же.
- **Rive / dotLottie / свой рендерер** — нет: `.tgs` — это Lottie; `lottie` покрывает его без нативного кода. **VP9-декодер для iPhone** — отложено (tech-debt 2.43): нужен libvpx в сборке.
- **Пользовательские анимированные эмодзи внутри текста** (как Telegram Premium) — пока нет: нужен свой формат разметки текста; сделано ближайшее — оживший одиночный эмодзи (tech-debt 2.43).

### Consequences
- **+** Стикеры — с первого запуска (108 бесплатных, с правом распространения), свои наборы из файлов, обмен по нажатию или коду; сервер видит только шифр, размеры по корзинам Padmé и факт скачивания объекта набора.
- **+** Старые приложения видят стикер как фото, а не теряют его.
- **−** Приложение тяжелее на ~1,2 МБ (ассеты); каждый отправленный стикер — новая загрузка (десятки КБ).
- **−** `.webm` на iPhone не двигается; набор, которым поделились, живёт на сервере, пока его кто-то открывает (90 дней с последнего раза).
- **−** Сервер может связать скачивания одного объекта набора разными людьми (кто открыл набор из чужого стикера или по коду) — threat-model.
## ADR-056 · Имя и текст в push без Apple и сервера: запечатанное превью + расширение уведомлений; имя звонящего по HMAC-метке (2026-10-18)

### Context
Владелец: «почему в push нет ни имени, ни текста — Apple же не видит переписку», «push от тех, кого я заблокировал, приходят», «при входящем звонке написано Sinhron, а не кто звонит». Сервер видит только шифр (ADR-023), поэтому мог сказать лишь «Новое сообщение» (ADR-038); VoIP-push нарочно без чата (tech-debt 2.7, ADR-039). Нужно: показать «<имя>: <текст>» на телефоне так, чтобы ни сервер, ни Apple не узнали ни имени, ни текста, ни чата; не показывать push заблокированных, не сообщая серверу, кто кого заблокировал; назвать звонящего сразу.

### Decision
- **Превью от отправителя.** К каждой «срочной» запечатанной доставке (ADR-038) отправитель прикладывает превью: вид (текст / фото / голос / видео / файл), первые 320 байт текста, чат (group id), время, своя подпись. Запечатано HPKE на **тот же ключ доставки** получателя, что и конверт (X25519 / HKDF-SHA256 / **ChaCha20-Poly1305** — AES-128-GCM нет в CryptoKit; info `sinhron-push-preview-v1`, aad = key id), дополнено нулями до 640 байт — все превью одного размера (689 байт с заголовком). Подпись Ed25519 ключом устройства над `sinhron-push-preview-v1:` ‖ key id получателя ‖ тело; в теле — учётные данные (ключ личности или сертификат устройства, ADR-025/027): кто угодно, умеющий доставить мне конверт, не напишет на моём экране «Мама: перезвони», и превью нельзя перезапечатать другому участнику. Подпись говорит только, **кто** писал, не что он в этом чате (`sealed-push:2`, исправлено 2026-11-04): личный чат назван на экране только для превью от его собеседника (`p` в контексте расширения), группа показывает текст только от человека с известным именем; иначе — «Новое сообщение». Текст исчезающего сообщения в превью не кладётся (`storage-devices:17`). Код: `sinhron_sync::push_preview` (`seal` / `open`), `SyncClient::push_preview_for`, `sealed_plan` в `api/simple.rs` (только для срочных доставок, не для своей копии).
- **Сервер** не читает и не хранит превью: `SealedDelivery.push_preview` (proto, поле 5) / `push_preview_b64` в `POST /v1/sealed` → в push (`p`, base64) вместе с `mutable-content: 1`; больше 1024 байт — отбрасывается, push уходит как раньше. С превью нет `apns-collapse-id` — каждое сообщение отдельным уведомлением (группирует телефон, по чату). Обычный `Submit` (не запечатанный) — без превью.
- **Расширение уведомлений (Notification Service Extension)** — отдельная цель `ios/NotificationService`, чистый Swift + CryptoKit (`HPKE.Recipient`, iOS 17+; на iOS 15–16 — «Новое сообщение»), **без Rust и без базы**: мало памяти (лимит ~24 МБ), нечего делить с приложением, которое держит базу открытой. Вскрывает превью, проверяет подпись (и сертификат устройства), берёт имя чата и отправителя из того, что оставило приложение, и пишет заголовок = чат, текст = «<отправитель>: <текст>» в группе или «<текст>» в личном (вместо пустого текста — «Фото», «Голосовое сообщение»…; `@[ключ]` → «@Имя»). «Уведомления показывают»: «Имя и текст» / «Только имя» («Новое сообщение» под именем) / «Ничего» (только «Новое сообщение»). Чат без звука — уведомление тихое. Превью старше суток (или из будущего) — «Новое сообщение» (сервер не переиграет старое). Нажатие открывает этот чат (`chatId` в userInfo → `PushBridge` → Dart).
- **Общее хранилище — Keychain**, а не App Group: группа доступа `$(AppIdentifierPrefix)com.sinhron.shared` в обеих целях (`keychain-access-groups`; у приложения первой стоит своя группа, поэтому ключ устройства ADR-021 и прочее, что пишется без группы, остаётся только приложению), доступ «после первой разблокировки, только это устройство». Не нужна регистрация App Group в аккаунте Apple. Три записи (`ios/Shared/PushShared.swift`): `push-keys` — закрытые ключи доставки на недели [−2, +2] (FFI `push_preview_keys`, Dart передаёт их сразу в Keychain при каждом подключении, если поменялись); `push-context` — JSON от Dart (`notificationContextProvider`, `lib/core/notification_context.dart`): режим, слова на языке приложения, ≤ 500 чатов (имя, группа, без звука, личный с заблокированным), имена людей, заблокированные ключи — **без текста сообщений**; `call-hint-key` — 32 случайных байта. При удалении аккаунта (`eraseAndStartOver`) всё стирается.
- **Заблокированные:** расширение видит подписанного отправителя и сверяется со списком. Совсем убрать уведомление iOS разрешает только с правом `com.apple.developer.usernotifications.filtering` — его выдаёт Apple по заявке. Пока его нет (`SinhronCanFilterNotifications` = false в Info.plist расширения) — «Новое сообщение» без имени, без звука, без экрана (`passive`), без изменения бейджа, в отдельной ветке; приложение при следующем запуске убирает такие из списка уведомлений. С правом — `UNNotificationContent()` и уведомления нет вовсе. Сервер о блокировках не знает.
- **Имя звонящего:** приложение отдаёт свой `call-hint-key` вместе с токеном PushKit (`PUT /v1/push-token`, `call_hint_key_hex`, под подписью; `apns_tokens.call_hint_key`, только VoIP). В VoIP-push сервер кладёт `h` = HMAC-SHA256(ключ, `sinhron-call-hint-v1` ‖ call id ‖ group id)[..16] — **новое значение на каждый звонок**. `CallKitBridge.reportFromPush` перебирает чаты из `push-context` (`CallHint.lookup`), находит совпадение и сразу показывает имя чата («Sinhron», если не нашёл или «Уведомления показывают: ничего»); личный чат с заблокированным — звонок показывается и сразу завершается (iOS требует показать каждый VoIP-push). *(2026-11-04, ADR-090: подсказка только находит чат; имя — лишь при подписи звонящего `s` в том же push, иначе «Sinhron» — ключ подсказки лежит на сервере.)*

### Alternatives
- **Rust-ядро в расширении** (MLS-расшифровка самого сообщения из общей базы) — отклонено: ~24 МБ памяти мало для OpenMLS + SQLCipher; расшифровка в расширении двигает состояние MLS, а приложение держит те же базы открытыми (гонка, порча); пришлось бы переносить базы и ключи в общий контейнер.
- **Сервер ходит за сообщением сам / расширение качает с сервера** — сеть и MLS в расширении, те же проблемы.
- **Отдельный ключ превью, разосланный внутри MLS** (как ключ доступа ADR-026) — отклонено: ключ доставки у отправителя уже есть; HPKE с другим info и другим AEAD на тот же ключ — штатное разделение контекстов. Цена — закрытые ключи доставки лежат ещё и в Keychain (доступ только у нашего расширения).
- **Подсказка звонка = HMAC(group id) без call id** — отклонено: одно значение на чат позволило бы Apple связывать звонки одного чата.
- **Блок-лист на сервере** — отклонено: сервер узнал бы, кто кого блокирует.
- **App Group** — не нужен: Keychain шифруется iOS и не требует отдельной возможности в аккаунте Apple.

### Consequences
- **+** На экране блокировки — «Мама: привет», как в Telegram; сервер и Apple видят те же непрозрачные байты одного размера.
- **+** Входящий звонок при закрытом приложении сразу с именем чата; звонок заблокированного не звонит.
- **−** Сервер узнаёт, у какой доставки есть превью (у срочных — всегда, если у отправителя новое приложение); Apple видит, что push «изменяемый», и больше не схлопывает уведомления — число push им видно и раньше было, теперь видно и на экране.
- **−** Закрытые ключи доставки (недели −2…+2) — в Keychain, общем с расширением: кто вскроет Keychain телефона, откроет запечатанные конверты этих недель (то же, что и сейчас с ключом устройства в Keychain — но отдельной копией).
- **−** Превью есть только у запечатанных доставок; первые сообщения нового собеседника, пока ключи не разошлись, и отправки старых версий — «Новое сообщение».
- **−** iOS 15–16 — без текста (нет HPKE в CryptoKit).
- **−** Push заблокированного без права фильтрации всё же появляется (тихо, без имени) до следующего запуска приложения; право — заявка в Apple (`docs/open-items.md`).
- **−** Не проверено на телефоне: живой push, память расширения, CallKit с именем — после выкладки сервера и сборки. Swift проверен на Mac тестом против вектора из Rust (`ios/SharedTests/main.swift`).

**Дата принятия:** 2026-10-18.

- **Два «Избранных» (2026-10-26, status 205).** Если оба устройства успели создать своё «Избранное» до встречи, `adopt_saved_chat` выбирает одно (меньший id), а второе раньше оставалось обычным чатом «Saved Messages» — владелец увидел две строки. Теперь отвергнутое запоминается (настройка `saved_chat_former`), и после каждой синхронизации устройств `SavedMessages.tidy` переносит его заметки в выбранное и убирает строку; так же складываются уже существующие дубликаты — чат с названием «Избранное»/«Saved Messages», где в группе только я. Сообщение, пришедшее потом в прежнюю группу, попадает в «Избранное» (`formerSavedRedirect` в обработке push), а не теряется.
- **Два личных чата с одним человеком (2026-11-03).** У одного человека два чата с одним собеседником: «Написать» (контакт, QR, ссылка) искало чат по `chats.peer_id`, а он появлялся только с `profile` собеседника — чат, пришедший приглашением или без ответа, «не находился», и создавалась вторая группа; удалённый чат возвращался (record 211) рядом с новым. Теперь строка знает собеседника сразу (`createMlsChat`, `_createChatRow` при участниках {я, X}; старые — `People.repairSelfPeers` по участникам MLS), `_startChatByIdentity` ищет в хранилище (`PersonalChats.find`, и по участникам). Уже возникшие дубликаты складываются так же, как второе «Избранное»: `PersonalChats.tidy` после синхронизации устройств и при возврате удалённого чата оставляет **меньший id группы** (одинаково на всех устройствах обоих; *с записи 231 (critic:2)* — принятый чат всегда раньше запроса, и складывание не снимает пометку «запрос»), переносит сообщения (`storage_chat_merge_into`), запоминает `из → в` (настройка `personal_chat_former`), и push в сложенную группу попадает в оставленный чат (`formerPersonalRedirect`); оставленный чат удалён — сложенный возвращается сам. Из сложенной MLS-группы не выходим (другие устройства могут ещё писать туда). Ждёт, пока это устройство не во всех группах или чат ещё «Новый чат» (группа из двоих выглядит личной, пока не пришло её имя). Заблокированных, группы и «Избранное» не трогает.
---

## ADR-063 · Звонки: токен пока звонит, звонящий в комнате заранее с немым микрофоном; одно окно входящего на платформу; строка звонка над всеми экранами (2026-10-18)

### Context
Владелец: «звонок принят, а слышим друг друга только через 1–3 секунды»; «из звонка не перейти в чат — приходится сбрасывать»; «приложение открыто и мне звонят — сразу системная плашка и экран приложения, дубль». По коду всё медийное начиналось **после** ответа и шло цепочкой: ответ серверу → токен LiveKit + TURN → настройки камеры → вход в комнату → ключи SFrame → микрофон → публикация → подписка у собеседника; звонящий начинал ту же цепочку только получив «ответили». Входящий звонок показывали и CallKit / уведомление Android, и своё окно приложения.

### Decision
- **Пока звонит — подготовка у обоих:** `LiveKitCallEngine.prepare` (токен, TURN, настройки телефона — кэш на запуск, DNS сервера LiveKit). Токен выдаётся на группу участнику (`/v1/call/token`), а не на ответ — сервер не меняется. Старше 10 минут — берётся заново (переход на резервный путь посреди долгого звонка).
- **Звонящий входит в комнату, пока звонит**, с опубликованным, но **выключенным до публикации** микрофоном (`LocalAudioTrack.mute(stopOnMute: false)` → `AddTrackRequest.muted`): кадров голоса нет, пока собеседник не ответил. Нажатый за это время «Выкл. звук» только запоминается. На `CallAccept` — `LiveKitSession.goLive`: трек включается, камера видеозвонка стартует. Вход не удался — повтор при ответе; комната упала, пока звонит, — тоже.
- **Отвечающий входит сразу по нажатию**, параллельно с отправкой ответа серверу; ответ не дошёл — выход из комнаты, звонок снова звонит. Микрофон создаётся параллельно со входом; согласование кодеков (ADR-045) — после входа, в фоне. Вход, закончившийся после конца звонка, сразу выходит.
- **«Соединяем…»** до звука собеседника (`ActiveCallState.audioAt`: трек его микрофона получен и открыт; группа — вход в комнату; молчащий собеседник — через 3 с); таймер считает от звука. `CallTimeline` отмечает шаги от ответа (`prep`/`accept`/`room`/`mic`/`sound`) → строка «setup:» в диагностике, `[call-timing]` в логе.
- **Одно окно входящего:** канал `dev.sinhron/callkit` — `reportIncoming` возвращает, показывает ли звонок система. iPhone — всегда CallKit (в открытом приложении — его плашка), своего окна нет (`false` только на Симуляторе и при ошибке CallKit); Android — своё окно, пока приложение на экране (push-уведомление о звонке снимается), иначе полноэкранное уведомление; вышли на экран — `onShowIncoming` (окно приложения), ушли в фон — снова уведомление. Ответили в системном UI — приложение само открывает экран звонка (`callScreenToOpen`).
- **Звук звонка на iPhone (без звука с маминого iPhone):** пока CallKit держит звонок, WebRTC не запускает звук сам (`RTCAudioSession.useManualAudio`); `provider(_:didActivate:)` передаёт ему сессию CallKit (`audioSessionDidActivate`, `isAudioEnabled = true`), `didDeactivate` — обратно; через 2 с после ответа / начала без активации — звук включается всё равно. Выбор сессии LiveKit (`onConfigureNativeAudio`) во время звонка — всегда play-and-record (по умолчанию было `playback` без микрофона, пока опубликован только чужой трек при «динамике»); выбор динамика звонка — с начала входа. Пока идёт звонок, ничто другое в приложении не трогает аудиосессию (звуки приложения молчат, голосовые играют в сессии звонка).
- **Камера звонка не останавливается при сворачивании:** внутри приложения она принадлежит звонку (не экрану); Android — служба звонка получает тип «камера», как только камера включена (видеозвонок или включили посреди звонка), и держит его до конца; iPhone — на каждой сессии камеры WebRTC включается многозадачный доступ (`isMultitaskingCameraAccessEnabled`), который iOS даёт только приложениям с правом Apple `multitasking-camera-access` (заявка — open-items); без него камера в фоне на паузе.
- **Строка звонка над всеми экранами** (`CallBarHost` вокруг навигатора): пока идёт звонок и экран звонка закрыт («⌄» или звонок пришёл в CallKit, когда я в другом месте приложения). Экраны сдвигаются под неё. Видеозвонок — окошко камеры собеседника поверх приложения, перетаскивается в угол.

### Alternatives
- **Отвечающий входит в комнату, пока звонит** (без публикации) — отклонено: звонящий видел бы, что телефон собеседника в сети и звонит (ещё до ответа), в группе все звонящие телефоны висели бы участниками комнаты (`/v1/call/live` считал бы звонок живым), каждое входящее — соединение с LiveKit, даже отклонённое.
- **Звонящий публикует микрофон только при ответе** (без раннего трека) — отклонено: публикация + подписка у собеседника = ещё 300+ мс тишины после ответа.
- **iPhone: своё окно вместо CallKit в открытом приложении** — отклонено: VoIP-push обязан показать CallKit, иначе iOS закрывает приложение; без CallKit у звонка нет аудиосессии и системного «зелёного» звонка.
- **Системный PiP для видео** (AVPictureInPictureController / Android PiP) — пока нет: окошко внутри приложения дешевле и одинаково на обеих платформах (tech-debt 2.51).

### Consequences
- **+** По оценке шагов: отвечающий слышит звонящего через ~0,6–0,7 с вместо ~1,4 с, звонящий его — через ~0,9 с вместо ~1,4 с (медленная связь: ~1,5 с вместо 2,5–3 с). Не измерено на телефоне — числа даст строка «setup:».
- **+** Один звонящий экран на платформу; из звонка можно уйти в чат и вернуться.
- **−** Звонящий держит микрофон (выключенный трек) и соединение с LiveKit всё время, пока звонит: индикатор микрофона iOS / Android горит с начала вызова, как в Telegram; кадров голоса нет.
- **−** Сервер LiveKit видит звонящего в комнате до ответа (раньше — с ответа); сервер Sinhron и так знал о звонке.
- **−** Уровень голоса для столбиков — отчёты сервера LiveKit о говорящих (несколько раз в секунду): плавность — рисованная, не настоящий спектр.

- **Мой звонок на двух моих устройствах (2026-10-26, status 208).** Было: сервер вёл звонок «по человеку» и любое сообщение о звонке не слал тому, кто ответил, — значит и его другим устройствам: ответил на iPhone — iPad звонил ещё до 45 с и писал «пропущенный»; заблокированный iPhone не получал PushKit, пока на iPad открыт Sinhron (push только тем, у кого нет ни одного соединения). Теперь сервер знает устройство соединения: ответил (отклонил) на одном — остальным соединениям этого человека `CallEnd{reason: "answered_elsewhere" | "declined_elsewhere"}` (`stop_ringing_elsewhere`); устройство, разбуженное push и подключившееся позже, получает такой же `CallEnd` при входе (`CallSessionRegistry::answered_elsewhere`, кроме самого ответившего — он мог просто переподключиться). Звонок человеку, у которого Sinhron открыт где-то, будит VoIP-push'ем его **не подключённые** устройства (`call_targets_for_connected`). Приложение: «ответили на другом устройстве» — звонок исчезает без записи в историю и без «пропущенного» (историю ведёт ответившее устройство), «отклонили на другом» — «отклонённый»; CallKit закрывает звонок как `.answeredElsewhere` / `.declinedElsewhere` (`endedElsewhere`); устройство, которое само в разговоре, на эти причины не реагирует. Старые приложения на такой `CallEnd` просто перестают звонить (и пишут «пропущенный»).
---

## ADR-060 · «Поделиться» в Sinhron из любого приложения: Android — меню «Поделиться», iPhone — расширение + App Group; отправляет само приложение (2026-10-18)

### Context
Владелец: «чтобы из любого приложения можно было поделиться в Sinhron — фото, видео, файлы, ссылки, текст — как в Telegram / WhatsApp», на Android и iPhone, и когда приложение закрыто или заблокировано.

### Decision
- **Android:** отдельная `ShareActivity` (exported, прозрачная, `excludeFromRecents`, `noHistory`) с фильтром `SEND` / `SEND_MULTIPLE` для `image/*`, `video/*`, `text/plain`, `*/*`. Сама ничего не показывает: передаёт адреса (`content://`) и текст в `MainActivity` (действие `com.sinhron.sinhron.SHARE_IN`, `NEW_TASK | SINGLE_TOP`, право чтения едет в `ClipData`) и закрывается — иначе общий движок «Постоянного соединения» получил бы второй экран в задаче чужого приложения. `ShareBridge` (`Share.kt`) копирует каждый элемент в кэш приложения (`cache/share/<id>/`) не на главном потоке; HEIC / WebP / BMP → JPEG (≤2048 px, `ImageDecoder`), GIF остаётся файлом. **Не берёт** `file://` и адреса собственных провайдеров Sinhron (иначе чужое приложение могло бы «поделиться» нашими же файлами — базой, ключами). Канал `dev.sinhron/share`: `takeInitial`, `finished(id)` (удаляет копии), из натива — `share(map)`; копии старше суток стираются при подключении движка.
- **iPhone:** цель `ios/ShareExtension` (`com.sinhron.sinhron.ShareExtension`, в «Поделиться» — «Sinhron»): чистый Swift, **без Rust, базы и сети** (лимит памяти расширения ~120 МБ). Копирует присланное в **App Group** `group.com.sinhron.sinhron` (`Share/<id>/` + `share.json`): видео и файлы — как есть (копирование файла, без буферов), картинки кроме JPEG / PNG / GIF — в JPEG ≤2048 px через ImageIO (поворот применён, метаданных и GPS нет); ссылки и текст — текстом. До 20 элементов. Файлы — `FileProtectionType.complete`, папка вне резервных копий. Затем открывает `sinhron://share?id=<id>` (у расширения «Поделиться» нет `openURL` — вызов через `UIApplication` по цепочке ответчиков); не открылось — «Сохранено. Откройте Sinhron и выберите чат.» `Runner/ShareBridge.swift`: ссылка из `SceneDelegate` → Dart; `takeInitial` — самая новая непереданная за последний час (на случай, если открыть не вышло); `finished` удаляет папку; старше суток — стираются.
- **Почему App Group, а не Keychain** (как у расширения уведомлений, ADR-056): видео и файлы до сотен МБ в Keychain не положить. Группа добавлена в entitlements обеих целей; автоматическая подпись регистрирует её в аккаунте Apple при сборке.
- **В приложении:** `IncomingShareListener` в корне (как ссылки-приглашения) → `handleIncomingShare` (`app/navigation.dart`): нет аккаунта → строка «Сначала войдите в Sinhron…», копии удаляются; иначе поверх открытого экрана — **«Отправить в…»** (`features/share_into/share_target_screen.dart`): что пришло («3 фото», «Видео», имя файла), поиск чатов, «Избранное» первым, потом чаты в порядке списка (архив не показан, как в «Переслать»), можно отметить несколько; поле подписи (для ссылки / текста — сам текст, его можно поправить); кнопка «Выберите чат» → «Отправить» → «Отправить в 3 чата». Отправка — **обычные пути чата** (`share_send.dart` → `sendPhoto` / `sendVideo` / `sendDocument` / текст): несколько фото — один альбом, подпись на первом элементе, видео сжимается как из галереи, файлы > 95 МБ отказ до отправки; «Отправка…» / «Не отправлено — нажмите, чтобы повторить» — в самом чате. Ждёт соединения до 15 с (открыто из меню — связь может подниматься). Один чат → он открывается; несколько → «Отправлено». Ошибка (нет связи) — строка на экране, «Отправить» ещё раз пропускает уже отправленные чаты. Отмена, «назад» или отправка — копии удаляются.
- **Блокировка приложения** закрывает и этот экран, как всё остальное (`AppLockGate` над навигатором): ничего не уходит, пока человек не разблокировал и не выбрал чат.

### Alternatives
- **Отправка из самого расширения** (как Telegram) — отклонено: Rust-ядро, MLS и база в расширении — память, общая база с приложением, второй экземпляр клиента.
- **Плагин `receive_sharing_intent`** — отклонено: своя цель-расширение из pod, лишняя зависимость; свои мосты (как ссылки) проще и понятнее.
- **`ShareActivity` сама копирует и показывает выбор** — отклонено: два Flutter-экрана на одном движке; копирование в `MainActivity` держит право чтения, пока жива задача приложения.
- **Direct Share** (недавние чаты прямо в меню Android) — пока нет; отдельной задачей.

### Consequences
- **+** «Поделиться → Sinhron» из Фото, Файлов, Safari / Chrome, любой программы; несколько чатов сразу; подпись.
- **+** Расширение iPhone не держит ничего секретного и не трогает базу; всё шифрование — в приложении, как обычно.
- **−** Пока человек выбирает чат, присланное лежит открытым файлом в App Group (iPhone, защищено ключом экрана) или в кэше приложения (Android); удаляется после отправки / отмены, забытое — через сутки.
- **−** iPhone: открытие приложения из расширения — не официальный путь Apple; если перестанет работать, человек увидит «Откройте Sinhron» и выберет чат там (присланное подождёт час).
- **−** Не проверено на телефонах: меню «Поделиться» на Android и iPhone, большое видео, холодный старт с блокировкой — после сборки.

---

## ADR-059 · Секретные слова без мучений: «Сохранить в Пароли» одним нажатием, «Позже» без блокировки, лист восстановления, проверка 2 слов (2026-10-18)

### Context
Владелец: «что можно сделать, чтобы людям не надоедало при регистрации вспоминать кодовые слова? Большинство просто скриншот делают, переключаются, вводят и потом удаляют». Шаг 3 регистрации был стеной: 24 слова, две галочки («записал на бумагу», «понимаю, что без них никто не восстановит») и тест из трёх слов — без этого аккаунт не создавался. Люди делали снимок экрана (он уходит в «Фото» и в облако — хуже бумаги), проходили тест и стирали снимок — то есть в итоге слов не оставалось нигде.

Ограничения: слова — это аккаунт (ADR-021: из них выводятся все ключи; ADR-027: ключ личности только на первом устройстве); сервер не должен их видеть ни в каком виде; приложение для самостоятельного размещения — у каждого сервера свой домен.

### Decision
- **Шаг 3 «Сохраните доступ к аккаунту»** (`lib/features/onboarding/save_access_screen.dart`) вместо стены слов. Три пути, аккаунт создаётся при любом из них (как и раньше — в конце шага 3):
  1. **«Сохранить в Пароли»** (iOS) / **«Сохранить в менеджер паролей»** (Android) — главная кнопка. Системное окно сохранения, одно нажатие; слова человек не видит и не переписывает. Логин записи — «имя · первые 8 знаков отпечатка», пароль — 24 слова.
  2. **«Записать слова»** — прежний экран слов (размыт до нажатия, «Скопировать», «Лист восстановления»), без галочек; «Я записал(а)» → проверка **2 слов** (было 3) с выбором из четырёх.
  3. **«Позже»** — сразу в чаты. Слова остаются **только на этом телефоне** до сохранения.
- **Где слова ждут сохранения:** Keychain (iOS, `AfterFirstUnlockThisDeviceOnly`, запись `pending-phrase`) / Android Keystore (`SecureStore`), тот же канал `dev.sinhron/keychain`, что и ключ устройства ADR-021. Как только человек сохранил их любым способом (Пароли, бумага с проверкой, лист, проверка всех 24 слов), запись **удаляется** — дальше, как и раньше, телефон хранит только ключ устройства.
- **Пароли (платформенный шов `PasswordVault`, канал `dev.sinhron/passwords`):**
  - iOS — **с 2026-11-04 заменено ADR-085** (запись связки ключей приложения; пароль сайта позволял странице домена выманить слова). Было: `SecAddSharedWebCredential` (системное «Сохранить пароль?», ответ «сохранено / отказ» приходит в приложение) и `ASAuthorizationPasswordProvider` для «Вставить из Паролей» при восстановлении. Требует `webcredentials:<домен>` в entitlements и `webcredentials.apps` в `apple-app-site-association` сервера (добавлено в `handlers/join.rs`). Домен один на сборку — `SinhronPasswordDomain` в `Info.plist` (= домен applinks, `chat.777400777.xyz`), **для любого сервера**: это только «папка» в «Паролях», сам сервер ничего не получает. Оператор со своей сборкой меняет оба места, как для applinks (ADR-043).
  - Android — Credential Manager (`androidx.credentials` 1.3.0 + `credentials-play-services-auth` для Android < 14): `CreatePasswordRequest` / `GetPasswordOption`. Домен не нужен — запись привязана к приложению. Провайдер — тот, что выбран в телефоне (Google, Samsung Pass, 1Password…).
  - Записи шифруются Apple / Google сквозным шифрованием (iCloud Keychain с кодом телефона; Google Password Manager — с ключом на устройстве / PIN экрана) и приезжают на новый телефон того же Apple ID / Google-аккаунта. На новом телефоне «У меня уже есть аккаунт» → «Вставить из Паролей».
- **Напоминание, не стена:** если выбрано «Позже» — через сутки в списке чатов спокойная карточка «Сохраните доступ к аккаунту» («Сохранить» / «Позже» — следующая через 7 дней); в Настройках строка «Секретные слова» показывает «Не сохранены». Экран «Секретные слова» стал настоящим: «Доступ не сохранён / сохранён — где и когда», действия, второе устройство.
- **Лист восстановления** (`recovery_sheet.dart`): картинка PNG (A4, 150 dpi) — 24 слова, QR со словами, имя, сервер, дата и предупреждение «кто видит эти слова — владеет аккаунтом; распечатайте и удалите файл». Отдаётся через системное «Поделиться» (печать, «Файлы»). QR сканируется на новом телефоне: «У меня уже есть аккаунт» → «Сканировать лист».
- **Проверка слов в Настройках** — теперь настоящая: ввести (или вставить из Паролей) все 24 слова, приложение сравнивает отпечаток с сохранённой личностью. Демо-экран с тремя выдуманными словами остался только в галерее.
- **Снимки экрана не запрещаем** (с 2026-11-04 кроме самого экрана слов — ADR-085). Запрет (FLAG_SECURE / скрытие на iOS) не убирает желание «сохранить быстро» — люди фотографируют экран вторым телефоном или бросают регистрацию. Вместо запрета даём способ лучше снимка (Пароли, лист) и короткую строку «снимок экрана уходит в облако вместе с фото».
- **Второе устройство** честно: на экране слов — «У вас есть второе устройство: если с этим телефоном что-то случится, переписка останется там. Но добавить новый телефон без слов нельзя» (ADR-027: подписывать новые устройства может только устройство с ключом аккаунта или слова). Поэтому второе устройство — не замена словам, а страховка переписки; кнопка «Привязать устройство».

### Alternatives
- **Passkey + зашифрованная копия слов (PRF / largeBlob)** — отклонено сейчас: нужен домен-«relying party» на каждый сервер, PRF есть не у всех провайдеров (iOS 18+, Android 14+ с Google), а восстановление всё равно упирается в тот же аккаунт Apple/Google. Пароль-запись даёт то же самое проще и везде.
- **Автозаполнение Flutter (`AutofillGroup` + `finishAutofillContext`)** — без нативного кода, но не говорит, сохранил ли человек, и на iOS срабатывает ненадёжно для программно заполненных полей. Явный API даёт ответ «сохранено» — по нему удаляется копия с телефона.
- **Хранить слова на первом телефоне всегда (как кошельки)** — «Показать ещё раз» работало бы, но человекочитаемые слова на телефоне — лишняя мишень (взгляд через плечо, разблокированный телефон). Держим их только до сохранения.
- **Копия слов на сервере под паролем** — отклонено: сервер не доверенный (спека §6.8), пароль подбирается офлайн.
- **Совсем без проверки** — оставили лёгкую проверку 2 слов только на пути «Записать»: менеджер паролей хранит слова точно, проверка там не нужна.

### Consequences
- **+** Обычный путь регистрации — одно нажатие «Сохранить в Пароли» и системное «Сохранить»; ни одного слова вручную. Слова переезжают на новый телефон сами.
- **+** Никто не заперт на шаге 3: «Позже» — и сразу в чаты; напоминание спокойное и редкое.
- **+** Нет причины делать снимок экрана — значит, слова реже оказываются в облаке с фотографиями.
- **−** Слова теперь могут жить **у Apple/Google** (в зашифрованном менеджере паролей человека) и **на телефоне до сохранения** (Keychain/Keystore, только это устройство). Кто вскроет аккаунт Apple/Google человека вместе с кодом телефона — получит слова. См. threat-model.
- **−** iOS: без включённой синхронизации «Пароли и связка ключей» запись остаётся только на этом iPhone — говорим об этом в подписи. Приложение не может это проверить.
- **−** iOS: сохранение работает, только когда сервер, указанный в `SinhronPasswordDomain`, отдаёт `webcredentials` в AASA (нужна выкладка сервера; Apple кэширует AASA через свой CDN до суток). До этого кнопка отвечает «не получилось» и предлагает «Записать».
- **−** Лист восстановления — файл со словами во временной папке и там, куда его отправят; предупреждение прямо на листе.
- **−** Android 13 и старше: Credential Manager работает через Google Play services (библиотека `credentials-play-services-auth`) — отступление от «без Google Play Services» ADR-040 только для этой кнопки (FCM ADR-057 делает то же). Без сервисов Google кнопка отвечает «не получилось», остальные способы работают.
- **−** Не проверено на телефонах: системные окна сохранения/выбора пароля, печать листа. Swift — `swiftc -typecheck`, Kotlin — `gradle :app:compileDebugKotlin`, логика — виджет-тестами с подменой шва.

---

## ADR-061 · Показ экрана в звонке: iPhone — Broadcast Upload Extension, Android — MediaProjection; тот же SFrame, что у камеры (2026-10-18)

### Context
Владелец: «и также экран показывать, на обеих платформах, во время звонка». Нужно показать весь экран телефона (не только Sinhron, и пока Sinhron в фоне) в личном и групповом звонке, с тем же сквозным шифрованием, что у камеры (ADR-024), читаемым текстом и без лишних мегабит на плохой связи (ADR-041/046).

### Decision
- **Вторая видеодорожка LiveKit** (`source = screenShareVideo`) рядом с камерой: `LocalParticipant.setScreenShareEnabled`. E2EE: `E2EEManager` livekit_client 2.7.0 вешает SFrame-шифратор на **каждую** опубликованную дорожку (`LocalTrackPublishedEvent`), ключ тот же (MLS-лист участника, ADR-024). Кодек — как у камеры из настроек комнаты (H.264 там, где есть аппаратный, иначе VP8; ADR-041/045), запасной кодек выключен (он ушёл бы без шифрования), AV1 нет (не шифруется). Опции публикации экрана живут в тех же `defaultVideoPublishOptions` комнаты (`screenShareEncoding`), захват — `defaultScreenShareCaptureOptions` (`livekit_engine.dart`).
- **iPhone — Broadcast Upload Extension** (цель `ios/ScreenShare`, `com.sinhron.sinhron.ScreenShare`, чистый Swift, по образцу примера LiveKit/Jitsi, Apache-2.0). Кнопка «Показать экран» → livekit_client показывает системный лист «Трансляция экрана» с нашим расширением; после «Начать вещание» ReplayKit отдаёт кадры расширению (и когда Sinhron в фоне), оно шлёт их JPEG-ами по Unix-сокету в контейнере **App Group `group.com.sinhron.sinhron`** (тот же, что у расширения «Поделиться», ADR-060), flutter_webrtc (`FlutterBroadcastScreenCapturer`, `deviceId: broadcast-manual`) делает из них дорожку, livekit_client публикует её сам по Darwin-уведомлению `iOS_BroadcastStarted`. Изменения против образца: не больше 15 кадров/с, длинная сторона ≤ 1920 px, JPEG 0,9 (память расширения ~50 МБ); App Group берётся из Info.plist (`RTCAppGroupIdentifier`); запущено вне звонка (из Пункта управления) — через 10 с «Начните показ экрана из звонка в Sinhron»; останавливается, когда приложение закрывает сокет (Остановить / положили трубку) или по `iOS_BroadcastRequestStop`.
- **Android — MediaProjection** по правилам Android 14: сначала системное согласие (`Helper.requestCapturePermission` flutter_webrtc), потом **foreground service типа `mediaProjection`** (`ScreenShareService` в `ScreenShare.kt`, канал `dev.sinhron/screen_share`, `start` отвечает, когда сервис уже в foreground), и только потом дорожка (`getDisplayMedia` берёт сохранённое согласие). Уведомление «Вы показываете экран» с кнопкой «Остановить» (→ `onStop` в Dart). Отдельный сервис, а не `CallService`: у того свои типы (микрофон, камера) и жизнь от начала до конца звонка.
- **Чёткость важнее плавности** (`screenShareLayerFor`): разрешение экрана сохраняется (только сжатие длинной стороны до 1920 / 1600 / 1280 по классу телефона, ADR-046), отдаются кадры: 15 к/с, на плохой связи 8, слабый телефон 10, нагрев «serious» 10, «critical» 5 (и 1280). Битрейт по связи: отличная 2,5 Мбит/с, хорошая / не измерена 1,5, плохая 600 кбит/с; слабый телефон ≤ 1 Мбит/с, горячий ≤ 1,5. Ставится на верхний слой через `RtpSender.setParameters` (как потолок камеры), меняется при смене связи и раз в 10 с по нагреву; нижний слой LiveKit (половина размера, 3 к/с) — для зрителей на плохой связи. `degradationPreference` у экрана — `maintainResolution` (по умолчанию LiveKit).
- **Интерфейс отдельно от экрана звонка** (`call_screen_share.dart`, `CallScreenShareLayer` поверх `CallScreen` в `live_call_screen.dart` — экран звонка переделывает другая ветка; **с 2026-10-19 (status 168) кнопка — среди кнопок звонка**, `CallScreen.onShareScreen`, — у правого края она висела поверх имени): круглая кнопка «Показать экран» у правого края (во время показа — «Остановить»), красная плашка «Вы показываете экран · Остановить» сверху; чужой экран — во весь экран поверх звонка: щипок — зум и сдвиг (`InteractiveViewer`), «Повернуть» (четверть оборота) и поворот самого телефона, пока открыт, «К звонку» (потом — плашка «Смотреть экран: <имя>»), «Завершить». Камеры в плитках и своё окошко берут только `TrackSource.camera`, переключение камеры — тоже.
- **Конец**: положили трубку / звонок кончился / комната ушла → показ остановлен, сервис остановлен (`ScreenShareNotifier` слушает `activeCallProvider` и комнату). Состояние: `off` → `asking` (ждём системный диалог / лист; лист iPhone, закрытый без ответа, забывается через 60 с) → `on`.

### Alternatives
- **Показывать только Sinhron (`RPScreenRecorder` внутри приложения)** — без расширения, но не видно других приложений и всё кончается, как только Sinhron уходит в фон; владелец просил экран.
- **Встроить в `CallService`** (тип `mediaProjection` добавить к микрофону) — нельзя запросить тип до согласия (Android 14 бросает исключение), а сервис звонка стартует раньше; отдельный сервис проще.
- **Отдельная комната / отдельный участник для экрана** — второе подключение, вторые ключи SFrame; не нужно — LiveKit держит обе дорожки одного участника.
- **Экран той же H.265, что камера после согласования (ADR-045)** — пока нет: публикация экрана берёт кодек из настроек комнаты (H.264/VP8, есть у всех); перевод на H.265 — после проверки на телефонах.

### Consequences
- **+** Экран виден всем в звонке, зашифрован как камера; сервер и LiveKit видят шифр.
- **+** На iPhone показ идёт и когда Sinhron в фоне; на Android — уведомление с «Остановить».
- **−** На iPhone в показ попадает всё, что на экране, включая баннеры уведомлений других приложений (iOS не прячет их при трансляции стороннего приложения) — предупреждение в `threat-model.md`.
- **−** Android: если показ остановлен системой (значок «Остановить показ» в строке состояния Android 15, блокировка экрана на Android 14+), flutter_webrtc не сообщает об этом — картинка у зрителей застынет до «Остановить» в Sinhron (tech-debt 2.49).
- **−** Новый App Group и новая цель в аккаунте Apple (автоподпись регистрирует их сама при сборке); расширение — ещё ~0,3 МБ в IPA.
- **−** Не проверено на телефоне: живой показ iPhone ↔ Android, память расширения, нагрев на 10 минутах показа.

**Дата принятия:** 2026-10-18.

---

## ADR-057 · Android: связь всегда — push Google (FCM) без содержимого, «Постоянное соединение» само, батарея (2026-10-18)

### Context
Владелец: «я хочу, чтобы связь была всегда». Отец (Samsung Galaxy A40, Россия) смахнул Sinhron из недавних — и звонок не зазвонил: ntfy у него нет (ADR-040 требует ставить отдельное приложение и вписывать сервер), «Постоянное соединение» было выключено по умолчанию, а после смахивания служба на Samsung может остановиться. Человек не будет ничего настраивать. Владелец решил: **делать push Google (FCM)** — пересмотр отказа от FCM в ADR-040.

### Decision
- **FCM — только «разбудить».** Сервер (`server/src/fcm.rs`, FCM HTTP v1) шлёт data-сообщение высокого приоритета с **одним полем `s`**: та же маленькая JSON, что у UnifiedPush (`{"t":"msg","n":…}` / `{"t":"call","id":…,"v":…}`) плюс `ts`, дополненная пробелами до 128 байт и **запечатанная AES-256-GCM ключом телефона** (32 случайных байта, телефон сделал сам и отдал вместе с токеном; AAD `sinhron-fcm-v1`). Сообщение и звонок для Google одинаковы: один размер, один приоритет, один TTL (сутки), без collapse key, без `notification` — Google видит только, что для Sinhron на этом телефоне что-то пришло, и когда. Звонок, пролежавший в очереди Google дольше 2 минут (`ts`), телефон не показывает.
- **Токен** — тот же `PUT /v1/push-token`, та же подпись ключом устройства: `token_hex` = `fcm:` + токен Google, `call_hint_key_hex` = ключ телефона (для обоих видов, alert и voip; колонка `apns_tokens.call_hint_key`, миграция `20261018160000_fcm.sql`). Без ключа FCM-токен не принимается. Ответы Google 404 / `UNREGISTERED` / `SENDER_ID_MISMATCH` / «неверный токен» — токен забывается; 401 — один повтор с новым access token.
- **Ключи оператора — вне git**, как ключ APNs: `/etc/sinhron/fcm/service-account.json` (закрытый ключ сервисного аккаунта, uid 10001, права 400) и `/etc/sinhron/fcm/google-services.json` (id приложения — не секрет, они в любом APK с Firebase). Оба на месте — FCM включён; нет — выключен, всё как раньше. JWT сервисного аккаунта подписывается RS256 через `ring` (уже в дереве через rustls) — новых крейтов нет; access token живёт до 5 минут до срока.
- **В APK нет `google-services.json` и плагина Google**: сервер отдаёт id своего проекта Firebase в `GET /v1/push/info` (`"fcm": {project_id, app_id, api_key, sender_id}`), Dart передаёт их нативу (`fcmConfigure`), `Fcm.kt` поднимает FirebaseApp из них (и при каждом старте процесса — из сохранённых). Один APK работает с Firebase любого оператора или без него. Библиотека — только `com.google.firebase:firebase-messaging:25.1.3` (родной приёмник, а не плагин `firebase_messaging`: тот тянет `firebase_core` и поды Firebase в iOS-сборку, требует файлы конфигурации при сборке). Автоинициализация, аналитика и выгрузка метрик доставки выключены в манифесте.
- **Порядок путей:** push Google (есть сервисы Google и Firebase у сервера) → ntfy (ADR-040) → «Постоянное соединение». ntfy-подсказки не показываются, когда работает Google.
- **Push будит соединение** (`PushWake.kt` ↔ `lib/core/push_wake.dart`): FCM-поток держит процесс до 9 с; приложение (движок экрана или общий движок без экрана, как у «Постоянного соединения») подключается, сервер досылает ждавшее, приложение само рисует «Имя: текст» (сообщения у него расшифрованы) или забирает приглашение звонка (имя звонящего, «Отклонить» доходит). Затем соединение **закрывается до ответа натива** — иначе Android заморозит процесс с открытым сокетом, и сервер перестанет слать push. Не нарисовало за 9 с — простое «Новое сообщение». Звонок звонит сразу (уведомление на весь экран), соединение держится, пока звонит.
- **Без Google и без ntfy — «Постоянное соединение» само включено** (пока человек не тронул переключатель: `android_keep_connected_auto`), выключается само, когда путь появился. После смахивания из недавних служба возвращается через секунду (`onTaskRemoved` → точный будильник → `KeepAliveBootReceiver`), после перезагрузки — как раньше.
- **Батарея:** при первом запуске (после разрешения уведомлений) один раз — системное окно «Не ограничивать батарею для Sinhron?» (`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`; APK, не Google Play — можно); на Samsung перед ним — простыми словами окно с кнопкой к «Никогда не спящим приложениям» (Device Care; нет такого экрана — экран батареи; нет и его — страница приложения). В «Настройки → Уведомления» первым разделом — **«Звонки дойдут: да / нет — что сделать»** с кнопкой на каждое исправление (`lib/core/call_reach.dart`).

### FCM из России (проверено 2026-10-18)
Сообщений о блокировке FCM (`mtalk.google.com`, `fcm.googleapis.com`) Роскомнадзором нет; на FCM работают и банки, и государственный MAX. Ограничены YouTube, WhatsApp, Telegram — не FCM. Риск: в регионах с «белыми списками» мобильного интернета push MAX, по сообщениям, не проходят — FCM там тоже не работает, но и наш сервер в такие списки не входит; по Wi-Fi всё работает. Сервер ходит к `oauth2.googleapis.com` и `fcm.googleapis.com` из своего дата-центра. Если FCM заблокируют — сервер получает ошибки (токены сохраняются), телефон: путь Google есть, но push не приходят — «Постоянное соединение» тогда надо включить вручную (раздел «Звонки дойдут» этого не видит — см. tech-debt 2.45).

### Alternatives
- **Плагин `firebase_messaging`** — отклонён: `firebase_core` + поды Firebase в iOS, файлы конфигурации при сборке, Dart-обработчик в фоне — то же, что наш нативный приёмник, но тяжелее.
- **Плагин google-services и `google-services.json` в APK** — отклонено: APK привязан к одному проекту, сборка без файла падает; id с сервера — то же самое без пересборки.
- **Открытый `{"t":"call","id":…}`** (как в ntfy) — отклонено: Google видел бы, что это звонок, и его id.
- **Web Push (RFC 8291) поверх FCM** — тот же результат, но расшифровку ECDH + HKDF пришлось бы писать в Kotlin; общий ключ + AES-GCM проще и проверяем на сервере тестом.
- **UnifiedPush embedded FCM distributor** — нужен шлюз-переписчик у оператора; лишнее звено.
- **RuStore push** — только для устройств с RuStore, ещё одна учётная запись оператора; отложено.

### Consequences
- **+** Звонок звонит и сообщение приходит, даже если Sinhron смахнут, без ntfy и без настроек — на любом телефоне с Google.
- **+** На Android с FCM в уведомлении — «Имя: текст» (как в «Постоянном соединении»), а не «Новое сообщение».
- **−** Google узнаёт: на этом телефоне (и в Google-аккаунте телефона) стоит Sinhron, этот сервер — его проект Firebase, и **время** каждого push (не что, не от кого, не сообщение или звонок). Это метаданные, которых ADR-040 избегал; `docs/threat-model.md`.
- **−** Владелец должен один раз создать проект Firebase и положить два файла на сервер (`docs/open-items.md`, шаги по-русски).
- **−** APK больше на ~1–2 МБ (firebase-messaging + play-services-base).
- **−** Не проверено на телефоне: живой FCM, пробуждение при смахнутом приложении, окно Samsung — только сборка и тесты.

### Дополнение 2026-10-19 · один движок Flutter на процесс; с push Google «Постоянное соединение» не нужно
**Что было (Samsung A40, 0.6.0):** Sinhron смахнут; сервер 14 минут (12:05–12:19) отправлял звонки и сообщения в открытое фоновое соединение (`delivered=1`), на телефоне — ничего; открыв приложение, человек получил 24 сообщения разом (`resume replayed=24`). **Причина:** соединение живёт в ядре Rust (на весь процесс), а код, который его читает, рисует уведомления и звонок, — в Dart, в движке Flutter. Общий движок (`SinhronApplication`), переживающий экран, создавался только если «Постоянное соединение» было включено **уже при старте процесса**. Включённое позже (само — ADR-057, или вручную) запускало только службу; экран работал на своём движке, и смахивание его уничтожало — весь Dart. Служба держала процесс, ядро Rust — сокет и heartbeat; сервер видел «на связи», а читать было некому, курсор не двигался.

**Решение:**
- **Экран всегда на общем движке** (`MainActivity.onCreate` → `SinhronApplication.ensureEngine` до `super.onCreate`): код приложения живёт, пока жив процесс, как бы ни включали режим. После смахивания Dart получает `detached`, но читает соединение: сообщение → системное уведомление «Имя: текст» по настройке «Что показывать» (`maybeShowBanner`), приглашение звонка → полноэкранный звонок (`CallBridge.reportIncoming`, тот же id, что из FCM, — звонит один раз). Машина звонков (`activeCallProvider`) поднимается в `main` до первого подключения — приглашение на соединении без экрана не теряется. Push будит уже живой Dart за миллисекунды (не холодный старт ~3–6 с).
- **Push при открытом соединении** (сервер шлёт его подключённым Android с 167): Dart отвечает `wakeDone(handled)` — дошло ли сообщение до приложения (за 30 с до push или за время пробуждения); дошло → натив не рисует «Новое сообщение» поверх «Имя: текст». Соединение было открыто, а ничего не пришло — сокет мог умереть незаметно: он заменяется (`netNetworkChanged`, Resume досылает проглоченное); не во время звонка.
- **Политика:** с работающим push Google «Постоянное соединение» **выключено** — push будит приложение, сокет живёт только пока приложение открыто (и несколько секунд после push). Само включается только без push (нет сервисов Google и нет ntfy). «Вкл», выбранное вручную, когда push не было (или до этого исправления — тогда неизвестно, был ли push), **возвращается в автомат**, как только появился push Google (`android_keep_connected_route`); выбранное при работающем push — остаётся. ntfy для этого не считается (может смотреть на ntfy.sh — 150). Текст в «Настройки → Уведомления» объясняет это.
- **Сервер** не менялся: фоновое соединение без heartbeat сбрасывается через 180 с (120 + 60; предел 450 с), ping/pong WebSocket не нужен — считается любой кадр; с 167 push Google идёт подключённым Android всегда.

**Последствия:** **+** звонок и сообщение при смахнутом Sinhron — и из сокета, и из push, без дублей; **+** батарея: у телефонов с Google сокет в фоне не висит. **−** Состояние Dart (открытый чат, стек экранов) переживает закрытие экрана — как на iPhone. **−** Проверено тестами и сборкой Kotlin, не на телефоне.

---

## ADR-062 · Стикерпак из Telegram по ссылке: сервер берёт набор ботом оператора (2026-10-18)

### Context
Владелец: «чтобы по ссылке из Телеграма скачать стикерпак целиком, сейчас выдаёт ошибку». Ссылка `https://t.me/addstickers/<имя>`, вставленная в «Вставить код набора», давала «нет кода» — ADR-049 нарочно не ходил в Telegram. Файлы набора отдаёт только Telegram: документированный путь — Bot API (`getStickerSet` + `getFile` с токеном бота). Токен — секрет, в приложение его класть нельзя (его вытащат из сборки), и с телефона в России Telegram может быть недоступен.

Проверено 2026-10-18 с боевого сервера (176.124.223.138, Россия): `api.telegram.org` и `t.me` по **IPv4 не отвечают** (таймаут 15 с), по **IPv6 отвечают** (`getMe` с выдуманным токеном → 401 Unauthorized за 0,15 с — то есть до API доходим). Из контейнера в сети `egress6` (как у Caddy) — тоже доходит по IPv6.

### Decision
- **Ходит сервер, не телефон.** `POST /v1/stickers/telegram {"name"}` → название, вид набора и список стикеров (эмодзи, формат, размер, есть ли у Telegram маленькая картинка) — **без file_id Telegram**; `GET /v1/stickers/telegram/{name}/{i}` — файл стикера, `…/{i}/thumb` — маленькая картинка Telegram (для видео-стикеров: iPhone не играет WebM, ADR-049). Код: `server/src/handlers/telegram_stickers.rs`.
- **Токен оператора** — файл `/etc/sinhron/telegram/bot-token` на хосте (вне git, как ключ APNs; uid 10001, 400), смонтирован только для чтения; можно `SINHRON_TELEGRAM_BOT_TOKEN_FILE` / `SINHRON_TELEGRAM_BOT_TOKEN`. Нет файла — функция выключена, ответ `503 {"error":"not_configured"}`. Токен не попадает в журналы: ошибки reqwest (в них URL с токеном) пишутся `without_url()`; Telegram отверг токен (401/404) — тоже `not_configured` + строка в журнале «проверьте bot-token».
- **Связь с Telegram из России:** клиент сервера сам перебирает адреса **сначала IPv6** (`Ipv6First`), `sinhron-server` подключён ко второй сети `egress6` (docker-compose). Без IPv6 у хоста IPv6-попытки отваливаются сразу и идёт IPv4. Если не доходит ни так, ни так — `502 {"error":"unreachable"}`, а оператор может указать другой адрес Bot API: `SINHRON_TELEGRAM_API_URL` (например, свой `telegram-bot-api` за границей).
- **Кэш на сутки** на диске: `<SINHRON_MEDIA_DIR>/telegram-cache/<имя в нижнем регистре>/pack.json` + файлы по `file_unique_id` (`SINHRON_TELEGRAM_CACHE_DIR`). Второй человек с той же ссылкой в течение суток Telegram не дёргает. Раз в час — чистка старше суток. Запись атомарная (временный файл → rename).
- **Пределы:** только зарегистрированные на сервере (подпись `x-sinhron-*`, домены `sinhron-tg-stickers-v1:` / `sinhron-tg-sticker-file-v1:`, привязанное устройство считается своим человеком, ADR-027); на аккаунт — 30 наборов и 3000 файлов в час (`SINHRON_RATE_TG_PACKS` / `SINHRON_RATE_TG_FILES`, `KeyedLimiter`); к Telegram — не больше 4 запросов сразу на весь сервер; 429 Telegram передаётся как `rate_limited` с `Retry-After`. Имя набора — `[A-Za-z0-9_]{1,64}` (и путь в кэше, и URL Bot API безопасны), файл больше 1 МБ — не стикер, больше 200 стикеров не берём.
- **Приложение:** «+» в панели стикеров → «Вставить ссылку или код набора» понимает и `t.me/addstickers/…`, `t.me/addemoji/…`, `telegram.me/…`, `tg://addstickers?set=…` (внутри любого текста); нажатие на такую ссылку в чате → «Добавить стикеры в Синхрон». Лист: «Открываю набор из Telegram…» → название, «N стикеров · Из Telegram», первые 10 стикеров (в движении) → «Добавить N стикеров» → «Загружаю стикеры: 40 из 120» (по 8 файлов за раз, «Отменить» останавливает) → **обычный свой набор** (ADR-049: зашифрован на телефоне, им можно делиться кодом). Id набора `tg.<имя>` — повторное добавление заменяет; «автор» — `t.me/addstickers/<имя>`. `.tgs` и `.webm` остаются анимированными, превью делает телефон (у видео — из картинки Telegram). Стикер, который не загрузился, пропускается («не загрузилось: 2»). Ошибки — простыми словами: «Набор не найден — проверьте ссылку», «Сервер не настроен для наборов из Telegram — попросите того, кто его держит», «Сервер пока не умеет… — его нужно обновить» (старый сервер без адреса), «Сервер сейчас не достаёт до Telegram», «Слишком много наборов подряд», «Не удалось загрузить набор — проверьте связь». Код: `lib/features/stickers/telegram_import.dart`, Rust `sinhron_sync::telegram_stickers`, FFI `telegram_pack_info` / `telegram_sticker_files`.
- **Права:** человек добавляет набор, который выбрал сам, по ссылке, которую ему дали; мы не перебираем и не выкладываем каталоги Telegram, у сервера нет списка наборов, кэш живёт сутки. Ответственность за права на чужие стикеры при пересылке набора дальше — на том, кто им делится (как в ADR-049). Это меняет пункт «Telegram» ADR-049: файлы по-прежнему не скачиваются в обход Telegram, но по ссылке — через Bot API.

### Alternatives
- **Токен бота в приложении** — нет: его извлекут из сборки и используют от нашего имени; и телефон в России часто не достаёт до Telegram.
- **Скачивать страницу `t.me/addstickers/…`** — нет: страница не отдаёт файлы, это был бы разбор чужого сайта, а не API.
- **MTProto-клиент (как приложение Telegram)** — нет: нужен вход в аккаунт Telegram, тяжёлая библиотека и условия Telegram для клиентов.
- **Телефон ходит в Telegram сам, сервер только как запасной путь** — нет: всё равно нужен токен на телефоне.
- **Отдавать весь набор одним ответом** — нет: превью было бы долгим (до ~30 МБ), и нечем показать прогресс; по одному файлу — превью за секунду, прогресс, повтор одного файла.
- **Открывать `t.me`-ссылки приложением на Android (intent-filter)** — пока нет: домен не наш, проверить его нельзя, а на Android 8–11 одна непроверенная https-ссылка отключает проверку и наших ссылок-приглашений (ADR-043). На iPhone чужой домен приложению не отдать вовсе. Ссылку можно вставить, нажать в чате или (после ветки «Поделиться в Sinhron») отправить в Sinhron через «Поделиться» — точка входа `openTelegramPackWith`.

### Consequences
- **+** Набор Telegram целиком в два нажатия, анимированный, дальше живёт как свой (зашифрован, делится кодом).
- **+** Telegram видит только нашего бота; телефон с Telegram не связывается.
- **−** Наш сервер видит, какой аккаунт попросил какой набор (в момент запроса; кэш и журналы аккаунта не хранят) — threat-model.
- **−** Нужен токен от оператора (шаги — `docs/open-items.md`); без него — «Сервер не настроен».
- **−** Зависимость от IPv6 на российском сервере; если пропадёт — нужен `SINHRON_TELEGRAM_API_URL`.
- **−** Кэш на диске без предела по объёму (≈ до 30 МБ на набор, сутки); при злоупотреблении ограничивает лимит на аккаунт (tech-debt 2.50).
- **−** Не проверено на живом Telegram: тесты — с поддельным Bot API; живой запрос — после выкладки сервера и токена.

---

## ADR-058 · Android обновляется сам — с нашего сервера, с проверкой подписи (2026-10-18)

### Context
Владелец: «как мы можем сделать с обновлениями? Клиент сам себя обновляет?». Отец владельца в России ставит Android-приложение из APK с нашего сервера (`https://chat.777400777.xyz/download/sinhron.apk`, status 148) — Google Play у него нет, репозиторий закрыт. Магазина, который обновил бы приложение, нет: каждая новая версия — «скачай файл по ссылке ещё раз». Нужно: приложение само узнаёт о новой версии и ставит её как можно проще, не открывая дыру «кто подменит файл на сервере, тот поставит своё приложение».

### Decision
- **Манифест рядом с APK:** `https://<сервер>/download/android.json` — `{version, build, notes, apks: {abi: {url, sha256, size}}}`. Пишет `scripts/android_release.sh` (в `build/android-release/` вместе с файлами `sinhron-<версия>-<сборка>-<abi>.apk`); манифест не пишется, если APK подписан не нашим ключом. Выкладывает `scripts/publish_android.sh --host …` по ssh: сначала APK с версией в имени, потом постоянные имена для `/join` (`sinhron.apk` = arm64-v8a, `sinhron-32bit.apk` = armeabi-v7a), **манифест последним** (временное имя → переименование), старые сборки чистятся (остаются три последние). Caddy отдаёт `android.json` с `Cache-Control: no-cache`.
- **Приложение** (`lib/core/app_update.dart`): через 30 с после старта и каждые 6 часов, и по «Настройки → О приложении → Проверить обновления» берёт манифест **со своего сервера** (`httpBaseUrl` + `/download/android.json`). Сборка новее своей (`build` > `SINHRON_BUILD`; сборки — время UTC, только растут) → спокойная карточка над «Чатами»: «Доступно обновление 0.6.0 · Обновить / Позже». «Позже» — до следующего запуска (или до ещё более новой сборки).
- **Скачивание — по нажатию**, не само (60 МБ по мобильному интернету — решать человеку): в фоне, с процентами, в `cacheDir/updates/` (старые файлы там удаляются). APK выбирается под процессор телефона **той же разрядности, что стоит сейчас** (`Process.is64Bit()`): у split-APK код версии = сборка + 1000 × тип процессора, и переход 64 → 32 бита Android принял бы за откат версии.
- **Перед установкой** (`checkApk`): SHA-256 файла = из манифеста; Android сам читает файл (`getPackageArchiveInfo`): пакет `com.sinhron.sinhron`, код версии выше установленного, **сертификат подписи = наш** (`kApkCertSha256`, SHA-256 `6F:04:86:35:…:69:18`). Любое несовпадение — файл удаляется, «Файл обновления не прошёл проверку безопасности». Хеш защищает от битой загрузки; подпись — от подмены файла и манифеста вместе (кто взломал сервер, не подпишет нашим ключом; Android и сам не поставит обновление с другой подписью — мы просто говорим об этом раньше и понятно).
- **Установка — системный установщик** (`AppUpdate.kt`, канал `dev.sinhron/update`): `ACTION_INSTALL_PACKAGE` + `content://` от своего `UpdateFileProvider` (только `cacheDir/updates/`), разрешение `REQUEST_INSTALL_PACKAGES`. Android **всегда** просит одно нажатие «Установить» — обойти нельзя (без root / прав владельца устройства). В первый раз Android ещё спрашивает «разрешить установку из этого источника» — перед этим приложение одним экраном объясняет, что нажать («Настройки» → «Разрешить из этого источника» → назад → «Установить»). Переписки и ключи остаются (то же приложение, та же подпись).
- **Где выключено:** iOS (TestFlight / App Store обновляют сами); отладочные сборки (нет номера сборки); установлено из магазина (`getInstallSourceInfo().installingPackageName` — Google Play, Galaxy Store, RuStore, AppGallery, F-Droid, Obtainium…, `installedFromStore`); сборка подписана не нашим ключом (отладочная подпись — Android не принял бы обновление). Строка «Проверить обновления» в Настройках там не показывается.

### Alternatives
- **Google Play / RuStore** — отклонено пока: не у всех есть Google Play; RuStore — отдельная публикация, проверка, аккаунт; потом можно (тогда магазин обновляет сам, наш механизм выключается сам).
- **Obtainium / F-Droid-репозиторий** — лишнее приложение и настройка для пожилого человека.
- **`PackageInstaller` session API** — то же одно нажатие на Android 11 (тихо без нажатия — только Android 12+ и только при `setRequireUserAction`, когда мы уже установщик прошлой версии; ставили из браузера). Больше кода, выигрыш — ноль.
- **Скачивать само в фоне** — отклонено: трафик и место без спроса.
- **Только SHA-256 из манифеста** — отклонено: манифест лежит там же, где APK; подменили одно — подменят и другое. Подпись — единственное, что нельзя подделать с сервера.
- **Манифест с отдельного адреса, зашитого в приложение** — отклонено: у человека на чужом сервере обновлений не будет — это и правильно; подпись всё равно наша.

### Consequences
- **+** Новая версия у человека — карточка «Обновить» → проценты → «Установить» (в первый раз ещё одно разрешение), без ссылок и браузера.
- **+** Подменённый на сервере APK не установится: и наша проверка, и сам Android требуют нашу подпись.
- **−** Файл качает Dart `HttpClient` напрямую: «Прокси» (SOCKS5 / Tor) приложения на скачивание обновления не действует (tech-debt 2.46). В России сайт доступен без VPN — сейчас не мешает.
- **−** Потеря ключа подписи = конец обновлений и для этого механизма (как и для любого Android-приложения) — копия ключа в `docs/open-items.md`.
- **−** Не проверено на телефоне: разрешение «из этого источника» на Samsung, чтение подписи из файла на Android 11 (A40), что после установки приложение открывается кнопкой «Открыть» установщика (само Android не перезапускает).

---

## ADR-064 · Новое устройство — как то же самое: полный перенос при привязке и синхронизация моих устройств (2026-10-18)

### Context
Владелец: «чтобы синхронизация между устройствами реально работала хорошо — сохранились все стикерпаки, все контакты, вся история, вообще всё, что возможно, как будто это то же самое устройство». И вопрос: «синхронизируется ли переписка при подключении нового устройства?» — до этого: только **последние 200 сообщений каждого чата** (конверт `History`, ADR-025) с устройства, которое добавило новое, без исчезающих и удалённых; «Избранное» — флагом (ADR-055). Контакты (ADR-052), стикерпаки (ADR-049), папки, настройки чатов (без звука / закреплён / в архиве), заблокированные, проверенные, профиль, настройки — **только на том устройстве**, где их сделали. MLS не даёт новому устройству расшифровать прошлое: всё, что было до его добавления, оно может получить только от другого моего устройства.

### Decision
**Канал — группа моих устройств.** «Избранное» (ADR-055) — MLS-группа, в которой только мои устройства; она же теперь канал между ними. Если её ещё нет, а устройство появилось, приложение создаёт её само (`NetService.syncDevices` → `SavedMessages.ensure`). Сообщения в ней запечатаны **только на мой ключ доставки** (как `History`): получают только мои устройства. Принимаются только **от меня** (MLS-отправитель — моя личность) и только в группе, где **нет никого, кроме меня** (`is_own_devices_group`); иначе отбрасываются. Отправлять туда Rust тоже отказывается, если в группе есть кто-то ещё.

**1. Перенос (один раз, при привязке).** Устройство, добавившее новое в «Избранное» (`sync_devices`; коммит выигрывает одно), ставит задачу переноса (`sinhron_sync::transfer`):
- **Сборка:** первая часть — «шапка» (`sinhron_storage::transfer::Header`): чаты с настройками (без звука, закреплён и порядок, архив, таймер, закреплённое сообщение, собеседник, «запрос»), контакты (имя, звезда, дата), заблокированные, имена / фото / «О себе» других людей, история звонков, настройки (см. ниже) с их часами, список стикерпаков с ключами их файлов, какой чат — «Избранное». Дальше — части с сообщениями (**вся история**: текст, медиа-ссылки с ключами, ответы, реакции, правки, статусы) по ~2 МБ. Каждая часть — `"SNTP"‖v1‖JSON`, зашифрована как медиа (свежий AES-256-GCM-ключ, размер по Padmé), лежит до выгрузки зашифрованной в `<БД>.transfer/`.
- **Выгрузка:** файлы стикерпаков (тот же шифротекст, что на телефоне), части, затем **манифест** (`"SNTM"`: части с ключами, стикерпаки, итоги) — через обычный `POST /v1/media`. Ключ манифеста уходит **только внутри MLS**: конверт `Transfer` (тег 40, стадия «готово», адресован ключу нового устройства; мои третьи устройства его игнорируют).
- **Медиа «потом»:** файлы не копируются в перенос — в сообщениях уже их ссылки и ключи. Старое устройство спрашивает сервер `POST /v1/media/touch` (новое, ≤ 256 хэшей): «продли эти на 90 дней, каких нет?» — и **выкладывает недостающие из своих локальных копий** (ADR-033; тот же шифротекст, тот же хэш — сервер узнаёт только, что такой блоб снова есть). По окончании — `Transfer` «медиа готовы» (сколько не нашлось нигде). Новое устройство открывает фото и файлы по нажатию, как обычно. Старый сервер без `touch` — выкладывается всё, что есть локально (сервер дедуплицирует).
- **Новое устройство** скачивает манифест, по одной части применяет (`import_header` / `import_messages`), потом стикерпаки. Слияние не теряет его своего: сообщения сопоставляются по wire id (то, что уже пришло историей или вживую, только дополняется реакциями / правкой / ответом), непрочитанные не растут, имя чата — только вместо заглушки, флаги чата — если здесь их не меняли позже, настройки — по часам.
- **Продолжение после перерыва:** обе стороны хранят задачу в зашифрованной БД (`transfer_out` / `transfer_in`) после каждого шага; шаг при ошибке сети ничего не сдвигает — приложение повторяет через 30 с и при каждом подключении. Части лежат на сервере 90 дней, поэтому старое устройство может уйти из сети, как только выложило их. Пропавшая с сервера часть — задача «не удалась» с причиной (а не вечный повтор).
- **Вручную:** «Устройства» → нажать на другое устройство → «Отправить всё на это устройство» — для устройств, привязанных до этого изменения, и после неудачи.
- **Видно:** карточки с прогрессом на экране «Устройства» (обе стороны: «Отправляю: 3 из 12», «Фото и файлы: 120 из 900», «Готово — перенесено сообщений: 5 210»); на новом — полоска над списком чатов «Переношу переписку… 40%».

**2. Синхронизация после (всё время).** Предмет синхронизации — **элемент** с часами в `sync_clock` (схема v16, `sinhron_storage::devsync`): `set:<ключ>`, `chat:<id>` (без звука / архив / закреплён / порядок), `read:<id>` (прочитано до — время самого нового входящего; дополнено 2026-11-03, status 223: на другом устройстве непрочитанными остаются только пришедшие позже, уведомления чата убираются), `contact:<ключ>`, `blocked:<ключ>`, `pack:<id>`. Локальное изменение ставит отметку (время в мс — «последний пишущий побеждает»; порядковый номер — «ещё не отправлено»). Приложение раз в 20 с (на экране, при связи) и при подключении отправляет изменённые элементы с **текущими** значениями конвертом `DeviceSync` (тег 41, ≤ 500 элементов, ≤ 64 КБ значение); раз в неделю — все (для устройства, которое что-то пропустило). Принимающее применяет элемент, только если его часы новее своих, и сохраняет часы отправителя — эха нет. Стикерпак: файл выкладывается до сообщения, другое устройство докачивает (`device_sync_fetch_packs`). Удаление контакта и разблокировка — тоже элементы. Удаление **чата** не синхронизируется (оно у каждого устройства своё).

**Что куда (настройки):**
- **Общие, синхронизируются:** профиль (имя, фото, «О себе»), отчёты о прочтении, «печатает», «в сети», превью ссылок, входящие звонки, папки и их вид, недавние стикеры и эмодзи, оттенки кожи, отметки «проверен» (`verified:<чат>`), имена моих устройств (`device_name:<ключ устройства>` — каждое называет себя само, запись 218), заблокированные чаты; плюс контакты, заблокированные, флаги чатов, стикерпаки.
- **Копируются один раз при переносе** (стартовая точка; дальше у каждого свои): тема, акцент, обои, язык, вибро, звуки, баннеры в приложении, значок на иконке, что показывать в уведомлениях, «звонки через резервный путь».
- **Только на этом устройстве:** адрес сервера, прокси, обои отдельного чата (`wallpaper:<чат>`, «Инфо» → «Обои»), сколько хранить копии медиа, push и «постоянное соединение», блокировка приложения и «скрывать в переключателе», черновики, непрочитанные, ключи и курсоры. Перенос их не трогает, `DeviceSync` с ними отвергается.

### Честные пределы
- **MLS не расшифровывает прошлое.** Без переноса новое устройство видит только то, что пришло после его добавления (и 200 сообщений истории). Весь «как то же самое» — это перенос с другого моего устройства.
- **Старое устройство потеряно / сломано / без связи — переноса не будет.** Сервер не хранит переписку в читаемом виде, «облачной копии» нет. Что остаётся: 24 слова возвращают аккаунт и чаты (новые сообщения), но не историю. *(С 2026-10-22 — копия в iCloud / Google Диске самого человека, ADR-073: тот же механизм, восстанавливается после входа по 24 словам.)* Если есть хотя бы одно другое моё устройство — перенос можно запустить с него («Отправить всё на это устройство»).
- **Старое устройство должно быть онлайн**, пока собирает и выкладывает части (минуты); медиа, которых нет на сервере, выкладываются, пока оно в сети; после — может уходить.
- Файлы, которых нет **ни на сервере (90 дней), ни на старом устройстве** (чистка копий, ADR-033), не перенесутся — новое устройство скажет, сколько.
- **Исчезающие сообщения не переносятся** (ADR-020 — они должны пропадать, а не размножаться); удалённые у всех — тоже.
- Чаты, в которые новое устройство не добавить (я из них вышел, собеседник ушёл), переносятся **историей для чтения**; писать туда нельзя.
- Синхронизация — «последний пишущий побеждает» по часам устройств: одновременная правка одного и того же на двух устройствах оставит одну.
- Только устройства с этой версией: старое приложение игнорирует `Transfer` / `DeviceSync` (незнакомое тело → «invalid»).

### Alternatives
- **Хранить историю на сервере зашифрованной ключом аккаунта** (как бэкап Signal / WhatsApp) — возможно позже отдельной функцией; сейчас сервер не хранит переписку вовсе, и потерянное устройство — честный предел.
- **Прямой канал устройство → устройство** (локальная сеть / Bluetooth, как перенос в Signal) — быстрее для гигабайтов, но нужно, чтобы оба были рядом и онлайн; через сервер работает, когда старое уже ушло. Можно добавить как ускорение.
- **Ключ переноса из QR-сопряжения:** привязка по 24 словам обходится без QR — тогда ключ передавать не через что. Ключ манифеста идёт внутри MLS (группа только моих устройств), это покрывает оба пути; доверие к новому устройству — сертификат из QR / слов (ADR-027).
- **Копировать сами медиа в перенос** — удвоило бы трафик и место на сервере; ссылки с ключами уже есть, недостающее выкладывается из локальных копий.
- **Синхронизировать снимками целиком** — проще, но затирает одновременные изменения разных элементов и гоняет весь список каждый раз; элементы с часами — точечно.

### Consequences
- **+** Новое устройство получает всю историю, контакты, стикерпаки, папки, настройки чатов, заблокированных, проверенных, профиль; дальше устройства остаются одинаковыми.
- **+** Сервер видит только шифротекст: части, манифест и стикерпаки — как медиа (размеры по Padmé, время загрузки), `Transfer` / `DeviceSync` — как MLS-сообщения в группе одного человека, запечатанные на его ключ. Новое: сервер видит, что один аккаунт **выгрузил пачку блобов и спросил про пачку хэшей** — похоже на перенос; содержимое и число сообщений — нет.
- **−** Трафик и место: вся история один раз через сервер (текст — мегабайты; медиа — только недостающее).
- **−** Схема БД v16 (`sync_clock`), новые теги конверта 40 / 41, новый маршрут сервера `POST /v1/media/touch` (выкладывать сервер вместе с приложением; без него — фолбэк).
- **−** Не проверено на телефонах: перенос между настоящими устройствами (iPhone → iPad, Android → iPhone) и большие истории (гигабайты медиа) — тестами в Rust (парсинг, шифрование, прерывания, потеря части, слияние) и в Dart (цикл, повтор, обновление экранов).

**Дата принятия:** 2026-10-18.

## ADR-066 · Уведомление открывает свой чат; «Ответить» прямо из уведомления (2026-10-19)

### Context
Владелец: «нажатие на уведомление должно открывать этот чат, а не главный экран» и «ответ из уведомления, как в Telegram / WhatsApp». Что было: Android уже клал id чата в уведомление, iPhone — тоже (расширение, ADR-056), но Dart открывал чат, только если список чатов уже загружен: при холодном старте с нажатия (приложение закрыто) список ещё пуст — открывался список чатов. На iPhone нажатие при закрытом приложении приходило раньше Flutter-движка (`pushBridge` ещё нет) и терялось. Пропущенный звонок уведомления не давал вовсе (только строка в чате). Ответа из уведомления не было.

### Decision
**1. Нажатие → чат на любом пути.**
- Dart: `PushSync` → `openChatFromNotification` (`lib/app/navigation.dart`): ждёт навигатор и **ждёт чат в списке** (`waitForChat`, до 12 с — список грузится; новый чат приходит с первой синхронизацией), открывает его поверх того, что на экране (Назад — туда же); тот же чат уже открыт — ничего. Под блокировкой приложения (она — обложка поверх всего, не маршрут) чат открывается под обложкой — после Face ID / кода он на экране.
- Одно нажатие приходит дважды (событие `opened` и `takeOpened` при старте) — второй раз в течение 3 с отбрасывается. Событие, которое пришло, пока его никто не слушает (корневой виджет ещё не построен), `ChannelPushPlatform` хранит для `takeOpened`, а натив забывает свою копию только после ответа Dart.
- iPhone: нажатие до движка (холодный старт) — в `PushBridge.launchOpen`, мост забирает его при создании. Открывает только само нажатие (`UNNotificationDefaultActionIdentifier`), не другие действия.
- Android: без изменений по сути (`ACTION_OPEN_FROM_PUSH` + `chat_id` → `PushBridge.opened`), но копия для `takeOpened` теперь снимается по ответу Dart.
- **Кто написал — в группе (Android):** уведомление группы, которое рисует приложение, теперь «Семья» · «Анна: текст» (при «только имя» — «Анна: Новое сообщение», при «ничего» — без имени), как у расширения iPhone (ADR-056); раньше было только название группы и текст (`withSender`).
- **Пропущенный звонок:** когда приложение не на экране и звонок записан пропущенным (`CallLog.missedLine`), приложение само показывает уведомление «<чат> · Пропущенный звонок» (`maybeNotifyMissedCall`), нажатие — в этот чат. Без звука / архив / заблокирован — тихо; «ничего не показывать» — «Sinhron». Только если приложение в этот момент работает (звонок, на который телефон звонил при закрытом Sinhron, видно строкой в чате при следующем подключении).

**2. «Ответить» из уведомления.**
- **Где есть:** на уведомлениях о сообщениях, которые знают чат: Android — те, что рисует приложение (`Notifications.chatMessage`: «Постоянное соединение», разбуженное Google push), iPhone — от расширения уведомлений и местные. **Нет:** «Уведомления показывают: ничего», **блокировка приложения включена** (ответ обошёл бы Face ID / код), запрос на переписку, чат с заблокированным, простое «Новое сообщение» без чата (ntfy), пропущенный звонок. Решает Dart (`canReplyFromNotification`); iPhone-расширению — поля `reply` и `chats[].q` в контексте (ADR-056).
- **Только на разблокированном телефоне:** iPhone — `.authenticationRequired`, Android — `setAuthenticationRequired(true)`.
- **Текст до Dart — зашифрованным на телефоне:** Android — `SecureStore` (ключ Keystore), iPhone — своя Keychain-запись «только это устройство»; запись `pending-replies` удаляется, как только Dart взял ответ.
- **Отправка — как набранное в чате** (`NotificationReplier.send` → `MessageActions.sendText`): та же MLS-шифровка, та же строка «отправляется → отправлено», та же очередь без связи; ответ = чат прочитан (как в Telegram). Соединение открывается без экрана (`BackgroundConnection.openForReply`) и закрывается после (`closeAfterReply`) — как для push (ADR-057); пока оно открыто, пришедшие сообщения получают уведомления от приложения (сервер видит телефон на связи и push не шлёт) — на iPhone тоже, местными уведомлениями.
- **Android:** `ReplyReceiver` (`RemoteInput`) → `NotificationReplies.handle` в фоне (`goAsync`, ждёт ≤ 25 с): отдаёт ответ Dart (`reply`), если Dart работает, иначе поднимает общий движок без экрана (как `PushWake`) — тот забирает `takeReplies` из `main`. Итог (`replyDone`): отправлено → уведомление убирается; в очереди / нет ответа за 25 с → «Ответ уйдёт, как только Sinhron подключится»; не отправлено → «Ответ не отправлен — откройте чат».
- **iPhone:** категория `sinhron-message` с `UNTextInputNotificationAction` (слова — из контекста, на языке приложения; регистрируется при запуске и при каждой смене контекста). Действие без `.foreground`: iOS будит приложение в фоне (`didReceive response`), `beginBackgroundTask`, ответ — Dart, ждём ≤ 25 с. Если iOS закрывала приложение, Flutter-движок без экрана не стартует (он создаётся со сценой) — ответ остаётся в Keychain и **уходит при следующем открытии Sinhron**, уведомление «Ответ уйдёт, когда вы откроете Sinhron».
- Канал `dev.sinhron/push`: native → Dart `reply {id, chatId, text}` (Dart отвечает true = взял); Dart → native `takeReplies`, `replyDone {id, outcome: sent|queued|failed}`; `showMessage` получил `reply`, на iPhone он теперь тоже есть (местное уведомление).

### Честные пределы
- iPhone, приложение закрыто системой: ответ не уходит сразу — только при следующем открытии (иначе — второй Flutter-движок рядом с тем, что создаёт сцена, на одну БД и одно MLS-состояние).
- «Отправлено» = передано серверу; доставку видно галочками в чате.
- Android подписи кнопок — на языке телефона (ресурсы), не приложения; текст уведомления — на языке приложения.
- Прокрутки к самому сообщению нет: чат открывается внизу, где и есть новое сообщение (в превью push нет id сообщения).

### Alternatives
- **Ответ с открытием приложения (`.foreground`)** — проще и всегда работает, но это не «как в Telegram»; оставлено только для холодного iPhone, и то — через «уйдёт при открытии», без принудительного открытия.
- **Отдельный Flutter-движок без экрана на iPhone** — отправлял бы и при закрытом приложении, но второй движок при открытии сцены = две копии Dart над одной БД и одним Rust-ядром; слишком рискованно.
- **Ответ при включённой блокировке приложения** — Telegram так умеет; у нас блокировка обещает «без Face ID — ничего», поэтому выключено. Можно включить отдельной настройкой.
- **Кто кому отправляет всё (2026-10-26, status 206).** Владелец: на старом телефоне карточка «Переношу всё с другого устройства · Готово — 0 сообщений», на новом — только часть истории, без имени и фото. Причина: новое устройство сделало своё «Избранное» раньше, добавило туда старый телефон и отправило ему свою пустую базу; старый телефон принял эту группу как своё «Избранное» и поэтому сам перенос не начал. Теперь (`sync_devices`): всё идёт **только от более старого устройства к более новому** (по `registered_at` из списка устройств; неизвестно — как раньше), и устройство, уже состоящее в моей группе устройств, но не получавшее всё от этого (настройка `transfer_sent:<устройство>`; привязано не больше 30 дней назад), получает перенос при следующей синхронизации устройств. Ручной «Отправить всё на это устройство» тоже ставит отметку. Карточка приёма по окончании показывает, **сколько сообщений действительно добавилось** (`messages_added`), а не сколько было у отправителя. Имя, фото, «о себе» и прочие синхронные настройки, заданные до v16 (у них не было «часов»), получают самые старые часы (1) при открытии базы (`stamp_unclocked_settings`) и уходят на другие устройства; изменение, сделанное там позже, побеждает.
---

## ADR-070 · Форматирование текста: чистый текст + диапазоны рядом с ним (как Telegram), WYSIWYG в поле ввода, маркеры превращаются по ходу набора (2026-10-19)

### Context
Владелец: «форматирование текста в сообщениях, причём очень, очень хорошее» — не хуже Telegram. До этого `message_text.dart` при показе искал в тексте маркеры `*жирный*` `_курсив_` `` `моно` `` `~зачёркнутый~` `||спойлер||`: маркеры ехали внутри текста, были видны в поиске, в списке чатов, в push, в цитате ответа; поле ввода показывало сырые звёздочки; ни ссылок-словами, ни цитат, ни блоков кода, ни подчёркивания; звёздочку как символ нельзя было написать.

### Decision
- **Передача — диапазоны рядом с текстом**, внутри зашифрованного конверта (`envelope.rs`): `TextEntity { kind, offset, length, url, language }`, смещения — в единицах UTF-16 (как в Telegram и как индексирует Dart). Виды: 1 жирный, 2 курсив, 3 подчёркнутый, 4 зачёркнутый, 5 моно в строке, 6 блок кода (+ язык), 7 спойлер, 8 ссылка-слова (+ адрес), 9 цитата. Поля: `TextBody` 3/4 (`entities`, `rich`), `Edit` 3/4, `MediaBody` 20/21 (подпись; 15–19 оставлены другим), `HistoryItem` 20/21. Сам текст — **чистый**: поиск, список чатов, push, цитата ответа и старые приложения видят обычные слова.
- **`rich`** — «диапазоны — это всё форматирование»: новое приложение ставит его всегда (без форматирования — пустой список), и получатель **не ищет маркеры** — звёздочки, набранные как символы, остаются звёздочками. Без `rich` (0.6.0 и старше) — показ, как раньше: маркеры 0.6.0 читаются (`FormattedText.legacy`).
- **Проверка у получателя** (`clean_entities`, в Rust до Dart): диапазон внутри текста и на границах символов (не половина эмодзи), известный вид, ссылка только на `https://` `http://` `mailto:` `tel:` без пробелов и управляющих символов (≤2048 байт), язык — короткий `[A-Za-z0-9+#._-]`, не больше 1000 диапазонов. Плохое — выбрасывается, текст остаётся. Dart при показе ещё раз обрезает и проверяет (данные с другого моего устройства).
- **Между Rust и Dart, в базе** — JSON `[{"t":"bold","o":0,"l":4},{"t":"link",…,"url":…},{"t":"pre",…,"lang":…}]`: `NetPush.entities_json`, `NewMessageRow` / `StoredMessageSummary.entities_json`, `storage_message_apply_edit(…, entities_json)`, `net_send_message(…, entities_json)`, `net_send_media/photo/video(…, caption_entities_json)`, правка — `"entities"` в action JSON. База v17: колонка `messages.entities_json` (NULL = сообщение старого приложения); удаление для всех её стирает; перенос на новое устройство (ADR-064) и история для нового устройства (ADR-025) её везут.
- **Поле ввода** (`rich_composer.dart`): `RichTextController` хранит стиль каждого символа рядом с текстом и рисует его при наборе (WYSIWYG). Набранное продолжает стиль символа слева (после ссылки — нет, внутри — да), заменённое (автозамена) берёт стиль заменённого. Маркеры превращаются в форматирование **в момент набора закрывающего**, как в Telegram: `**ж**` `__к__` `~~з~~` `||с||` `` `к` `` ```` ```язык\nкод``` ```` `[слова](адрес)`; `> ` в начале строки — цитата, Enter продолжает её, Enter на пустой строке — выход. Внутри кода маркеры не читаются. Меню выделения: «Формат» → Жирный, Курсив, Подчёркнутый, Зачёркнутый, Моноширинный (на несколько строк — блок кода), Спойлер, Ссылка (спрашивает адрес, `ya.ru` → `https://ya.ru`), Цитата, Очистить формат. Клавиатура iPad / Bluetooth: ⌘/Ctrl + B, I, U, ⇧X, ⇧M, ⇧P, K, ⇧. (цитата), ⇧N (очистить). Черновик сохраняет форматирование (в `chats.draft` — метка `U+E070` + JSON; без форматирования — обычный текст, как раньше).
- **В пузыре** (`message_text.dart`): блоки — абзацы, цитата (полоса сбоку, лёгкий фон цвета ссылок), блок кода (моноширинный, язык, «Копировать»); стили вкладываются как угодно. Спойлер — слова невидимы под «пылью» (зерно, медленно плывёт; перерисовка без перекладки текста), касание — пыль расходится от пальца, слова проявляются (0,42 с); с «Уменьшением движения» — пыль стоит, раскрытие сразу. Ссылка-слова, у которых текст не совпадает с адресом, открываются через лист с настоящим адресом и предупреждением. Адреса, телефоны и упоминания в тексте находятся, как раньше, но не внутри кода.
- **Копирование** — системный буфер получает обычный текст; форматирование запоминается в приложении (`RichClipboard`) и возвращается при вставке того же текста в поле ввода Sinhron. Пересылка и «Сохранить в Избранное» несут форматирование; цитата ответа — чистые слова.
- **Вставка Markdown из других приложений** (2026-10-26, status 204): ответ ИИ, скопированный в чат, приходил с `##`, `**`, `-` как символами. Если вставленный текст точно Markdown (`looksLikeMarkdown`: `**…**`, `~~…~~`, `` `…` ``, ```` ``` ````, `# заголовок`, `[слова](https://…)`; одиночные `*…*` и `- ` не считаются), поле ввода сразу превращает его в форматирование (`FormattedText.markdown`): жирный, курсив (`*…*`, `_…_`, `__…__` — как в Sinhron), зачёркнутый, моно, блок кода с языком, ссылка (только https/http/mailto/tel), цитата; чего в Sinhron нет — простым текстом: заголовок → жирная строка, `- пункт` → `• пункт`, `- [ ]` → `☐`, строка таблицы → ячейки через ` · ` (шапка жирная), `---` → `———`. Над полем — «Разметка стала форматированием · Вернуть как было» (`pastedMarkdown`, `revertPastedMarkdown`): возвращает текст как вставлен, исчезает при следующей правке. Внутри блока кода вставка не трогается.

### Alternatives
- **Маркеры в тексте (Markdown)** — отклонено: старые приложения и все места, где текст показывается без разбора (поиск, список чатов, push у получателя, цитата ответа, уведомления от NSE), видят мусор; нужен экран для символов; вложенность и ссылки-словами в Markdown хрупкие.
- **Диапазоны в UTF-8 / в символах (code points)** — отклонено: Dart индексирует UTF-16, Telegram тоже; в Rust проверка границ — по UTF-16 (`len_utf16`).
- **Нативное меню iOS (`SystemContextMenu`) с пунктами формата** — пока нет: приложение уже рисует своё меню (на языке телефона, в тёмной теме — 2026-10-16); пункты формата в нём одинаковы на iPhone и Android.
- **Форматированный буфер обмена (RTF/HTML)** — пока нет: Flutter даёт только текст; нужен платформенный код (tech-debt 2.58).

### Consequences
- **+** Старое приложение (0.6.0) видит у нового чистый текст без звёздочек; новое у старого — как раньше (маркеры).
- **+** Поиск, список чатов, push, цитаты — без мусора; звёздочку можно написать.
- **−** Старое приложение не увидит форматирования нового (только слова) — до обновления.
- **−** Подпись уже отправленного медиа не правится (как и раньше); форматирование подписи — только при отправке.
- **−** Буфер обмена других приложений получает только слова (tech-debt 2.58).
---

## ADR-071 · Заблокировал — ничего не доходит: ключ доступа на каждого собеседника, блокировка = отзыв ключа (2026-10-19)

Расширяет ADR-023 (запечатанные конверты) и ADR-026 (ключ доступа). Пересматривает ADR-029 «блокировка — только на устройстве»: блокировка по-прежнему **не называется серверу**, но сервер теперь перестаёт будить телефон.

### Context
Владелец (2026-10-19): «когда я блокирую человека, с его стороны ко мне на телефон не должно приходить ничего — никакого push». Было не так: приложение отбрасывало сообщения заблокированного **после** доставки, а сервер уже разбудил телефон. На iPhone оставалось тихое «Новое сообщение» (сервер не знает, кто отправил запечатанный конверт; убрать уведомление в расширении можно только с правом Apple `usernotifications.filtering`, его нет), на Android push Google о звонке мог даже зазвонить. Условие: сервер **не должен узнать, кого я заблокировал и кто мои контакты**.

Ключ доступа ADR-026 был **один на аккаунт**: его знали все собеседники, отозвать его для одного человека было нельзя — смена ключа (`Сбросить ключ`) отрезала всех.

### Decision
**1. Свой ключ каждому собеседнику.** `SyncClient::access_key_for(contact)` = SHA-256(`"sinhron-access-key/v2"` ‖ корень ключей доступа ‖ версия ‖ ключ личности собеседника)[..16]. Выводится из секрета аккаунта, поэтому одинаков на всех моих устройствах и ничего не надо хранить или синхронизировать. Себе (моим другим устройствам) — тоже свой ключ по той же формуле.

**2. Сервер хранит набор хэшей, а не список людей.** `PUT /v1/access-keys` (подпись ключом личности, домен `sinhron-access-keys-put-v1:`) — таблица `access_keys(user_pk, key_hash, version, revoked, decided_ms)`, миграция `20261019120000_per_contact_access.sql`. В запросе:
- `add` — хэши ключей, которые я раздаю (все участники моих чатов + я сам). Добавление **никогда не включает обратно** отозванный хэш.
- `decisions` — `{hash, revoked, at_ms}`: блокировка (`revoked = true`) и разблокировка (`false`) с моментом решения. Побеждает более позднее решение (часы — те же, что у синхронизации моих устройств ADR-064, `sync_clock` элемента `blocked:<ключ>`), поэтому устройство, ещё не узнавшее о блокировке или разблокировке с другого моего устройства, не откатывает её.
- Первый такой запрос включает для меня **строгий режим** (`users.access_per_contact`): с этого момента общий ключ ADR-026 для меня больше не принимается. Новая версия ключей (`Сбросить ключ`, отзыв устройства) удаляет активные хэши старых версий, отозванные остаются.
- Сервер видит только хэши: какой хэш чей — не знает (собеседник получает ключ внутри MLS), хэш ключа не превращается обратно в человека.

**3. Раздача — внутри MLS, перед раздачей хэш уже на сервере.** `sync_share_access_key` (при подключении, после синхронизации устройств, после вступления в чат, после блокировки/разблокировки): сначала `PUT /v1/access-keys`, потом ключи: в личном чате — сообщение `Access` (тег 11, как раньше) в чат; в группе — **каждому участнику своё** сообщение `Access`, запечатанное только на его ключ доставки (как `History` в ADR-025: остальные его не получают). Заблокированным ключ не отправляется, и в непринятых запросах на переписку тоже (чат, начатый незнакомым, — пока я его не принял или не ответил; «Принять» отправляет сразу). Метка «уже отправлено» — эпоха + версия + список получателей, так что разблокировка отправляет ключ снова. Получатель хранит ключ как раньше (`access_key:<личность>`): приложение 0.6.0 принимает новый ключ без изменений и пользуется им.

**4. Блокировка = отзыв хэша.** `setBlocked` → `sync_access_reconcile`: хэш ключа этого человека — `revoked`. Разблокировка — `revoked = false` с более поздним временем (ключ тот же, он снова действует; отправляется ещё раз). Без связи — при следующем подключении (решения берутся из локального списка заблокированных и его часов, повтор безвреден).

**5. Что делает сервер с доставкой мне** (когда я в строгом режиме):

| Путь | Ключ | Итог |
|---|---|---|
| `POST /v1/sealed` (без входа) | действующий мой ключ для него | доставлено, push если срочное |
| | **отозванный** | **принято и выброшено молча**: ответ как при успехе, ничего не хранится, push нет |
| | неизвестный / общий старый | отказ (`refused`) → отправитель уходит на путь «запрос» ниже |
| `SealedSubmit` по WS (с входом) | ключ не передаётся | **запрос**: доставлено, **без push**, не считается в значке; не больше 60 в минуту от одного человека одному |
| `Submit` (обычный, по группе) | — | доставлено, **без push** |
| свои устройства (отправитель = я) | — | как раньше |

На WS-пути ключ нарочно **не передаётся**: иначе сервер связал бы хэш с вошедшим отправителем, и отзыв этого хэша выдал бы, кого я заблокировал. Новое приложение отправляет по каждому получателю отдельно: у кого есть ключ — без входа, у кого нет — запросом.

**6. Незнакомые и первая переписка.** Без ключа можно написать только «запросом» — сообщение приходит в приложение (чат-запрос, как раньше), но телефон **не будит**; разбудит следующее сообщение после того, как наши ключи разойдутся (это происходит, как только приложение собеседника откроет чат и подключится). Заблокированный, выбросивший ключ, неотличим от незнакомого — и тоже не будит.

**7. Звонки.** `CallInvite.access_keys` (поле 7, `repeated bytes`) — ключи доступа звонящего ко всем, кого он зовёт. Для каждого приглашённого в строгом режиме: действующий ключ — звонит как раньше (в приложение и push PushKit / Google); **отозванный — приглашение проглатывается**: ни в приложение, ни push, при входе в сеть не повторяется, звонящий слышит гудки до таймаута; ключа нет (незнакомый, старое приложение) — только в открытое приложение, без push. Сервер знает звонящего и вызываемого и без этого, поэтому ключ в приглашении нового о контактах не говорит; что сервер узнаёт о блокировке — см. «Честные пределы».

**8. Совместимость и порядок выкатки.**
- **Сначала сервер, потом приложения.** Новый сервер с телефонами 0.6.0 ведёт себя как раньше (строгий режим включается только запросом `PUT /v1/access-keys`, его шлёт только новое приложение). Новое приложение со старым сервером: `PUT /v1/access-keys` → 404 → работает по-старому (общий ключ), блокировка — только на телефоне, как раньше.
- **Собеседник на 0.6.0, я на новом:** он получает мой личный для него ключ тегом 11 и пишет мне без входа — push работает. Его **звонок** ко мне ключей не несёт, поэтому мой спящий телефон не зазвонит (зазвонит открытое приложение), пока он не обновится. Пока он не получил мой новый ключ, его сообщения идут запросом (без push) — обычно это первые минуты после обновления.
- **Я на 0.6.0, собеседник на новом:** всё как раньше (у меня нет строгого режима; его ключи в приглашении сервер для меня не проверяет).
- **Мои собственные устройства — обновить все.** Старое моё устройство раздаёт общий ключ и затирает им новый у собеседников — их сообщения пойдут запросом (без push), пока новое устройство не раздаст ключи снова.

### Честные пределы
- **Сервер узнаёт о блокировке, только если заблокированный звонит.** Решение «проглотить приглашение» сервер принимает сам, а звонящего он знает (тот вошёл) — значит, в этот момент он видит, что я этого человека заблокировал. Обычный сервер это нигде не записывает. Изменённый сервер, который запоминает, какой ключ показал каждый звонящий, может после такого звонка заметить отзыв этого ключа и тоже понять, кого я заблокировал. Сообщения так не выдают (путь без входа не называет отправителя; IP — как в ADR-026, против этого Tor/VPN).
- **Сервер видит число моих ключей** (≈ число людей, с которыми у меня есть общие чаты, плюс я) и **число отозванных** (≈ сколько я заблокировал), и моменты изменений. Кто именно — нет.
- **Заблокированный в общей группе** по-прежнему участник MLS: его групповые сообщения мне выбрасываются сервером (ключ отозван), но Commit-ы группы (`Submit`) доходят — без push. Читать мои сообщения в группе он может (ADR-029).
- **Без push от незнакомых.** Первое сообщение от человека, ещё не получившего мой ключ, телефон не разбудит. Тихое «Новый запрос» через фоновый push, решаемый на самом телефоне, — tech-debt 2.56.
- **«Принято и выброшено» — отвечает так же**, но по времени ответа (нет записи в базу) внимательный заблокированный теоретически отличит; вывод «меня заблокировали» он может сделать и без этого — ответа нет.

### Alternatives
- **Сообщить серверу список заблокированных** — отклонено: ровно то, что владелец запретил.
- **Отзывать один общий ключ (новая версия) и раздавать всем, кроме заблокированного** (как профильный ключ Signal) — каждая блокировка рассылает ключи всем собеседникам, и пока они не дошли, все пишут без push; а сервер видит «набор сменился на N−1» в момент блокировки. Ключ на собеседника отзывается точечно.
- **Передавать ключ и на WS-пути** — тогда push работал бы и при запасном пути, но сервер связал бы хэш с отправителем, и отзыв выдал бы блокировку. Отклонено.
- **Неизвестный ключ тоже молча выбрасывать** (как было в постановке) — отклонено: тогда сообщения собеседника, у которого ещё старый общий ключ (0.6.0, переход, сброс ключа), терялись бы бесследно. Молча выбрасывается только **отозванный** ключ; неизвестный — отказ и запрос без push.
- **Случайные ключи, хранимые на устройстве** — пришлось бы синхронизировать между моими устройствами; вывод из секрета аккаунта даёт тот же ключ везде.
- **Решать на телефоне по фоновому push** — iPhone обязан показать звонок PushKit, а уведомление без права фильтрации не убрать; без сервера push не остановить.

### Consequences
- **+** Заблокированный не будит мой телефон ничем: сообщения без входа выбрасываются сервером молча, запасные пути (WS, обычный `Submit`) не дают push, его звонок не доходит ни в приложение, ни в push. На iPhone больше нет «Новое сообщение» от заблокированного, Android не звонит.
- **+** Сервер не получает список заблокированных и контактов: только хэши без имён.
- **+** Групповые звонки от заблокированного тоже не звонят (раньше ADR-029: «не отклоняются»).
- **−** ~~Первое сообщение незнакомого и сообщения до обмена ключами не будят телефон.~~ Дополнено: тихий «Новый запрос», решает телефон (ниже).
- **−** ~~Звонок от собеседника со старым приложением (0.6.0) не будит мой спящий телефон, пока он не обновится.~~ Дополнено: будит на время перехода (ниже).
- **−** Новый маршрут сервера и миграция; сервер выкатывать **до** приложения.
- **Проверено:** серверные тесты на настоящем Postgres (строгий режим, молчаливый выброс, LWW решений, версия, запрос без push, проглоченный звонок), Rust (вывод ключей, подпись запроса), Dart (блокировка вызывает отзыв) и сквозной пример `examples/block_e2e.rs` через настоящий локальный сервер. На телефонах не проверено.

### Дополнено 2026-10-19 (status 177): тихий «Новый запрос» и звонки со старых приложений
Владелец — до выпуска 0.7.0: (1) первое сообщение незнакомого всё же должно давать знать о себе, но так, чтобы заблокированный не мог этим пользоваться; (2) звонки от приложений 0.6.0 должны звонить на телефон с 0.7.0, пока все не обновятся.

**1. Push о запросе — без содержимого, решает телефон.**
- Сервер на «запрос» (доставка без ключа по WS `SealedSubmit`, срочная) шлёт `PushMessage::Request` — не «Новое сообщение»: без текста, без счётчика, без звука. С ним идёт только запечатанное превью отправителя (ADR-056: кто, какой чат — внутри, открывает только мой телефон). Не чаще раза в 10 минут от одного отправителя одному и 10 в час одному человеку (`SINHRON_RATE_REQUEST_PUSH_PAIR` / `SINHRON_RATE_REQUEST_PUSH`); само сообщение доходит в любом случае. Обычный `Submit` без превью push о запросе не даёт.
- **iPhone — фоновый push** (`apns-push-type: background`, `content-available`, приоритет 5, `"r":1` + превью). iOS сам ничего не показывает; просыпается приложение (`AppDelegate … didReceiveRemoteNotification`), открывает превью теми же ключами, что расширение уведомлений, и решает (`RequestNotice` в `ios/Shared/PushShared.swift`): отправитель заблокирован или превью не открылось → **ничего**; чат уже принят → обычное уведомление «Имя: текст»; иначе одно тихое «Новый запрос на переписку» без имени и текста (по нажатию — этот чат, если он уже есть). **Почему не через расширение уведомлений:** расширение без права Apple `usernotifications.filtering` не может убрать уведомление — заблокированный получил бы хотя бы тихую строку. Цена: фоновые push iOS не доставляет приложению, смахнутому из переключателя, и может придерживать — тогда запрос просто виден при следующем открытии.
- **Android — `{"t":"req"}`** (FCM и ntfy, запечатано ключом телефона). Приложение подключается, получает сообщение (от заблокированного оно отбрасывается, как всегда) и в непринятом чате рисует одно тихое «Новый запрос на переписку» на своём канале без звука (`Notifications.CH_REQUESTS`); в принятом — обычное уведомление. Запасного «Новое сообщение» для запроса нет.
- Сервер не узнаёт, кто кого заблокировал: push о запросе уходит одинаково и незнакомому, и заблокированному; решение — на телефоне.

**2. Звонки со старых приложений — правило перехода.**
- Проверить «дал ли этот человек звонящему свой ключ», не узнав граф контактов, сервер не может: это ровно связь «ключ ↔ человек», которую он не должен знать (солёный хэш личности сервер посчитал бы для всех известных личностей сам). Поэтому правило — по версии приложения звонящего и на стороне телефона:
- Новое приложение ставит в приглашении `CallInvite.sends_access_keys = true` (поле 8) — всегда, даже без ключей. Без ключа такое приглашение доходит только в открытое приложение (как раньше в ADR-071). **Приглашение без этого поля — от приложения старше 0.7.0 — будит телефон как до ADR-071**, если сервер не выключил переход (`SINHRON_LEGACY_CALL_PUSH`, по умолчанию включён; выключить, когда все обновятся). Отозванный ключ проглатывает приглашение в любом случае. **2026-10-26 (KISS):** переключатель `SINHRON_LEGACY_CALL_PUSH` убран — приложений старше 0.7.0 нет; приглашение без ключа доходит только в открытое приложение.
- **Телефон сам не звонит заблокированному.** Android: сервер кладёт ключ звонящего (`"c"`) внутрь зашифрованного ключом телефона push (Google и ntfy видят шифротекст; тело дополнено до 256 байт, сообщение, запрос и звонок одного размера); `Fcm.kt` / ntfy-приёмник сверяют его со списком заблокированных, который приложение отдаёт нативу (`setNotificationContext`, теперь и на Android), и не звонят. iPhone: PushKit обязан показать звонок, поэтому, как и раньше (ADR-056), метка чата находит личный чат с заблокированным, и звонок сразу завершается без звонка; в групповом звонке от заблокированного со старого приложения iPhone может коротко показать звонок — до его обновления.
- Изменённый клиент может притвориться старым (не ставить поле) — это даёт ему только то, что умел 0.6.0, а телефон всё равно сверяет звонящего. Когда переход выключен, без ключа — только открытое приложение.

**Проверено (дополнение):** сервер — запрос даёт `Request`-push (один раз в 10 минут), заблокированному запросу — тоже только `Request` (решает телефон), приглашение старого приложения будит, нового без ключа — нет, отозванный ключ проглатывается; тела FCM одного размера; фоновый APNs; Swift — `RequestNotice` (тесты `ios/SharedTests` через `swiftc`) и проверка типов `ios/Runner`; Kotlin — сборка `compileDebugKotlin`; Dart — тихое уведомление в непринятом чате. На телефонах не проверено.

**Дата принятия:** 2026-10-19.

### Amendment 2026-10-19 (запись 181) — переходный режим и для сообщений
~~`SINHRON_LEGACY_MESSAGE_PUSH` (по умолчанию включён): старый общий ключ доставляет с push, запасные пути (WS, `Submit`) будят как до ADR-071; отозванный личный ключ — по-прежнему молча выбрасывается.~~ Убран 2026-11-04 (ADR-087). Без этого после 0.7.0 сообщения от своих с 0.6.0 (и от 0.7.0, пока личный ключ не дошёл) становились тихими «запросами» и не будили спящий телефон. Выключить вместе с `SINHRON_LEGACY_CALL_PUSH`, когда все обновятся.

---

## ADR-072 · Сервер находится, даже когда DNS телефона врёт: проверенный адрес, DNS-over-HTTPS и запомненный IP (2026-10-22)

Дополняет ADR-032 (адрес сервера вводится) и WU B3 (TLS pinning). Ничего не ослабляет: сертификат проверяется как раньше.

### Context
2026-10-22 (запись 186): из сети одного провайдера `chat.777400777.xyz` резолвится в **80.179.79.171** — хост Partner с чужим сертификатом, а Cloudflare 1.1.1.1, Google 8.8.8.8, Quad9 и Яндекс отдают наш 176.124.223.138. Проверка TLS правильно отказывает чужому хосту — и приложение пишет «нет соединения с сервером». То же у любого, чей роутер или провайдер подменяет / блокирует ответ DNS; возможно, это и часть жалоб «с VPN нет соединения».

### Decision
**1. Резолвер наших хостов — `sinhron_net::dns`.** «Наши» — хосты https/wss-адресов сервера: API и WebSocket (`HttpApi::new`, `WsClient::start`), LiveKit (`livekit_url` из токена звонка), адрес, который человек ввёл при проверке сервера (`net_dns_add_our_host`). Plain http/ws (разработка), IP и чужие хосты (превью ссылок) — системный резолвер, как раньше.

**2. Порядок для нашего хоста:**
1. **Системный ответ, проверенный:** TCP + TLS-рукопожатие к нему с SNI и проверкой сертификата на наше имя (те же корни webpki, что у настоящих соединений; при pinning — операторский CA). Прошёл → используется и запоминается: пока система отдаёт тот же адрес, проверки больше нет (сутки).
2. Не прошёл (чужой сертификат, нет соединения, нет ответа) → **адрес, проверенный раньше**, проверяется снова — без запроса в DoH.
3. Ничего → **DNS-over-HTTPS:** Cloudflare `https://1.1.1.1/dns-query`, потом Google `https://8.8.8.8/resolve` (JSON, по IP — DNS для них не нужен; A и AAAA вместе); каждый ответ проверяется так же. Прошедший запоминается.
4. Ничего не прошло (нет сети, сервер лежит) → возвращается системный ответ **без проверки** — настоящее соединение откажет на TLS, как раньше. 30 с после такой неудачи полная проверка не повторяется.

**3. Меняется только адрес.** Соединение идёт на проверенный IP, а TLS — с SNI и проверкой сертификата на **наше имя**: reqwest (`dns_resolver`), WebSocket (`connect_wss`: TCP к адресу + `client_async_tls_with_config` с именем из URL), Dart (`SecureSocket.secure(host: наше имя)`). Чужой сертификат не принимается ни на одном пути; адрес, на котором настоящее соединение не прошло TLS, выбрасывается (`note_bad`).

**4. Память.** Проверенные адреса — в зашифрованной таблице настроек (`settings`, ключ `net_dns_cache`, JSON `{v, hosts:{host:{ips, via, at, ttl}}}`), загружаются при открытии базы (`storage_init`). Не синхронизируется между устройствами. Адрес из DoH / запомненный используется сразу: без проверки — DNS-TTL (5 мин…1 ч), дальше — ещё до недели, с **проверкой в фоне** (не чаще раза в 5 мин), которая возвращается к системному ответу, как только он снова верный.

**5. Dart — `lib/core/server_dns.dart`.** `HttpOverrides.global = ServerDnsOverrides(...)` первым делом в `main()`: у каждого `HttpClient` свой `connectionFactory`; для нашего хоста он спрашивает Rust (`net_dns_override`) — IP возвращается **только** если системный ответ доказанно неверный (DoH / запомненный), иначе обычное соединение. Так идут сигнализация LiveKit (`io.WebSocket.connect` и `/rtc/validate` через `package:http`), скачивание APK, проверка сервера.

**6. Звонки.**
- **LiveKit:** сигнализация (WebSocket) — через п. 5. Медиа к SFU идёт по ICE-кандидатам с IP узла — DNS не нужен.
- **TURN:** WebRTC резолвит хосты TURN сам, системным резолвером. Если для хоста `turn:` / `stun:` (у нас это хост API) системный ответ неверный, Rust добавляет в список копию URL с проверенным IP (`turn_urls_with_checked_ips`): TURN проверяется паролем, а медиа и так сквозь SFrame. **`turns:` так нельзя** — TLS на 443 нужен с именем (Caddy layer4 маршрутизирует по SNI), поэтому `turns:` остаётся с именем: резервный путь звонка при подменённом DNS для `turn.` не поможет (tech-debt 2.60).

### Честные пределы
- **DoH раскрывает имя хоста Cloudflare / Google** — только когда системный ответ не прошёл проверку (threat-model §5 #23). IP телефона они тоже видят.
- **Провайдер может блокировать и 1.1.1.1 / 8.8.8.8** — тогда спасает только адрес, запомненный раньше. Свой список IP от сервера (в `/v1/push/info` или подписанном конфиге) — не сделан (tech-debt 2.60).
- **Лишнее рукопожатие:** первая проверка — одно TLS-рукопожатие на хост (~0,1–0,3 с) раз в сутки или при смене ответа системы; при подмене — ещё DoH и проверка (обычно < 1 с).
- **IPv6-only сеть с NAT64:** IPv4-адрес из DoH напрямую там может не открыться (iOS синтезирует адрес только через системный резолвер) — пока не обработано.

### Alternatives
- **Вшить IP сервера в приложение** — отклонено: адрес сервера вводит человек (ADR-032), сервер может переехать.
- **Всегда ходить через DoH** — отклонено: имя хоста каждый раз уходит Cloudflare / Google, хотя у большинства системный DNS верный.
- **Повторять запрос при ошибке TLS** вместо проверки до соединения — у reqwest нет хука на ошибку TLS по адресу, тело загрузки (поток) не повторить; проверка в резолвере проще и покрывает все запросы.
- **DoH по протоколу DNS wire (RFC 8484)** — JSON-ответ у обоих сервисов одинаковый и не требует разбора DNS-пакетов.
- **Принимать сертификат провайдера / отключить проверку** — никогда.

### Consequences
- **+** Сеть с подменённым DNS (провайдер): приложение подключается, сообщения, медиа, push-регистрация, сигнализация звонков и обновление APK работают; адрес помнится между запусками.
- **+** Пока системный DNS верный — поведение прежнее, в DoH ничего не уходит.
- **−** Новые зависимости `sinhron_net`: reqwest, tokio-rustls, webpki-roots, serde (уже были в сборке через `sinhron_sync` / tokio-tungstenite — те же версии, размер почти не растёт).
- **−** `turns:` (резервный путь звонков) при подменённом DNS хоста `turn.` не работает.

**Дата принятия:** 2026-10-22.

---

## ADR-073 · Копия переписки в облаке самого человека: iCloud на iPhone, Google Диск на Android (2026-10-22)

Дополняет ADR-064 (перенос на новое устройство — тот же механизм) и ADR-027 (пакет связанного устройства теперь несёт ключ копии).

### Context
Владелец (2026-10-22), после разбора проекта: «бэкап на гугл аккаунте или айклауд, там хранится должно и без трудной настройки пользователя»; на предложение «до 25 МБ на нашем сервере» — «нужно надёжнее, 25 МБ не хватает». Было: история живёт только на устройствах (§6.8); потерял единственный телефон — потерял всю переписку; ADR-064 переносит историю только со **своего живого** устройства. Условия: ни Apple, ни Google, ни наш сервер не читают копию; на iPhone — без настройки; без ограничения размера нашим сервером.

### Decision
**1. Где.** iPhone — iCloud Drive, свой скрытый контейнер приложения `iCloud.com.sinhron.sinhron`, папка `Documents/Backup` (нет в «Файлах»; iOS выгружает сама, по Wi-Fi, если «iCloud Drive по сотовой» выключено). Ничего нажимать не надо, если iCloud Drive включён. Android — Google Диск, папка данных приложения `appDataFolder` (скрыта в Диске, видна только этому приложению), после одного «Войти через Google» (`Identity.getAuthorizationClient`, область `drive.appdata`, `BackupBridge.kt`); загрузку делает Dart через REST Диска (возобновляемая загрузка, любого размера). Ежедневная копия на Android ждёт Wi-Fi; «Создать копию сейчас» — сразу.

**2. Что и как.** Тот же перенос ADR-064 с папкой вместо сервера: части (заголовок + сообщения; каждая — свой AES-256-GCM-ключ, размер по Padmé), файлы стикерпаков, медиа (локальные копии ADR-033, уже зашифрованы своими ключами) — всё названо SHA-256 шифротекста. То, что в переносе шло через MLS (ключ манифеста), — в один маленький `root.sinhron` (`SNBR` v1, AES-256-GCM, AAD `sinhron-chat-backup-root-v1`), запечатанный **ключом копии**: `cloud_backup_key` = HKDF(`backup_key`, `"sinhron-cloud-backup/v1"`) — из 24 слов, одним шагом ниже ключа серверной копии состояния. Rust (`sinhron_sync::backup`, `api/backup.rs`) пишет файлы в папку на телефоне (`DirTransport`), Dart (`backup_service.dart`) переносит их в облако: по ~32 МБ за раз (мало места на телефоне), корень — последним (корень в облаке всегда указывает на файлы, которые там есть), потом удаляет то, что старые копии этого устройства оставили (список `backup_keep`). Прерванная копия продолжается с того же места. Медиа уходят **один раз** (имя = содержимое); части сообщений собираются заново каждый раз.

**3. Каждое устройство — своё имя.** Файлы лежат как `<метка>-<имя>`; метка (16 hex) — SHA-256 сертификата устройства (у связанного) или ключа личности (у устройства с ключом аккаунта), ни о чём не говорит. Так iPhone и iPad на одном Apple ID, или два человека с разными аккаунтами на общем Apple ID / Google, не стирают копии друг друга. Корень, который эти слова не открывают (чужой аккаунт), не трогается никогда. Копия другого моего устройства, не обновлявшаяся больше 30 дней, удаляется после очередной успешной копии этого устройства (корень первым).

**4. Когда.** Раз в сутки (`BackupKeeper`: через минуту после запуска и при каждом уходе в фон / возвращении, если прошло 24 ч), выключается в Настройки → «Резервная копия» → «Копия каждый день». Пока идёт перенос на другое устройство (ADR-064), копия ждёт (общие части); перенос, начатый посреди копии, сбрасывает её — следующая начнётся заново.

**5. Восстановление.** Сразу после входа по 24 словам на новом телефоне: iPhone сам смотрит в iCloud и, если копия есть, спрашивает «Восстановить переписку? Копия от …: сообщений — N, чатов — M, медиафайлов — K»; Android сначала спрашивает «Найти копию в Google Диске?» → «Войти через Google». Берётся самая новая копия, которую эти слова открывают. Сообщения, контакты, настройки, стикерпаки — слиянием, как в ADR-064 (дубли отбрасываются), затем медиа в локальные копии (по 20). То же — Настройки → «Резервная копия» → «Восстановить из копии».

**6. Ключ на связанных устройствах.** До этого ADR связанное устройство (QR или 24 слова — ADR-027) не хранило ничего, что открывает копию: оно не могло бы ни делать копию, ни восстанавливать — а после восстановления новый телефон и есть связанное устройство. Теперь пакет `sinhron-linked:v1:` может нести на 32 байта больше — `cloud_key` (`LinkedBundle::cloud_key`); пакеты из 24 слов и из QR (`linked_bundle_for`) его несут. Ключ базы данных связанного устройства считается **без** этих 32 байт — база открывается как раньше. Устройство со старым пакетом видит «Включить копию на этом устройстве» → 24 слова один раз → тот же пакет с ключом (`chat_backup_unlock`; слова другого аккаунта — отказ; сами слова не сохраняются).

### Честные пределы
- **Apple / Google видят** число и размеры файлов (с точностью до Padmé), время загрузок и удалений, что это приложение Sinhron, и метки устройств (без смысла). Не видят содержимого, чатов, людей, числа сообщений. Кто получит доступ к iCloud / Google человека, получит только шифротекст — без 24 слов он бесполезен; **кто получит и 24 слова** (например, они в «Паролях» того же Apple ID, ADR-059), получит всю переписку — копия не слабее слов.
- **Связанное устройство теперь хранит ключ копии** (в Keychain / Keystore, как и весь пакет). Кто вытащит его из устройства и получит доступ к облаку человека, прочтёт копию — но с этого устройства он и так читает всю переписку. Ключ серверной копии состояния и ключ личности на связанные устройства по-прежнему не попадают.
- **Части сообщений выгружаются каждый день целиком** (у большой истории — десятки МБ в сутки по Wi-Fi); переиспользуются только неизменившиеся (одинаковый шифротекст бывает редко — ключи свежие). Медиа — один раз.
- **Копия — история, не членство в группах.** Восстановленные чаты показывают историю; писать в группу новое устройство может, как и раньше, когда его туда добавит другое моё устройство или участник (ADR-025/027). *С 2026-10-23 (ADR-074) участники добавляют его сами, когда появляются в сети.*
- **Медиа без локальной копии** (старые, загруженные до ADR-033 и уже удалённые сервером) в копию не попадают (`media_missing`).
- **iCloud выключен** — копии нет, экран говорит, где включить. **Android без Google Play** — копии нет.
- **Двух человек на одном Apple ID** приложение различает по ключу; копия каждого — только его.

### Alternatives
- **Копия на нашем сервере** (до 25 МБ) — владелец отказал: мало; и сервер стал бы хранилищем всей истории.
- **CloudKit (приватная база)** вместо iCloud Drive — тот же уровень, но отдельная схема и квоты записей; файлы проще и переиспользуют ADR-064.
- **Google Drive через `google_sign_in` / `googleapis` на Dart** — лишние пакеты; нативный `AuthorizationClient` (тот же Play services, что у «Паролей» ADR-059) + REST в Dart — меньше зависимостей.
- **Одна общая копия на аккаунт** (без меток) — два устройства на одном Apple ID чистили бы файлы друг друга, два аккаунта затирали бы один `root.sinhron`. Отклонено.
- **Хранить в связанном пакете сам `backup_key`** — отдал бы связанным устройствам и ключ серверной копии состояния; дочерний ключ закрывает только облачную копию.

### Consequences
- **+** Потерянный телефон больше не значит потерянную переписку: 24 слова → чаты из iCloud / Google Диска.
- **+** Ни Apple, ни Google, ни наш сервер копию не читают; размер ограничен только облаком человека.
- **−** Владельцу: в Apple Developer — iCloud у App ID `com.sinhron.sinhron` с контейнером `iCloud.com.sinhron.sinhron` (Xcode с автоподписью, вероятно, включит сам при сборке); в Google Cloud (проект `sinhron-fd4e2`) — включить Google Drive API, экран согласия OAuth, Android-клиент OAuth (пакет `com.sinhron.sinhron` + SHA-1 ключа подписи релиза). Без этого на Android «Войти через Google» не сработает.
- **−** Swift и Kotlin этой части здесь не собираются — проверка сборкой на Маке и на телефонах.

**Дата принятия:** 2026-10-22.

## ADR-074 · Потерял телефон — собеседники сами добавляют новый в общие чаты (2026-10-23)

Дополняет ADR-025 (несколько устройств), ADR-027 (связанные устройства) и ADR-073 (копия переписки): после восстановления у нового телефона есть история, но не было членства в чатах.

### Context
Владелец (2026-10-23), про копию переписки: «сделай, чтобы в группу также добавлялось». Было: новое устройство попадает в чаты MLS, только если его добавит **другое моё устройство** (`sync_devices` смотрит только мои устройства). Потерял единственный телефон → новый никто не добавляет: чаты (личные и группы) после входа по 24 словам есть только как история из копии, писать и получать в них нельзя, пока кто-то не пригласит заново. Ещё две дыры по ходу: (1) телефон публикует **один** KeyPackage за запуск, а каждое добавление в чат тратит один — новый телефон за раз попадал бы в один чат; (2) мои устройства добавляли «моё новое устройство» по KeyPackage от сервера **без проверки, что он мой** — сервер мог подсунуть чужой ключ, и мой телефон сам добавил бы постороннего во все мои чаты.

### Decision
**1. Добавляет любой участник.** В синхронизации устройств (раз в 5 мин в открытом приложении и при подключении) — второй проход: для каждого чата, где я есть, для каждого **другого** участника — его активные устройства с сервера (не отозваны, были в сети за 30 дней, зарегистрированы больше 10 минут назад — сначала его собственные устройства, и меньше гонок), список держится 10 минут. Каких нет в чате — KeyPackage только для них, один ожидающий Commit на всех, сервер упорядочивает (ADR-022; проиграл гонку — в следующий раз), объявление группы, один Welcome каждому человеку на его новые устройства. Истории не шлём — она его (копия ADR-073 или его устройства). Не больше 20 чатов за проход.

**2. Проверка: только устройство того же человека, который уже в чате.** `GroupHandle::add_devices_of_pending`: у каждого KeyPackage — действительный сертификат устройства именно того человека, для которого его просили, и у этого человека уже есть лист в группе. Иначе пакет выбрасывается (остальные идут); так сервер не может ни добавить нового человека, ни подменить «устройство Боба» устройством Кэрол. То же теперь и для моих устройств (раньше проверки «это мой» не было).

**3. «Добавили обратно» — не запрос.** Welcome, которым устройство вошло, — от **другого** человека, а в чате уже есть ещё одно моё устройство (лист потерянного телефона) → я там был, чат не становится «запросом на переписку» (`added_back_by_someone_else`, отправитель Welcome — `StagedWelcome::welcome_sender`). Welcome от моего же устройства признаком не считается: чужой запрос на новом моём устройстве остаётся запросом.

**4. Запас KeyPackage.** Один раз на устройство после входа — 20 KeyPackage (`sync_publish_keypackages`, настройка `kp_stock_v1`; неиспользованные истекают через 30 дней); после каждого Welcome — ещё один взамен потраченного.

**5. «Избранное» из копии.** Группа «Избранного» — только мои устройства; если старого телефона нет, новый туда никто не добавит. Если это устройство не в группе «Избранного», а других моих устройств в сети не было 48 часов, создаётся новая группа, и все заметки переносятся в неё (`chat_merge_into`); иначе ждём — другое моё устройство добавит это (`SavedMessages.repair`, после восстановления и после синхронизации устройств).

### Честные пределы
- **Добавят, когда собеседник откроет приложение.** Новый телефон попадает в чат с Аней, когда Анин телефон в сети (приложение открыто, раз в 5 минут) и прошло 10 минут с регистрации нового телефона. Пока никто из чата не появился — чат только для чтения. Сообщения, отправленные до добавления, новый телефон не прочитает (MLS) — они есть в копии, если она свежее.
- **Сервер может придержать.** Не показать новое устройство в списке или не отдать KeyPackage — устройство не добавят (как и раньше с моими устройствами). Показать в списке **отозванное** устройство как активное — его добавят обратно мои собеседники; против этого — отзыв на сервере, как и прежде (тот же уровень доверия, что у синхронизации моих устройств).
- **Потерянный телефон остаётся в чатах, пока его не отозвать** (Настройки → «Устройства»): собеседники только добавляют, не удаляют. Отозванный убирает из каждого чата первое моё устройство, попавшее туда.
- **Гонки** — несколько собеседников могут одновременно попытаться добавить одно устройство: сервер принимает один Commit, остальные выбрасываются; потраченный зря KeyPackage — из запаса.
- **Сервер видит**, что участник группы добавил в неё устройство другого участника (как и раньше видел добавления) — нового о людях из этого не следует.

### Alternatives
- **External Commit (новое устройство само входит в группу по GroupInfo)** — без участия собеседников, но серверу нужно хранить GroupInfo каждой группы после каждого Commit, а участникам — правила, кого пускать; большая переделка протокола.
- **Восстанавливать MLS-состояние старого телефона из серверной копии (§6.8.1)** — два устройства с одним листом и старой эпохой; небезопасно и не работает после смены эпохи.
- **Просить собеседника пригласить заново вручную** — то, что было; теряются группы, где некому догадаться.
- **«Последний» KeyPackage (RFC 9420 last resort)** вместо запаса — правка сервера и клиента; запас из 20 + пополнение решают задачу без протокола.

### Consequences
- **+** Потерял телефон → вошёл по 24 словам → восстановил копию → собеседники, появляясь в сети, возвращают новый телефон во все общие чаты и группы; чаты остаются своими, не «запросами».
- **+** Мои устройства больше не добавят «моё» устройство, если сервер подсунул чужое.
- **−** Каждый открытый телефон раз в 10 минут спрашивает сервер о списке устройств своих собеседников (по одному запросу на человека).
- **Проверено:** юнит-тесты (добавление чужого нового телефона, отказ чужим пакетам, «добавили обратно»), `examples/restore_e2e` через настоящий сервер (Боб потерял телефон, Аня добавляет новый, сообщения в обе стороны). На телефонах не проверено.

**Дата принятия:** 2026-10-23.

- **Восстановление на уже привязанном устройстве (2026-10-26, status 207).** Владелец: сделал свежую копию на старом телефоне, восстановил на новом — новых сообщений нет. Возможные причины по коду: «самая новая копия» выбиралась среди всех устройств, включая само это (а оно делает свою копию раз в сутки — в ней только то, что уже здесь); iCloud ещё не доставил файл, а приложение видело только скачанное; «Создать копию сейчас» доделывала прерванную старую копию со старыми сообщениями; «восстановлено» писалось и при 0 добавленных. Теперь: `find()` берёт самую новую копию **другого** моего устройства (свою — только если других нет: переустановленный главный телефон); ручной «Создать копию сейчас» начинает свежий снимок (`reset`), ежедневная — продолжает начатую; после восстановления — «добавлено сообщений — N» или «в копии нет ничего нового»; iPhone спрашивает у iCloud список файлов (`NSMetadataQuery`, до 10 с) и начинает скачивать «корни», которых ещё нет здесь, а после копии проверяет, забрал ли iCloud файл («Ещё загружается в iCloud…» под «Последняя копия»).
---

## ADR-075 · Новый телефон сам входит в чаты по «карточке чата»; отключённый телефон отключён для всех (2026-10-23)

Дополняет ADR-074 (собеседники добавляют новый телефон), ADR-073 (копия переписки), ADR-025 / ADR-027 (устройства и их отзыв).

### Context
После ADR-074 у потерявшего телефон остались два хвоста (tech-debt 2.61): (1) новый телефон попадает в чат, только когда кто-то из участников **откроет приложение** — в чате, где все молчат неделями, новый телефон неделю только читает; (2) **потерянный телефон остаётся в чатах**, пока его не отзовут, а отозвать его с нового телефона после входа по 24 словам можно было только в «Устройствах», где об этом надо догадаться; собеседники его не убирали — сервер мог бы «отозвать» что угодно, проверить было нечем. Кроме того, первое устройство (его ключ — ключ аккаунта) после отзыва всё ещё входило по WS.

### Decision
**1. Карточка чата.** После каждой смены состава (эпохи) устройство участника кладёт на сервер «карточку» чата — MLS GroupInfo: дерево с публичными ключами устройств и внешний ключ эпохи; **без сообщений и имён**. `PUT /v1/groups/{id}/card`: подпись ключом этого устройства (`GROUP_CARD_PUT_DOMAIN`, тело = group_id ‖ be8(epoch) ‖ карточка), устройство должно быть в группе, карточка старше упорядоченной сервером эпохи — 409, до 256 КБ. Одна карточка на эпоху (клиент помнит, какую уже клал).

**2. Новый телефон входит сам (MLS external commit).** Чат, который есть на телефоне только из копии (нет MLS-состояния), телефон пытается открыть по карточке: `POST /v1/groups/{id}/card` (подпись ключом устройства, `GROUP_CARD_GET_DOMAIN`) — сервер отдаёт её **только** активному устройству человека, у которого есть устройство в этом чате или было там и отключено (`group_former_devices`). Дальше external commit, упорядоченный сервером как любой Commit; отказ (кто-то успел раньше) → состояние выбрасывается, следующая попытка — со свежей карточки, не чаще раза в 30 минут на чат. Нет карточки — ждём, пока добавят участники (ADR-074).

**3. Кого пускают по карточке.** `GroupHandle::join_by_card` — только если в группе уже есть **другой лист этого же человека** (чат, где я был). Участники, получив external commit, применяют его, только если вошло устройство человека, у которого уже есть лист в чате. Сервер принимает такой Commit (и **только** Commit) от человека, чьё отключённое устройство было в чате. Посторонний с карточкой не входит ни у себя, ни у участников.

**4. Отключение с подписью — видно всем.** Отзыв устройства хранит подпись ключом аккаунта (`devices.revoke_proof`, `revoke_proof_ts`; `DEVICE_REVOKE_DOMAIN`, тело = device_pk); `GET /v1/devices?revoked=1` отдаёт отозванные с подписью. Телефоны собеседников при синхронизации устройств проверяют подпись **сами** (`revocation_is_signed`) и убирают такие листы из общих чатов одним Commit — но **никогда последний лист человека** (его новый телефон ещё должен войти по карточке, а участники пускают только пока человек в чате). Свои отозванные устройства убирает, как и раньше, другое моё устройство. Отключённое первое устройство больше не входит по WS (403).

**5. «Ваши другие устройства» сразу после 24 слов.** Устройство, восстановленное по словам, ключ аккаунта не хранит (ADR-027) — отключить потерянный телефон можно, только пока слова под рукой. Поэтому сразу после входа по словам — шторка со списком других устройств (имя, когда были в сети) и «Отключить» у каждого; «Готово» — дальше, без нажатия ничего не отключается (`old_devices_sheet.dart`).

### Честные пределы
- **Карточка — публичная часть группы**: сервер и так знает, какие устройства в каких группах (`group_members`); из GroupInfo он видит ещё публичные ключи и эпоху. Содержимого и имён в ней нет.
- **Сервер может придержать**: не отдать карточку или не показать отзыв — тогда работает путь ADR-074 (добавят участники) и ручной отзыв в «Устройствах».
- **Сервер вместе с украденным отключённым телефоном** мог бы провести его обратно по карточке (участники пускают устройство человека, который уже в чате); при следующей синхронизации телефоны собеседников снова уберут лист с подписанным отзывом — кроме последнего листа человека.
- **Сообщения между копией и входом** новый телефон не прочитает (MLS) — как и в ADR-074.
- **Сервер должен быть обновлён** (миграция `20261023120000_group_cards.sql`); со старым сервером карточек нет — остаётся ADR-074.

### Alternatives
- **Только ADR-074 (ждать участников)** — неделя «только чтение» в тихих чатах.
- **Сервер сам убирает отозванное устройство из групп** — сервер не может делать Commit в MLS; и собеседники не должны верить серверу на слово, кого отключили.
- **Хранить на сервере MLS-состояние телефона** — две копии одного листа, небезопасно (как в ADR-074).

### Consequences
- **+** Потерял телефон → вошёл по 24 словам → в той же шторке отключил старый → новый сам входит во все чаты, даже если все собеседники офлайн; старый пропадает из чатов у всех, по подписи самого человека.
- **+** Отключённое первое устройство не подключается к серверу.
- **−** Каждый участник после смены состава кладёт карточку (одна загрузка на эпоху, ~0,6 КБ на устройство в чате).
- **Проверено:** юнит-тесты (вход по карточке при спящих участниках, отказ постороннему у себя и у участника, отзыв считается только с подписью), сервер `a_lost_phone_is_cut_off_with_a_proof_and_its_person_gets_the_card`, `a_cut_off_devices_person_rejoins_by_commit_only`; `examples/rejoin_e2e` через настоящий сервер. На телефонах не проверено.

**Дата принятия:** 2026-10-23.

---

## ADR-076 · iPad — нормальный клиент: две колонки во всех вкладках, окошки вместо шторок, клавиатура (2026-10-24)

Заменяет решение 2026-10-18 (чаты рядом со списком только от 900 pt, `_SplitChats`).

### Context
Владелец: «сделать, чтобы клиент был для iPad нормальный: разделение экрана, нормальное отображение и так далее». Было: список чатов и чат рядом только у горизонтального iPad (от 900 pt); «Настройки», «Контакты», «Звонки» — экраны iPhone во всю ширину; шторки — во всю ширину внизу экрана; меню сообщения в правой колонке рисовалось со сдвигом на ширину списка (координаты пузыря — экранные, а меню открывалось в навигаторе колонки); звонок, фото и шторки из чата — только в правой колонке; пузыри — 78 % ширины колонки (на 12,9" — до 770 pt строки); с клавиатурой Enter переносил строку.

### Decision
Вопросы владельцу: устройство экрана — «как Telegram» (вкладки внизу под левой колонкой, справа — открытое); с какой ширины — «и стоя, от 700 pt».

**1. Когда две колонки.** Ширина окна ≥ 700 pt **и** высота ≥ 500 pt (`isWideSize` в `lib/app/adaptive.dart`): любой iPad стоя и лёжа, половина экрана 12,9" лёжа — нет (683), Slide Over / треть Split View — нет, iPhone на боку (844×390) — нет. Колонка списка 320 pt, у окна шире 1100 pt — 380 pt. Уже — как на iPhone.

**2. `AdaptiveSplit`** — одна обёртка для всех четырёх вкладок. Слева экран вкладки как есть (со своей нижней панелью вкладок; ему подставлена ширина колонки), справа — свой навигатор: заглушка «Выберите чат / раздел / контакт / звонок», строка списка открывает своё вместо того, что там было (`openDetail` / `_detail` в `navigation.dart`), глубже — внутри колонки, «Назад» — к заглушке. Открытое отмечено в списке (`AdaptiveSplit.selectedOf` → подсветка строки чата и контакта). Поиск, ⌘N, звонки из «Звонков», уведомление о сообщении (если чаты на экране) открывают чат справа.

**3. Поворот и Split View без потери чата.** Окно стало узким — открытое справа открывается во весь экран поверх списка (что было открыто внутри него глубже — закрывается). Снова широкое — открытое во весь экран (если поверх него ничего нет) уходит в правую колонку, одна копия. Список не пересоздаётся (`GlobalKey`). Вкладка помнит открытое: «Чаты» → «Настройки» → «Чаты» — тот же чат справа (до «Назад», выхода или удаления аккаунта).

**4. Поверх обеих колонок.** Звонок (исходящий, вход в групповой, из чата и из «Контактов»), фото / видео / галерея, меню сообщения, шторки и меню (`showDsActionSheet`, `showDsPickerSheet`, пересылка, ссылка, вставка ключа, слова копии, «Ваши другие устройства») открываются в навигаторе приложения (`rootNavigator`), не в колонке. Меню сообщения больше не сдвинуто. Выход и удаление аккаунта возвращают в начало приложения, а не к заглушке колонки.

**5. Шторки — окошки.** На широком экране шторка — окошко шириной до 440 pt в середине экрана, над клавиатурой, со скруглением со всех сторон (`DsSheetPlacement`); на iPhone и в узкой колонке — внизу, как было.

**6. Ширины на большом экране.** Пузырь — 78 % ширины чата, но не шире 560 pt (`bubbleMaxWidth`). Регистрация, вход по словам, «Разблокировать» — колонка 560 pt по центру (`DsReadableWidth`). Кнопки звонка без видео — не шире 480 pt (как уже было у видео).

**7. Клавиатура (iPad с клавиатурой).** В поле ввода Enter, ⌘Enter, Ctrl+Enter — отправить; Shift+Enter (и ⌥Enter) — новая строка; буквы, которые ещё набираются (японская / китайская раскладка), получают Enter сами; экранная клавиатура — как было (Enter — новая строка). ↑ в пустом поле — изменить своё последнее сообщение. Esc: ответ / изменение / выделение / панель стикеров → отменить, иначе закрыть чат; закрыть открытое справа; закрыть шторку или окошко. В «Чатах»: ⌥↑ / ⌥↓ и Ctrl+Tab / Ctrl+⇧Tab — чат выше / ниже (порядок «Все», «Избранное» первым), ⌘F — поиск, ⌘N — новое сообщение. Старые ⌘B / ⌘I / … (ADR-070) — как были.

### Alternatives
- **Боковая полоса значков вместо нижних вкладок** (как «Почта») — владелец выбрал вид Telegram; больше работы и непривычно после iPhone.
- **Только лёжа, от 900 pt** — как было; стоя iPad оставался большим iPhone.
- **Шторки-поповеры от кнопки** (как в iPadOS) — нужна точка привязки у каждого вызова; окошко по центру даёт ту же ширину без переделки вызовов.
- **Esc-обработчик над навигатором колонки** — не работает: ближайший к фокусу обработчик Esc — у самого экрана (Flutter `ModalRoute`), он «выключен» и глотает клавишу. Поэтому экран справа открывается маршрутом с `barrierDismissible` (барьер под страницей не виден), и Esc закрывает его штатно.

### Consequences
- **+** iPad стоя и лёжа — список и открытое рядом во всех вкладках; Split View / Slide Over — как iPhone, открытый чат не теряется.
- **+** Меню сообщения в правой колонке на месте (было сдвинуто на ширину списка).
- **−** При переходе в узкое окно закрывается то, что было открыто внутри правой колонки глубже первого экрана (например «Инфо» поверх чата) — остаётся сам чат.
- **−** Настройки справа — во всю ширину колонки (до ~985 pt), как в «Настройках» iPadOS.
- **Проверено:** виджет-тесты `test/app/adaptive_test.dart` (1024 и 1366 pt, Slide Over 375, 507, iPhone на боку; поворот туда и обратно; память вкладки; Esc; ⌥↓; шторка по центру и внизу; колонка формы; Enter / ⌘Enter / Shift+Enter / набор иероглифов / ↑), `unlock_test.dart` (настоящий экран чатов на 1024 pt). Swift / Kotlin не менялись. На iPad не проверено.

## ADR-077 · Администратор сервера: служебный чат «Сервер» с тревогами о нагрузке и жалобами (2026-10-24, урезано 2026-11-01)

Дополняет ADR-037 (жалобы), T1.5 (лимиты), T2.4 (метрики), ADR-032 (установщик).

> **Урезано перед слиянием (2026-11-01, status 216, правило KISS).** Владелец оставил ровно две вещи: **(а) тревоги о нагрузке** — процессор, память, соединения (с повтором не чаще 30 мин и «снова в норме») и **(б) жалобы** — каждая сразу, с аккаунтом и IP обеих сторон. Убрано: сводка за сутки, топ по трафику и сам подсчёт трафика (WS и медиа), тревоги «всплеск лимитов» и «похоже на DDoS» вместе со слоем подсчёта запросов по IP (`count_request`), пачки жалоб, уведомление «Сервер запущен», пороги в `.env` (`SINHRON_ADMIN_CPU_PCT` и др. — теперь константы в `admin.rs`; настройка одна — `SINHRON_ADMIN_IDENTITIES`). Виды уведомлений — `alert`, `ok`, `report`; миграция переименована в `20261101120000_admin_notices.sql` (на сервер ещё не выкладывалась). Ниже — исходное решение; зачёркнутое по смыслу — пункты про сводку, трафик, лимиты, DDoS и пачки.

### Context
Владелец: «можно добавить админа самого мессенджера: вводится его адрес (ключ) на сервер, чтобы сервер отправлял ему служебные уведомления — слишком высокая нагрузка, спам, возможный DDoS, кто больше трафик расходует; чтобы жалобы можно было смотреть, с аккаунтом и IP-адресом». До этого жалобы читались только SQL / `scripts/reports.sh` на сервере, о нагрузке оператор узнавал, когда всё уже лежало; IP сервер не хранил нигде.

### Decision (решения владельца 2026-10-24)
**1. Служебный чат, а не «сервер как собеседник».** Сервер не становится участником MLS: он автор уведомлений, прятать их от него нечего. Уведомления лежат в таблице `admin_notices`; приложение администратора забирает их `POST /v1/admin/notices` (подпись ключом устройства, `ADMIN_NOTICES_DOMAIN`, тело = `after_id`; привязанное устройство читает за своего человека) и показывает отдельной строкой «Сервер» вверху «Чатов» и экраном только для чтения. Всем остальным сервер отвечает 403 — приложение перестаёт спрашивать до следующего запуска, строки нет. Ответы командами («/топ») — потом, вместе с ботами (ADR-080).

**2. Кто администратор.** `SINHRON_ADMIN_IDENTITIES` — адреса (ключи аккаунта, 64 hex) через запятую; в установщике — `ADMIN_KEYS` в `/etc/sinhron/sinhron.conf` и вопрос «Ваш адрес в Sinhron…». Пусто — администратора нет, монитор не запускается и **ничего не собирается**: ни IP, ни трафик.

**3. Что и как часто (владелец: «Так»).**
- **Тревоги — сразу**, одна и та же не чаще раза в 30 мин, и «✅ снова в норме», когда прошло (3 спокойные минуты подряд): процессор ≥ 90 % три минуты подряд, память ≥ 90 % две, соединений ≥ 2000. Пороги — константы в `admin.rs`. (До урезки здесь были ещё лимиты ≥ 100/мин и «похоже на DDoS» ≥ 6000 запросов/мин — убраны.)
- **Жалоба — сразу**: № , причина, кто (начало ключа, IP), на кого (начало ключа, последний IP), сколько жалоб на него за 30 дней, текст (до 300 знаков, если приложен), полный ключ нарушителя. Каждая жалоба — отдельным уведомлением (пачки убраны в 216).
- ~~Сводка раз в сутки~~ и ~~«🟢 Сервер запущен»~~ — убраны в 216.
- Администратору без соединения уходит обычный push «новое сообщение» (без текста) — на тревоги и жалобы. На iPhone это «Новое сообщение»; на Android push только будит приложение — уведомления может не быть (tech-debt 2.63).

**4. Что хранится (владелец: «Оба IP, 30 дней»).** К жалобе — IP жалующегося (с запроса, последний адрес в `X-Forwarded-For`, его ставит Caddy) и последний IP того, на кого жалоба (из памяти: адрес, с которого он последний раз входил по WS). Через 30 дней оба IP стираются (`admin::sweep` из ежечасной уборки), жалоба остаётся; уведомления удаляются через 30 дней. Последний IP аккаунта — **только в памяти**, с пределом 200 000 аккаунтов, пропадает при перезапуске. Трафик и запросы по IP с 216 не считаются вовсе. Политика конфиденциальности (`server/download/privacy.html`) дополнена разделом «Жалобы и защита сервера».

### Где в коде
Сервер: `src/admin.rs` (`AdminConfig`, `note_ip` / `last_ip`, `Alarm`, `Monitor::check`, `tell_reports`, `spawn`, `sweep`), `src/handlers/admin.rs` (`POST /v1/admin/notices`), `handlers/account.rs::report` (IP, `report_filed`), `ws.rs` (`note_ip` при входе), миграция `20261101120000_admin_notices.sql`. Клиент: `HttpApi::admin_notices`, FFI `admin_notices`, `lib/core/admin_notices.dart`, `lib/features/server_notices/server_notices.dart`. Установщик: `ADMIN_KEYS`.

### Честные пределы
- **Сервер видит** то же, что и раньше видел в момент запроса (IP есть у любого соединения); новое — он **записывает** IP к жалобам на 30 дней и держит последний IP аккаунта в памяти. Изменённый сервер мог это делать и раньше.
- **Уведомления на сервере — открытым текстом** (в них ключи и IP): кто получит базу, прочтёт уведомления за 30 дней. Шифровать их на ключи администратора не стали — автор уведомлений сам сервер.
- **IP без Caddy подделывается**: без прокси клиент может сам прислать `X-Forwarded-For`. В нашей установке Caddy перезаписывает заголовок.
- **Нагрузка из `/proc`** — процессор и память машины (VM), не контейнера; на macOS (разработка) этих тревог нет.
- **Администратор с открытым приложением** получает новое за минуту (опрос раз в минуту, push только тем, кто без соединения).
- **Тексты уведомлений — по-русски**, независимо от языка приложения.

### Alternatives
- **Сервер как собеседник в MLS** (свой аккаунт, обычный зашифрованный чат, можно отвечать командами) — по сути бот: сервер хранит ключи и состояние MLS, в 3–4 раза больше работы, пересекается с ветвью «Боты». Отложено.
- **Prometheus + Alertmanager + Telegram** — внешние сервисы и настройка, которую владелец делать не будет; жалобы с IP туда не положишь.
- **Хранить IP дольше / только IP нарушителя** — владелец выбрал оба IP на 30 дней.

### Consequences
- **+** Владелец узнаёт о перегрузке и жалобах в самом Sinhron, без SSH.
- **+** Без администратора поведение сервера и данные — как раньше.
- **−** Новая таблица и три колонки у `abuse_reports`; IP к жалобам — новые персональные данные (политика обновлена).
- **Проверено:** сервер `cargo test -- --include-ignored` (тревоги о нагрузке, каждая жалоба по одной, уборка через 30 дней, только админ читает, IP в жалобе; после урезки 216 — снова), клиент `admin_notices_for_administrators_only`, Flutter `server_notices_test.dart`, установщик `install_test.sh`. На телефоне и на настоящем сервере не проверено.

**Дата принятия:** 2026-10-24.

## ADR-083 · Состав чата на сервере: только с подписью участника; удалённого убирают из рассылки и из звонка (2026-11-04)

Дополняет ADR-035 (выход из группы), ADR-075 (вход по карточке чата). Проверка безопасности `docs/security-review-2026-11.md`: server-http:1 (старый P0 #4), critic:5, critic:3 (серверная часть), calls:4.

### Context
Сервер не читает MLS — какие устройства в чате, ему говорят приложения: `POST /v1/groups` (создали чат, добавили людей или устройства, новый телефон вошёл по карточке). Запрос был **без подписи**: любой, кто знал id чата (бывший участник, тот, кто видел журнал сервера), вписывал туда своё устройство и получал всё, что сервер даёт участнику — рассылку Commit'ов и «открытых» сообщений, карточку чата (дверь к входу по внешнему Commit'у), приглашения и токен звонка, замену карточки, таймер чата. Удалённого из группы сервер не вычёркивал никогда: выйти мог только сам человек (`/leave`), а изменённое приложение этого не делает. Токен LiveKit жил час, комната звонка — по id чата, и из неё никого не выгоняли.

### Decision (владелец 2026-11-04: «Делай всё чтобы исправиться»)
1. **`POST /v1/groups` подписывает устройство, которое объявляет** (новый домен `sinhron-group-announce-v1:`, тело = group_id ‖ ключи всех устройств списка; подписывает ключ устройства — `login_seed_bytes`, тот же, что у его листа MLS и в `devices.device_pk`). Новые поля запроса `proof_ts`, `proof_hex`; старый сервер их не замечает.
2. **Кто может вписать устройства:** в существующий чат — устройство человека, у которого уже есть активное устройство в составе чата (как проверка Submit по WS: по человеку); либо человек, чьё устройство в чате было отключено (`group_former_devices`, ADR-075), — только своё новое устройство и больше никого. Новый чат — подписавший должен быть в своём списке. Отключённое устройство не может ничего.
3. **Переход** (убран 2026-11-04, ADR-087: неподписанный запрос — 401)**:** старые приложения (до этой версии) шлют без подписи. Пока `SINHRON_LEGACY_GROUP_ANNOUNCE` включён (по умолчанию), такой запрос принимается, но те же правила применяются к устройству, которое он называет создателем. Это закрывает «вписал своё устройство от своего имени», но не «назвал чужое устройство создателем» (ключи устройств публичны). Когда все обновились — `SINHRON_LEGACY_GROUP_ANNOUNCE=0` в `.env`, и неподписанный запрос получает 401.
4. **Удаление на сервере:** новый маршрут `POST /v1/groups/{id}/remove` (домен `sinhron-group-remove-v1:`, тело = group_id ‖ ключи личности удалённых; подпись ключом личности или активного привязанного устройства). Приложение зовёт его после того, как сервер упорядочил Commit удаления (`sync_remove_group_members`, теперь с адресом сервера). Сервер проверяет только, что подписавший — участник (у него есть активное устройство в составе): Commit он прочесть не может, а удалить любого в MLS может любой участник и так (ADR-035). Удаляются все строки `group_members` этих людей **и** их `group_former_devices` в этом чате — бывший участник больше не получает карточку и не проходит «вход отключённого телефона». Старый сервер без маршрута отвечает 404 — приложение молча продолжает.
5. **Звонки:** токен LiveKit живёт 10 минут, не час (подключённым LiveKit сам продлевает токен, поэтому длинный звонок не рвётся). Удалённых маршрутом п. 4 и отключённое устройство (`DELETE /v1/devices/{pk}`) сервер выгоняет из комнат звонков их чатов (`RoomService/RemoveParticipant`, в фоне; LiveKit не настроен или человека нет в комнате — ничего).

### Где в коде
Сервер: `handlers/groups.rs` (`create` — подпись и правила, `legacy_group_announce`, `announce_body`; `remove`, `remove_body`), `handlers/proof.rs` (`GROUP_ANNOUNCE_DOMAIN`, `GROUP_REMOVE_DOMAIN`), `handlers/call.rs` (`TOKEN_TTL_SECS` = 600, `evict_from_calls`, `remove_participants`, `room_admin_token`), `handlers/devices.rs` (revoke выгоняет из звонков), `lib.rs` (маршрут). Клиент: `HttpApi::announce_group(device_seed, group, members)`, `HttpApi::remove_group_members`, FFI `sync_remove_group_members(server_base_url, …)`, Dart `CoreGroupOps.removeMembers`.

### Честные пределы
- **Пока переключатель включён**, тот, кто знает id чата и ключ любого устройства участника, всё ещё может вписать себя неподписанным запросом. Выключить, когда все телефоны обновлены.
- **Участник с изменённым приложением** по-прежнему может многое: вписать в чат устройства любого человека (сервер не знает, кого добавил Commit), вычеркнуть другого участника из рассылки без Commit'а, заморозить чат ложным Commit'ом (server-ws:2), заменить карточку чата на текущую эпоху (server-http:10). *(Заморозка закрыта ADR-092, карточка — ADR-090/092.)* Против него нужна проверка подписей листов на телефонах (старый P0 #1) — отдельная тема.
- **Мусорный чат:** зарегистрированный человек может создать новый чат и вписать туда устройство любого (ему придут приглашения и push). Не закрыто: создатель законно вписывает чужие устройства.
- Если сообщение «удалил» до сервера не дошло (нет сети), удалённый остаётся в составе до следующего удаления в этом чате или до своего `/leave`.

### Alternatives
- **Сервер читает Commit'ы** (MLS в открытом виде или подпись Commit'а для сервера) — точнее, но это смена формата MLS-сообщений и openmls на сервере; намного больше работы.
- **Временная мера без обновления приложения** (создатель должен быть в составе) — без подписи обходится называнием чужого ключа; оставлена только на время перехода.

**Дата принятия:** 2026-11-04.


## ADR-086 · Каждая подпись называет сервер; старые подписи без имени сервера не принимаются (2026-11-04)

Дополняет ADR-025 (устройства), ADR-032 (адрес сервера выбирает человек), ADR-072 (запасной DNS). Проверка безопасности `docs/security-review-2026-11.md`: mls-identity:5, server-http:8 (старый P1 «подписи не привязаны к серверу»).

### Context
Вход по WS подписывал только `sinhron-ws-auth-v1:` ‖ вызов сервера, подтверждения действий — `домен:sha256(тело):время`, регистрация — `sinhron-register-v1:` ‖ ключ. Ни в одной подписи не было, **какому серверу** она предназначена. Злой сервер (адрес из его ссылки-приглашения, человек на новом телефоне вводит 24 слова → «Уже есть аккаунт») мог: переслать настоящему серверу запрос «добавить это устройство», показать телефону вызов настоящего сервера и войти там по WS как устройство человека (получить его очередь сообщений, отвечать на звонки), а подписанные словами «отключить устройство» и «удалить аккаунт» — переслать настоящему серверу в течение 60 с. Время в подписи телефон берёт у сервера, так что и 60 с злой сервер выбирает сам.

### Decision (владелец 2026-11-04: «Делай всё чтобы исправиться», «Убери все легаси, это пока 3 человека пользуются»)
1. **Что подписывается теперь:** `sinhron-server-host-v1:` ‖ имя сервера ‖ 0x00 ‖ <прежнее сообщение>. Так — у входа по WS, у всех подтверждений действий (KeyPackage, устройства, группы, медиа, звонки, push, ключи доставки и доступа, жалобы, удаление аккаунта, стикеры, привязка) и у регистрации. Внутреннее сообщение и домены прежние; новое поле в запросах не нужно — сервер сам знает своё имя. Префикс `sinhron-server-host-v1:` — в `ALL_SIG_DOMAINS` (не префикс другим доменам), старые сообщения начинаются со своего домена, поэтому старую подпись нельзя выдать за новую и наоборот.
2. **Имя сервера у приложения** — хост из адреса сервера, который человек ввёл (`HttpApi::host`, `sinhron_net::url_host`): маленькими буквами, без порта и пути. Не адрес, по которому реально подключились: запасной DNS (ADR-072) меняет только IP, имя в URL остаётся — его и проверяет TLS.
3. **Имя у сервера** — `SINHRON_PUBLIC_HOSTNAME` (его пишет установщик, docker-compose теперь передаёт его и самому серверу; можно несколько через запятую). Не задано — только `localhost`, `127.0.0.1`, `[::1]` (запуск на своём компьютере, тесты). Сервер пробует подпись по каждому своему имени; при запуске пишет в журнал, какие имена принимает.
4. **Без переходного периода.** Подписи старого вида (без имени сервера) сервер не принимает; переключателя нет. Значит, **сервер и все телефоны обновляются вместе**: старое приложение к новому серверу не войдёт (401 / вход отклонён), новое к старому — тоже. Откатываться на старую подпись приложение не умеет нарочно: злой сервер просто отказал бы в новой.
5. **Отключение устройства у собеседников** (ADR-075, `revocation_is_signed`): подпись отключения проверяется с именем своего сервера. Отключения, записанные на сервере до обновления (старого вида), собеседники больше не применяют — их уже применили раньше.

### Где в коде
Сервер: `handlers/proof.rs` (`SERVER_HOST_DOMAIN`, `public_hosts`, `bind_to_host`, `verify_bound`, `verify_ws_auth`; `verify_action_proof` и `verify_registration_proof` проверяют через него), `ws.rs` (`verify_auth_with_challenge` → `proof::verify_ws_auth`), `lib.rs` (имена в журнал), `docker-compose.yml`, `.env.example`; примеры `examples/{gen_proof,ws_client,ws_fanout,ws_resume}.rs`, `scripts/integration_smoke.sh` (подписи регистрации для `localhost`). Клиент: `sinhron_net/src/client.rs` (`SERVER_HOST_DOMAIN`, `url_host`, `bind_to_host`, `ws_auth_message`), `sinhron_sync/src/http_api.rs` (поле `host`, `action_proof(host, …)`, все подписи внутри методов, `revocation_is_signed(host, …)`), `sinhron_sync/src/telegram_stickers.rs`, `rust/src/api/simple.rs` (вызов `revocation_is_signed`).

### Честные пределы
- Сертификат устройства (`sinhron-device-cert-v1:`) имени сервера не содержит — он про человека, его проверяют и собеседники; переслать его на другой сервер бесполезно: добавление устройства требует ещё и подписи нового устройства, а она теперь с именем сервера.
- Злой сервер по-прежнему видит, что ему прислали (метаданные, ADR-032 / угроза 18), и может не пускать человека; не может — действовать от его имени на другом сервере.
- Часы: время подписи по-прежнему берётся у сервера (`clock_drift`); раз подпись годна только для этого сервера, «будущее» время от злого сервера ничего не даёт — отдельного ограничения не добавлял.
- Сервер, доступный под двумя именами: перечислить оба в `SINHRON_PUBLIC_HOSTNAME` через запятую (наш Caddy отдаёт API под одним именем, так что обычно это не нужно).

### Alternatives
- **Новые версии всех доменов (`…-v2`) с именем внутри** — те же байты по смыслу, но 25 констант на двух сторонах; общий префикс проще и закрывает всё сразу.
- **Отпечаток TLS-ключа сервера вместо имени** — крепче против подмены сертификата, но ломается при каждом обновлении сертификата Let's Encrypt; TLS и так проверяет имя.
- **Переходный период со старыми подписями (как `SINHRON_LEGACY_GROUP_ANNOUNCE`)** — владелец отказался: пользователей трое, обновляются вместе.

**Дата принятия:** 2026-11-04.
---

## ADR-087 · Сервер без переходных режимов: подписанное взятие KeyPackage, push только своему соединению и своему аккаунту, ntfy и база без лишних прав (2026-11-04)

Проверка безопасности `docs/security-review-2026-11.md`, тема server-ops (запись 240). Решения владельца 2026-11-04: «Делай всё чтобы исправиться» и «Убери все легаси, это пока 3 человека пользуются» — все телефоны обновляются вместе с сервером, переходные режимы не нужны.

### Decision
1. **Переходные переключатели убраны.** `SINHRON_LEGACY_MESSAGE_PUSH` (запись 181, ADR-071 amendment) и `SINHRON_LEGACY_GROUP_ANNOUNCE` (ADR-083 п. 3) больше не читаются; старый общий ключ к человеку с личными ключами больше не доставляет (`Refuse`); неподписанный `POST /v1/groups` — 401 (server-http:11, sealed-push:4).
   **Дополнено (тот же день): push своим — по любому пути (изменение протокола).** Без переключателя сообщения, ушедшие путём со входом, переставали будить телефон своих: WS `SealedSubmit` (анонимная отправка не прошла — нет сети, ключ сменился) давал только «запрос», обычный `Submit` — вообще ничего. А обычный `Submit` приложение шлёт ровно тогда, когда у кого-то в чате нет свежего подписанного ключа доставки (#76) — то есть телефону, который давно спит. Теперь `Submit` и `SealedSubmit` несут `access_keys` — ключи, которые собеседники дали отправителю (как `CallInvite.access_keys`, поле 8 / 3; старый сервер его не замечает). Сервер решает по каждому получателю с личными ключами, как для звонка (`verdicts_on` / `call_verdicts`): есть его ключ и он не отозван — обычный push и бейдж; только отозванный (заблокировал) — доходит без push и вне бейджа; ключа нет (незнакомый, ключ ещё не дошёл) — push «запрос» без содержимого (раз в 10 минут от одного одному; раньше у `Submit` — ничего). Приложение кладёт ключи участников чата (`members_access_keys`) в обычный `Submit` срочного сообщения и в `SealedSubmit` (`plan.access`). Почему не «состоит в общем чате на сервере»: новый чат с чужим устройством создаёт любой зарегистрированный (ADR-083), и не принятый ещё запрос — тоже общий чат; ключ же выдаёт только сам человек и отзывает блокировкой.
2. **Взятие KeyPackage подписано** (server-http:5; изменение протокола). `GET /v1/keypackages/consume` получает `signer_pk_hex`, `proof_ts`, `proof_hex`: подпись действия (домен `sinhron-kp-consume-v1:`, тело = ключ личности того, чьи KeyPackage берут) ключом личности или активного привязанного устройства (`resolve_signer`). Без подписи, с чужой подписью или от отключённого устройства — 401. Кроме лимитов на того, у кого берут (60 в час), и на IP — 240 в час на аккаунт берущего. Приложение: `HttpApi::fetch_device_keypackages(signer_seed, …)` (подписывает `login_seed_bytes`); `fetch_keypackage` (`count=1`) удалён — им пользовался только пример.
3. **push-токен не уходит к чужому аккаунту** (server-http:14, critic:6; миграция). Миграция `20261104160000_push_token_per_account.sql` убирает уникальный индекс `(token, kind)`. Регистрация токена снимает его только с устройств своего аккаунта и с отключённых устройств; у другого аккаунта его строка остаётся (раньше кто знал чужой токен, регистрировал его на себя — и у человека пропадали уведомления и звонки). Ошибки соединения с APNs и ntfy пишутся в журнал без адреса (в адресе был токен).
4. **Ответы на кадр — только соединению, которое его прислало** (server-ws:9). `Ack` и ответ на `Heartbeat` идут в это соединение (`tokio::task_local REPLY_TO` = id соединения, `SessionRegistry::send_to`), а не во все соединения человека.
5. **«Был в сети» — только день** (server-http:7). `GET /v1/devices` отдаёт `last_seen_at`, округлённое вниз до начала суток UTC (не раньше `registered_at`); `registered_at` точное (по нему приложение упорядочивает устройства). Приложение ждёт своё устройство в «Избранном» от начала того дня (≥ 48 ч, как раньше).
6. **Звонок без ключа не сообщает звонящему, что дошёл** (calls:10). Приглашение по-прежнему уходит в открытое приложение того, у кого звонящий без ключа, но звонящий видит то же, что при проглоченном звонке: `CallRing{delivered:false}` и «ringing» (не «callee offline»), и при подключении собеседника `CallRing` не приходит (`CallSession.quiet`). Цена: настоящий собеседник без ключа видит «Вызов…», а не «Звонит…».
7. **Полученный запечатанный конверт хранится 30 дней после получения** (sealed-push:6), не год: уборка удаляет `message_deliveries` с `envelope` и `received_at` старше 30 дней. Неполученные ждут год, как раньше. Другое устройство человека, не подключавшееся больше 30 дней, эти сообщения повтором (`Resume`) уже не получит.
8. **ntfy: подписка без входа, публикация — только сервер** (deploy-deps:16). ntfy v2.28.0, `auth-default-access: read-only`, пользователь `sinhron` (пароль никому не известен — хэш случайного выброшенного) с правом `up*` write-only и токеном из `.env` (`SINHRON_NTFY_TOKEN`, установщик делает один раз). Сервер шлёт `Authorization: Bearer` только первому хосту `SINHRON_UNIFIEDPUSH_HOSTS` (свой ntfy).
9. **Своя роль базы** (deploy-deps:8). Новая установка: сервер входит в Postgres как `sinhron_app` (не суперпользователь), она владеет базой, схемой и всеми таблицами (`server/scripts/db-init/10-app-role.sh`: при создании базы, перед каждым запуском из установщика, после `restore.sh`). Пароль суперпользователя в контейнер сервера больше не попадает. Существующая установка остаётся на `sinhron`, пока оператор не переключит (одна строка в `.env`, `deploy-guide.md` §9.1). Резервная копия — без владельцев (`pg_dump --no-owner`).

### Где в коде
Сервер: `handlers/access_keys.rs` (`anonymous_verdict`), `ws.rs` (`handle_submit` `quiet`, `handle_sealed_submit`, `REPLY_TO`, `push_to_user`, `handle_call_invite`, `replay_ringing_invites`), `session.rs` (`send_to`, `SessionGuard::conn_id`), `call_session.rs` (`quiet`), `handlers/groups.rs` (`create`), `handlers/keypackages.rs` (`consume`, `CONSUME_PER_CALLER`), `handlers/proof.rs` (`KP_CONSUME_DOMAIN`), `handlers/push_tokens.rs` (`put_with`), `handlers/devices.rs` (`list`), `retention.rs` (`RECEIVED_SEALED_KEEP_DAYS`), `unifiedpush.rs` (`token`, `token_for`), `apns.rs`, `migrations/20261104160000_push_token_per_account.sql`, `docker-compose.yml`, `install.sh` (`render_env`, `start_services`), `scripts/db-init/10-app-role.sh`, `scripts/backup.sh`, `scripts/restore.sh`. Клиент: `sinhron_sync/src/http_api.rs` (`fetch_device_keypackages`), `client.rs`, `src/api/simple.rs`, `lib/core/providers/saved_messages.dart`.

### Честные пределы
- Старые приложения (до этой версии) после обновления сервера не могут добавить человека или устройство (взятие KeyPackage — 401) и объявить чат (401) — обновлять телефоны вместе с сервером.
- Пока ключ собеседника ещё не дошёл (новый чат или группа — ключи раздаются при подключении; собеседник не принял запрос; у участника группы нет ключа доставки, чтобы передать ему ключ), сообщение путём со входом будит его телефон только «запросом» (на iPhone — тихое «Новый запрос на переписку»). Анонимный путь в этом случае и не используется.
- Сервер узнаёт, что отправитель держит ключ собеседника, и на запасных путях сообщений (раньше — только у звонков).
- Заблокированный с изменённым приложением, не кладущий отозванный ключ, для сервера — незнакомый: до одного push «запрос» в 10 минут, его телефон собеседника отбрасывает (блок на устройстве).
- Аккаунт без личных ключей (`access_per_contact = false`, ADR-026) работает как раньше — общий ключ.
- Кто знает чужой push-токен, по-прежнему может добавить свою строку и слать на тот телефон «Новое сообщение» и звонок «Sinhron» (нужна проверка, что телефон держит токен, — изменение протокола, отдельно).
- Прежний аккаунт этого же телефона (вышел и завёл новый на том же сервере) продолжит будить телефон, пока приложение не будет снимать токен при выходе.
- Активное «осушить KeyPackage и смотреть `/available`» сужено (нужен аккаунт), но не закрыто.

---

## ADR-090 · Звонок называет только подписавшего; облако не откатить незаметно; эпоха чата с начала и карточку меняет её автор; сервер обновляется до названного коммита (2026-11-04)

*Уточнено ADR-109 (2026-11-12): `install.sh --commit <id>` (пункт 5) при локальных правках в папке сервера, когда HEAD не на этом коммите, теперь останавливается с подсказкой, а не пропускает обновление молча.*

Проверка безопасности `docs/security-review-2026-11.md`, тема server-final (запись 244). Решение владельца 2026-11-04: «Делай всё чтобы исправиться», без переходных режимов (три человека обновляются вместе). Меняются протокол (новое поле приглашения, поле и подпись announce, новый маршрут) и хранение (две миграции).

### Context
- **calls:5.** Имя звонящего на экране блокировки iPhone бралось из подсказки `h` — HMAC ключом, который лежит на сервере (`apns_tokens.call_hint_key`); само приглашение в звонок (WS `CallInvite`) тоже пишет сервер. Оператор (или взломавший сервер) мог позвонить на любой телефон «от Мамы».
- **storage-devices:14.** Корень копии в iCloud / Google Диске запечатан постоянным ключом аккаунта: кто управляет облаком, мог вернуть старую копию, и новый телефон восстанавливал её как самую свежую — без сообщений после неё, с разблокированными с тех пор людьми, старыми настройками. Ни телефон, ни сервер не помнили, что была копия новее.
- **server-ws:2.** Чат, который сервер ещё не упорядочивал (`current_epoch` = 0 — каждый новый: создатель сливает свой Commit с добавлением сам), один раз «догонял» до эпохи ≤ 100. Участник слал Commit с эпохой 100 — чат прыгал на 101, все честные Commit'ы получали 409 навсегда (добавить, удалить, обновить ключи — нельзя). Эпоха 2^63 становилась отрицательной.
- **server-http:10.** Карточку чата (ADR-075) текущей эпохи заменял любой участник списка — мусором или GroupInfo своей группы с тем же id для нового телефона участника.
- **deploy-deps:5.** `install.sh --yes` (так и обновляют) ставил от root всё, что лежит на ветке; ночной cron копий запускает скрипт из того же дерева. Кто может писать в репозиторий, получал root на сервере при следующем обновлении.
- **deploy-deps:11.** `cargo audit` нигде не запускался.

### Decision
1. **Приглашение в звонок подписывает звонящий** (calls:5; протокол). `CallInvite.caller_proof` (поле 9) = `ts (u64 BE) ‖ подпись Ed25519 ключом устройства ‖ удостоверение` (ключ личности, 32 байта, или сертификат устройства, 132 байта — как в превью ADR-056) над `sinhron-call-invite-v1:` ‖ ts ‖ вид (1 голос, 2 видео) ‖ длина id звонка ‖ id звонка ‖ id чата (`sinhron_sync::call_invite`). Сервер требует 104–204 байта (иначе 400 «the invite must be signed by its caller»), хранит в `CallSession.caller_proof` и передаёт как есть — в приглашение, его повторы и в VoIP-push: `s` = base64(nonce ‖ AES-256-GCM(ключ телефона `call_hint_key`, длина ‖ подпись ‖ нули до 205 байт) ‖ тег), aad `sinhron-call-proof-v1` (`push::seal_call_proof`) — все одного размера, Apple не видит, кто звонит.
   - **Приложение** (`api/simple.rs` `signed_caller`): `caller_identity_hex` в `NetCallInvite` — только если подпись верна, свежая (± 120 с по часам сервера, как у подписанных запросов), для этого звонка, чата и вида, и подписавший — участник этого чата в MLS; иначе пусто. Пустой — звонок не звонит (`_screenedOut`: убирает и показанный push-звонок), как заблокированный. Блок группового звонка — по проверенной личности, а не по полю сервера.
   - **iPhone, приложение закрыто** (`CallHint.lookup`, `CallProof` в `ios/Shared/PushShared.swift`): чат находится по подсказке, как раньше; имя — только при верной подписи: в личном чате его человека (`p` в контексте уведомлений — его ключ) — имя чата, иначе — имя подписавшего из `people`; незнакомый ключ, нет подписи, неверная — «Sinhron» (iOS требует показать каждый VoIP-push; приложение, подключившись, снимет звонок без подписи). Подписавший заблокирован — звонок сразу завершается.
   - **Android**: push звонка по-прежнему без имени («Sinhron»), имя ставит приложение после проверки (как выше).
2. **Отметка свежей копии на сервере** (storage-devices:14; новый маршрут и таблица). `POST /v1/backup-mark` `{device_pk_hex, cloud, created_ts, proof_ts, proof_hex}` — подпись действия активным устройством аккаунта (`sinhron-backup-mark-v1:`, тело = cloud ‖ be8(created_ts)); `created_ts` > 0 — копия этого времени в облаке (сервер хранит наибольшее, `backup_marks (user_pk, cloud)`, миграция `20261104190100`), 0 — только спросить; ответ — самое новое известное (0 — нет). Облако — `icloud` / `googledrive` (`backupCloudKey`). После каждой копии приложение сообщает её время (`ChatBackup.run`), перед восстановлением спрашивает (`find`): если самая новая копия в облаке старше отметки — `BackupContents.missingNewer`, и вопрос «Восстановить переписку?» говорит: «Была копия новее (дата) — её в облаке больше нет, эта старше. Сообщений после неё не будет.» Решает человек. Сервер недоступен — без проверки, как раньше. Откат теперь требует облака **и** нашего сервера вместе.
3. **Эпоха чата — с настоящей, без «догона»** (server-ws:2; протокол и миграция). `POST /v1/groups` несёт `epoch` — эпоху MLS у объявляющего (1 после первого добавления, 0 у «Избранного»), подписанную: тело = id чата ‖ be8(epoch) ‖ ключи устройств. Новый чат начинается с неё; для существующего поле не значит ничего. Commit принимается только на `current_epoch` ровно (ветка «0 догоняет до 100» и константа `LEGACY_EPOCH_CATCH_UP` удалены); эпоха больше `i64` — 400. Миграция `20261104190000` один раз берёт эпоху у карточки чата для чатов, застрявших на 0 (карточка есть почти у всех: участники оставляют её на каждой эпохе); чат без карточки остаётся на 0.
4. **Карточку эпохи заменяет только автор эпохи** (server-http:10; миграция; *заменено ADR-093 — у каждого устройства своя карточка, колонка автора удалена*). `mls_groups.epoch_committer_device_pk` — устройство, чей Commit выиграл эпоху (у нового чата — создатель). Карточка — только для текущей эпохи (другая — 409); первая карточка эпохи остаётся, заменить её может только это устройство; проигнорированная загрузка — 204 (приложение не повторяет).
5. **Обновление — только до названного коммита** (deploy-deps:5). `install.sh --commit <полный id, 40 знаков>`: забрать ветку из `origin` и перейти ровно на этот коммит (`checkout --detach`); без `--commit` код не обновляется вовсе (пересборка того же). Первая установка без `--commit` — как раньше (ветка), с ним — этот коммит. Ночной cron копий запускает скрипт из того же дерева — он тоже не меняется без `--commit`. Метки (теги) не принимаются: их может передвинуть тот, кто пишет в репозиторий.
6. **`cargo audit` раз в неделю и по кнопке** (deploy-deps:11). `.github/workflows/audit.yml`: понедельник 03:41 UTC и «Run workflow», не на каждый push (минуты Actions); оба `Cargo.lock`; `cargo-audit` ставится `cargo install --locked` и хранится в кэше. Исключение одно — RUSTSEC-2026-0387 (crypto-bigint 0.5 через кривые 0.13; исправления в 0.5 нет, наш набор MLS кривые P-256/P-384 не использует).

### Alternatives
- **Звонок: вообще без имени в push** (имя — только после подключения приложения) — отклонено: владелец хотел имя на экране блокировки (ADR-056), а подпись даёт его честно.
- **Звонок: подпись открыто в push** — отклонено: Apple видела бы ключ личности звонящего и связывала звонки.
- **Звонок: проверять на iPhone членство в чате** — нужен список участников каждого чата в Keychain; вместо этого имя подписавшего (а у личного чата — его человек).
- **Копия: счётчик в самой копии, синхронизация между устройствами** — не помогает одинокому новому телефону (главный случай). **Подпись отметки ключом личности** — защищает только от ложного предупреждения сервером; сервер, скрывающий отметку, и так не остановить.
- **Обновления: проверка SSH-подписи коммита** — строже, но владельцу надо завести ключ подписи и подписывать каждый выпуск; `--commit` проще и совпадает с тем, как сервер обновляют сейчас (bundle + названный коммит).
- **Эпоха: «первый годный Commit выигрывает»** (сервер хранит все Commit'ы эпохи, телефоны берут первый, который MLS принимает) — закрывает и мусор на текущей эпохе, но это новый порядок доставки Commit'ов на всех устройствах (~150 строк); отложено. *(Сделано 2026-11-04 — ADR-092, запись 247.)*

### Где в коде
Сервер: `ws.rs` (`handle_submit` — строгая эпоха, автор; `handle_call_invite` — проверка размера подписи, `replay_ringing_invites`), `handlers/groups.rs` (`create` — `epoch`, `announce_body`; `put_card`), `handlers/backup_mark.rs`, `handlers/proof.rs` (`BACKUP_MARK_DOMAIN`, `CALL_INVITE_DOMAIN`), `push.rs` (`seal_call_proof`, `IncomingCall.proof`), `apns.rs` (`call_body` — `s`), `call_session.rs`, миграции `20261104190000_epoch_committer.sql`, `20261104190100_backup_marks.sql`, `install.sh` (`--commit`, `move_to_commit`), `.github/workflows/audit.yml`. Клиент: `sinhron_sync/src/call_invite.rs`, `client.rs` (`call_invite_proof`, announce с эпохой), `http_api.rs` (`announce_group(…, epoch, …)`, `backup_mark`), `src/api/simple.rs` (`signed_caller`, `net_send_call_invite`, `epoch_of`), `src/api/backup.rs` (`chat_backup_mark`), `lib/features/calls/active_call_provider.dart` (`_screenedOut`), `lib/core/notification_context.dart` (`p`), `lib/core/backup/{backup_service,backup_core_ffi}.dart` (`BackupMark`, `missingNewer`), `lib/features/settings/backup_screen.dart`; iOS `Shared/PushShared.swift` (`CallProof`, `CallHint.lookup`), `Runner/{AppDelegate,CallKitBridge}.swift`.

### Честные пределы
- **Участник с изменённым приложением по-прежнему может заморозить чат** мусорным Commit'ом на текущей эпохе (сервер MLS не читает) и, сделав пустой Commit, стать автором эпохи и подменить карточку. Против этого — «первый годный Commit» (выше) и проверка листов на телефонах (старый P0 #1). *(Закрыто 2026-11-04 — ADR-092: следующий честный Commit проходит; карточку участник держит только до лечения.)*
- Чат, застрявший на 0 без карточки (её не оставили), после обновления не примет Commit с эпохой 1 — изменения в нём будут получать 409; новый чат или повторная карточка исправляют (на живом сервере таких быть не должно: карточки оставляются при каждой синхронизации устройств).
- Имя на экране блокировки iPhone в групповом звонке — имя подписавшего, не чата (чат — после подключения приложения). Человек, которого нет среди известных имён, — «Sinhron».
- Оператор может по-прежнему звонить «Sinhron» без имени (до подключения приложения, которое снимет звонок) — iOS требует показать каждый VoIP-push.
- Отметка копии — по облаку целиком: если новую копию сделало устройство, которое ещё не выгрузило её в iCloud, новый телефон предупредит (человек решает). Сервер, скрывающий отметку вместе с облаком, откат не покажет.
- Подпись звонка и отметка копии подписываются тем же `action_proof` / ключом устройства; PR #81 (адрес сервера в подписи) нужно слить с этим аккуратно (вызовы `action_proof` в новых местах).
- `audit.yml` будет красным, пока закреплённые версии (rustls 0.23.40, time, bytes, tracing-subscriber 0.3.19 …) не подняты — это и есть сигнал; подъём — отдельно.
- Swift и Kotlin здесь не собирались; `CallProof` проверяется тестом `ios/SharedTests/main.swift` (вектор из Rust) — на Маке.

**Дата принятия:** 2026-11-04.

---

## ADR-091 · Код QR-привязки — один раз: после того как его забрали, любой следующий ответ получает 409 (2026-11-04)

Проверка безопасности `docs/security-review-2026-11.md`, продолжение `storage-devices:13` (запись 245). Решение владельца 2026-11-04: протокол менять можно, без переходных режимов (три человека обновляются вместе).

### Context
Сервер отдавал ответ на QR (ADR-027) тому, кто ответил первым, а при взятии (`GET /v1/pairing/{id}`) удалял строку. Если чужой человек увидел QR нового телефона и ответил первым, а новый телефон уже забрал его ответ, то ответ владельца со старого телефона попадал в пустое место — новая запись, 204, «Готово». Владелец не узнавал, что код использовал кто-то другой.

### Decision
- **Сервер** (`handlers/pairing.rs::take`, миграция `20261104200000_pairing_taken.sql`): при взятии строка не удаляется — `pairing_mailbox.taken = TRUE`, пакет стирается (пустой `ciphertext`), срок — ещё 10 минут от взятия (затем её убирает обычная чистка `retention.rs`). Пока отметка жива, `PUT` с тем же id — 409 (как и раньше при занятом id), повторный `GET` — 409 «already used» (раньше 404). Взятие — одним `UPDATE … FOR UPDATE … AND NOT taken`: два одновременных `GET` не получат пакет оба.
- **Старый телефон** (`add_device_screen.dart`): на 409 вместо «Не удалось отправить, проверьте связь» — «Этот код уже использован другим устройством — если это не вы, ничего не подтверждайте».
- **Новый телефон** (`pair_qr_screen.dart`): на 409 (кто-то забрал ответ раньше него) — «Этот код забрало другое устройство. Вот новый — показывайте его только своему устройству» и новый код через 3 с.
- Rust-клиент не менялся: ошибка 409 уже доходит до приложения как `server 409: …` (`isPairingUsedError` в `core/pairing.dart`).

### Alternatives
- **Держать в строке, кто ответил** и говорить владельцу «ответил другой аккаунт» — сервер узнал бы больше, а сказать нужно одно и то же.
- **Отдельная таблица отметок** — лишняя; хватает колонки в той же строке.

### Честные пределы
- Это только сообщает владельцу; новый телефон, взявший чужой пакет, всё ещё входит в чужой аккаунт без вопроса — нужно показывать отпечаток аккаунта до входа (основная часть `storage-devices:13`, отдельная тема).
- Если ответ владельца дошёл до сервера, а ответ сервера потерялся, повторное нажатие покажет то же предупреждение (код уже использован — им самим). Редко; новый код решает.
- Старое приложение на 409 при взятии показывает «Не удалось привязать» и делает новый код — безопасно.

**Дата принятия:** 2026-11-04.

---

## ADR-088 · Админ группы записан в самой группе MLS, а не «кто на листе 0» (2026-11-04)

*Уточнение (2026-11-12, находка CM-08 второго аудита, открыта — решение владельца): фраза «изменённое приложение не сделает себя админом» неверна — любой участник может убрать админа и стать админом; правило «только после „выхожу“» пробовали и откатили (ADR-102).*

### Context
ADR-035 считал админом того, кто сейчас на листе 0 дерева MLS. Проверка `docs/security-review-2026-11.md` (mls-identity:8) показала, что это неверно: когда создатель уходит (или меняет телефон, и его первый лист убирают), MLS кладёт следующего добавленного в самый левый свободный лист, то есть на лист 0, и «админом» на всех телефонах становится новичок. Участник с изменённым приложением мог так забрать роль нарочно: убрать создателя и добавить своё второе устройство. С записи 231 Commit с новым человеком от не-админа не применяется, поэтому неверный админ стал важнее. Запоминать создателя на каждом телефоне отдельно нельзя: телефоны разойдутся в том, кто админ, и честное добавление расколет чат. Владелец 2026-11-04: «исправить всё», смена формата допустима, совместимость со старыми версиями не нужна (все обновятся), но существующие чаты должны работать.

### Decision
- **Запись об админе — в контексте группы MLS**, который подписан, общий для всех участников и одинаков на каждом телефоне. Носитель — стандартное расширение `external_senders` с одной записью: ключ личности админа (`group.rs` `admin_record`). Создатель ставит её при создании группы (`GroupHandle::create`).
- **Правило одно, его считает каждый телефон** (`admin_after`): админ — человек из записи, пока у него есть хоть одно устройство в группе (смена телефона роль не забирает). Иначе (он ушёл, или записи ещё нет) — самый ранний оставшийся человек (наименьший номер листа среди тех, кто уже был до этого Commit'а). Новичок этого же Commit'а в счёт не идёт.
- **Каждый наш Commit** (`commit_pending`: добавление, удаление людей и устройств) сам вписывает запись, когда её нет или когда админа удаляют. Так передача роли происходит в том же Commit'е, который убирает ушедшего админа.
- **Каждый телефон проверяет чужой Commit:** запись после него должна быть ровно той, что даёт правило. Чат без записи может пока остаться без неё. Другие расширения контекста меняться не могут. Иначе Commit не применяется (`Other`, как отказы записей 225 и 231). Записать себя админом, убрать админа без передачи роли или «передать» роль не по правилу не получится.
- **Старые чаты** (созданы до этой версии): пока записи нет, правило даёт того, кто на самом левом занятом листе. Пока создатель на месте, это он, как раньше. Первый же Commit обновлённого телефона вписывает запись, и дальше всё идёт по ней. Второй ветки кода нет: «записи нет» — тот же случай правила, что «админ ушёл».
- Dart: `GroupOps.admin` → FFI `sync_group_admin` (было `sync_group_creator`); `GroupRole.canManage` прежний: админ, или любой, если админа нет (это только не-MLS группы в тестах и демо).

### Alternatives
- **Своё расширение контекста** (тип из частного диапазона). OpenMLS 0.8 требует, чтобы такой тип объявил в своих возможностях каждый лист группы, включая давно мёртвые телефоны, и чтобы он стоял в `required_capabilities`. Существующие листья его не объявляют, а без обновления каждого листа старые чаты запись не получат. `external_senders` — тип по умолчанию, его поддерживает каждый телефон, поэтому старые чаты получают запись со следующим Commit'ом.
- **Убрать роль админа** (управляет любой) — меньше кода, но любой участник тогда переименовывает группу и добавляет кого угодно. Владелец выбрал «исправить».
- **Запомнить создателя на каждом телефоне отдельно** — телефоны расходятся, чат раскалывается (см. Context).
- **Явная передача роли уходящим админом** — MLS не даёт закоммитить своё удаление, а лишнее сообщение не нужно, если правило одно для всех.

### Consequences
- **+** Новичок на листе 0 — не админ. Смена телефона админа не забирает роль. Изменённое приложение не назначит себя админом. Все телефоны согласны, кто админ, без лишних сообщений.
- **+** Новых таблиц, маршрутов сервера и сообщений нет. Сервер по-прежнему не видит ничего, кроме шифротекста.
- **−** `external_senders` в RFC 9420 означает «кто вне группы может присылать предложения». Мы кладём туда ключ личности админа (не ключ устройства). Подписать им предложение может только сам админ, а приложение предложения не обрабатывает (никогда не вызывает `store_pending_proposal`), так что запись ничего не разрешает.
- **−** Права по-прежнему соблюдают клиенты (ADR-035): участник с изменённым приложением может удалить админа (это тот же путь, что честный выход), и роль перейдёт к самому раннему оставшемуся, не к нему (если только он сам не самый ранний).
- **−** В старом чате, где создатель уже ушёл и лист 0 занял новичок, первая запись назовёт этого новичка: истории у группы нет. Таких чатов у владельца нет или единицы.
- **Проверено:** `a_newcomer_on_the_creators_old_leaf_is_not_the_admin`, `the_admin_keeps_the_role_after_changing_phone`, `a_member_cannot_make_itself_admin`, `a_chat_from_before_the_record_keeps_its_admin_and_gets_the_record` (все четыре падали до исправления), плюс прежние тесты групп и устройств. На телефоне не проверено.

**Дата принятия:** 2026-11-04.

---

## ADR-092 · Мусорный Commit не замораживает чат: «первый годный Commit эпохи», сервер берёт Commit от того, кто видел предыдущие (2026-11-04)

*Уточнено ADR-096 (2026-11-12): Commit принимается, только если дошёл до каждого получателя (занятый `message_id` — откат и 400), а повтор того же Commit после потерянного ответа получает прежний успешный ответ вместо 409; второй, другой Commit той же эпохи — по-прежнему 409. Уточнено ADR-101: Commit без Ack за 20 с больше не выбрасывается сразу — применяется по своему эху или по Ack 0 на повторную отправку; на 409/400/403 выбрасывается (нужен сервер 0.12.0).*

Проверка безопасности `docs/security-review-2026-11.md`, «Осталось» после ADR-090: server-ws:2 вариант B и server-http:10 со стороны участника (запись 247). Решение владельца 2026-11-04: протокол и хранение менять можно, без переходных режимов (три человека обновляются вместе). Дополняет ADR-022 (порядок Commit'ов) и ADR-090 (эпоха с начала, карточку меняет автор эпохи).

### Context
Сервер не читает MLS. Он брал первый Commit эпохи (`current_epoch` ровно) и сдвигал эпоху. Участник с изменённым приложением слал на текущей эпохе мусор или Commit, который честные телефоны не применяют (лист без человека — mls-identity:1, новый человек не от админа — mls-identity:3, чужая запись админа — ADR-088). Сервер принимал его, честные телефоны оставались на старой эпохе, и каждый их Commit получал 409 навсегда: чат нельзя было менять, нарушителя — удалить. Автор такого Commit'а становился автором эпохи и хозяином карточки чата (ADR-090).

### Decision
1. **Телефоны берут первый годный Commit своей эпохи** в порядке, в котором сервер их разослал (так они и делали: негодный — пропуск, чужая эпоха — пропуск). Раз все получают Commit'ы чата в одном порядке и проверяют одинаково, все честные выбирают один и тот же.
2. **Сервер берёт Commit для эпохи E от устройства, только если оно видело и не применило каждый Commit эпохи E, который сервер уже разослал после Commit'а, приведшего устройство в E.** `Submit.parent_commit_id` (поле 10) — message_id этого Commit'а (пусто — неизвестен: вход по Welcome или карточке; тогда считаются все Commit'ы эпохи), `Submit.refused_commit_ids` (поле 9) — Commit'ы эпохи E, пришедшие с тех пор и не применённые. Иначе — 409, как когда чужой Commit пришёл первым. Отсюда: два годных Commit'а на одну эпоху от честных телефонов не выйдут (второй не видел первого — 409; видел бы — был бы уже в E+1), а мусор ждёт только следующего честного Commit'а.
3. **Хранение:** `group_commits (n, group_id, epoch, message_id, device_pk)` — каждый разосланный Commit по порядку (`n`), миграция `20261104210000`. Один Commit на устройство и эпоху (поток мусора ограничен числом устройств). Commit'ы берутся и рассылаются по одному на весь сервер (`COMMIT_ORDER`, отпускается после рассылки) — живые соединения получают их в порядке `n`. `mls_groups.current_epoch` / `epoch_committer_device_pk` — эпоха и устройство последнего взятого Commit'а: только оно меняет карточку (ADR-090; *с ADR-093 у каждого устройства своя карточка, колонка удалена*). Ограничения «эпоха слишком далеко» нет: прыжок никто не применит.
4. **Commit говорит, что он Commit** (`ws::mls_commit_head` и тот же разбор `sinhron_sync::group::commit_epoch` — оба читают открытый заголовок MLS одинаково, мягко: всё, что телефон прочтёт как Commit, — Commit и для сервера): `is_commit` должен совпадать с содержимым, `commit_epoch` и чат — из заголовка (иначе 400). Commit через запечатанную доставку (`open_sealed`) телефон не применяет.
5. **Журнал на телефоне** (`sinhron_sync::commit_order::CommitLog`, настройка `commit_log`): на каждый пришедший Commit (`push_event`) — применили → «эпоха E, родитель — он»; не применили (и это не наше эхо) → в список эпохи, если он для нашей эпохи, и отметка «лечить». Наш Commit, взятый сервером, — тоже «родитель». Если наш Commit взят, а мы уже применили чужой — наш проиграл (`has_pending_commit`).
6. **Лечение:** при отметке «лечить» синхронизация устройств (`sync_devices`, при открытии приложения) делает пустой Commit (`self_update_pending`). Эпоха и карточка снова у честного участника; из нескольких честных выигрывает один.

### Alternatives
- **(a) Commit как PublicMessage, сервер проверяет подпись листа** по карточке. Подпись докажет только, что автор — участник; злоумышленник и есть участник, и его Commit подписан. Годность пути (ключи эпохи, confirmation/membership tag) без секретов группы не проверить. Плюс OpenMLS на сервере и раскрытие серверу, кто кого добавил. Отклонено: не закрывает атаку.
- **(b) Откат эпохи по жалобам** (телефон подписывает «этот Commit негоден», сервер откатывает при большинстве / жалобе админа). Сервер не знает, кто админ и сколько людей онлайн; телефон, уже применивший Commit, не умеет «отменить» его; ложная жалоба на честный Commit замораживает чат с другой стороны. Отклонено.
- **(c) Принятое**: сервер не судит Commit, он только проверяет, что отправитель видел всё, что было до него. «Жалоба» — это сам следующий Commit.
- **Курсор доставки вместо списка** (`seq`, до которого обработано) — проще на проводе, но доставки могут прийти не по порядку (повтор при входе и живая рассылка), и честный телефон мог бы «перепрыгнуть» годный Commit. Отклонено.

### Где в коде
Сервер: `ws.rs` (`handle_submit`, `mls_commit_head`, `COMMIT_ORDER`), `migrations/20261104210000_group_commits.sql`. Клиент: `sinhron_sync/src/commit_order.rs`, `group.rs` (`commit_epoch`, `self_update_pending`), `client.rs` (`open_sealed`, `self_update_pending`), `src/api/simple.rs` (`push_event`, `commit_log`, `send_commit`, `submit_pending_commit`, `join_by_cards`, `sync_devices`). Протокол: `Submit.refused_commit_ids`, `Submit.parent_commit_id`.

### Consequences
- **+** Мусорный или негодный Commit участника больше не замораживает чат: следующий честный Commit проходит (удалить нарушителя можно); автором эпохи и хозяином карточки нарушитель остаётся только до лечения.
- **+** Порядок честных Commit'ов прежний: гонка двух — 409 второму.
- **−** Новая таблица, два поля протокола, журнал на телефоне; Commit'ы на сервере идут по одному.
- **Честные пределы.** Commit «на половину чата» (ключи пути годные одним, мусор другим) раскалывает чат — предел MLS против участника. Участник может на время выставить карточку своей копии чата; новый телефон, вошедший по ней в это окно, попадёт в копию (нужна проверка карточки вторым участником). Лжец, назвавший честный Commit негодным, отправит второй годный на ту же эпоху — раскол только при разном порядке доставки (вход в сеть в этот момент). Потерянный ответ на наш Commit и потерянный журнал — 409 до чужого Commit'а. Старое приложение (без журнала) в обычном чате работает, после мусора — ждёт чужого Commit'а.
- **Проверено:** `ws::tests::a_members_garbage_commit_does_not_freeze_the_chat`, `a_commit_must_say_it_is_one`, `mls_commit_head_reads_private_and_public_commits`; клиент `client::tests::a_members_garbage_commit_does_not_freeze_the_chat` (настоящий MLS), `commit_order::tests::a_commit_names_what_it_saw_at_its_own_epoch_only`. На телефоне не проверено.
---

## ADR-093 · Своя карточка чата у каждого устройства; новый телефон верит той, что оставили его человек или большинство (2026-11-06)

*Частично заменено ADR-100 (2026-11-12): голосование «мой человек или большинство» больше не решает — карточку берём, только если её подписало другое устройство моего же человека; поддельная карточка от сервера — это чтение переписки, а не «отказ в обслуживании», как было написано.*

Проверка безопасности `docs/security-review-2026-11.md`, «Осталось» после ADR-092: окно, когда участник-злоумышленник выставляет карточку своей копии чата (server-http:10 со стороны участника). Владелец 2026-11-06: «Да, давай это сделай». Заменяет пункт 4 ADR-090 («карточку меняет автор эпохи»).

### Context
Сервер держал одну карточку на чат (GroupInfo для входа нового телефона по внешнему Commit'у). С ADR-090 первую карточку эпохи мог заменить только автор эпохи — устройство, чей Commit её сделал. Если автор — участник с изменённым приложением, его карточка (другое дерево, чужой внешний ключ, иная история) стояла всю эпоху, а эпоха может жить днями. Новый телефон честного человека входил по ней в копию чата, которой нет ни у кого: писал в пустоту и ничего не получал. Сервер не может отличить годную карточку от мусора — он не читает MLS.

### Decision
1. **У каждого устройства в чате своя карточка** (`group_cards` — ключ `(group_id, device_pk)`, миграция `20261106120000`). `PUT /v1/groups/{id}/card` — как раньше (подпись устройства, только текущая эпоха чата), но кладёт карточку этого устройства и ничью не заменяет. `mls_groups.epoch_committer_device_pk` больше не нужен — колонка удалена.
2. **`POST /v1/groups/{id}/card` отдаёт карточки всех активных устройств, которые ещё в чате** — `{ cards: [{ epoch, card_b64, identity_hex }] }`, новые эпохи первыми; `identity_hex` — ключ личности человека, чьё устройство её оставило.
3. **Телефон выбирает сам** (`sinhron_sync::card_choice::cards_to_try`). Честные карточки одной эпохи говорят одно и то же — отличается только подпись (последние 69 байт GroupInfo: номер листа подписавшего и подпись Ed25519). Карточки группируются по содержимому без подписи; первая — та, что оставил **мой человек** (другое моё устройство в чате), иначе та, за которую **больше людей** (устройства одного человека — один голос), при равенстве — более новая эпоха. Считаются только две последние эпохи, чтобы старые карточки давно не заходивших не перевешивали. Не открылась — следующая.
4. **Приложение один раз заново выкладывает свои карточки** (настройка `group_cards_sent_v2` вместо `group_cards_sent`): миграция удаляет старые карточки (у них не записано устройство).

### Alternatives
- **Вторая подпись на карточке** (участник подтверждает чужую карточку своей подписью). Тот же итог «верь тому, с чем согласны другие», но новый формат подписи и ещё один маршрут. Отклонено: голос по совпадающему содержимому даёт то же без нового формата.
- **Сервер выбирает карточку сам** (по большинству). Сервер не видит людей за устройствами иначе, чем по своей таблице, и не должен решать за телефон. Отклонено: телефон считает сам, сервер только хранит.

### Где в коде
Сервер: `handlers/groups.rs` (`put_card`, `get_card`, `CardEntry`), `ws.rs` (`handle_submit` — без автора эпохи), `migrations/20261106120000_cards_per_device.sql`. Клиент: `sinhron_sync/src/card_choice.rs`, `http_api.rs` (`get_group_cards`), `src/api/simple.rs` (`join_by_cards`, `CARDS_SENT_SETTING`), `examples/rejoin_e2e.rs`. Формат ответа `POST /v1/groups/{id}/card` изменился — сервер и телефоны обновляются вместе.

### Consequences
- **+** Участник больше не может на всю эпоху подсунуть новому телефону свою копию чата: честные карточки рядом, и телефон выбирает по голосам. Свой второй телефон в чате — решающий голос.
- **+** Меньше кода на сервере: нет колонки автора эпохи и правила «кто может заменить».
- **−** На сервере карточка на каждое устройство (до 256 КБ каждая, в семейных чатах — единицы КБ).
- **Честные пределы.** Сразу после мусорного Commit'а участника, пока ни один честный телефон не «вылечил» чат (ADR-092), его карточка — единственная новой эпохи; если честная карточка прошлой эпохи одна, это ничья, и новый телефон может войти по его карточке: вход уйдёт в никуда, телефон попробует снова позже (раз в 30 минут). Две и больше честных карточек прошлой эпохи побеждают — вход получит 409 и подождёт лечения. Чат на двоих, где второй — злоумышленник: опереться не на кого (но и переписка там только с ним). Сервер может отдать любые карточки — как и раньше, это отказ в обслуживании, не чтение.
- **Проверено:** сервер `every_member_keeps_its_own_card_and_nobody_replaces_another`, `a_lost_phone_is_cut_off_with_a_proof_and_its_person_gets_the_card`; клиент `client::tests::a_new_phone_joins_by_the_card_most_people_left` (настоящий MLS: карточки Алисы и Кэрол одной эпохи совпадают без подписи, карточка ветки Мэллори проигрывает, новый телефон Боба входит, Алиса принимает вход), `card_choice::tests::*` (6); `rejoin_e2e` и `groups_e2e` через живой локальный сервер. На телефоне не проверено.

**Дата принятия:** 2026-11-06.

---

## ADR-085 · 24 слова на iPhone — в связке ключей iCloud, а не паролем сайта; экран слов защищён (2026-11-04)

**Почему.** Проверка `docs/security-review-2026-11.md`, `storage-devices:2` (высокая): с ADR-059 кнопка «Сохранить в «Пароли»» звала `SecAddSharedWebCredential` — 24 слова становились **паролем сайта** `chat.777400777.xyz` (`SinhronPasswordDomain`, одинаковый для любого сервера). Safari предлагает такой пароль на любой странице этого домена: страница с полем пароля (оператор, взлом VPS, перехват домена) по одному нажатию и Face ID получала слова = аккаунт. ADR-059 считал, что «серверу ничего не передаётся» — для паролей сайта это не так. Владелец: «исправь всё», «убери все легаси, это пока 3 человека».

**Решение.**
- **iPhone:** слова — запись связки ключей самого приложения (`kSecClassGenericPassword`, сервис `dev.sinhron.words`, логин «Имя · 8 знаков отпечатка», `kSecAttrSynchronizable = true`, `AfterFirstUnlock`). Связка ключей iCloud переносит её на новый iPhone с тем же Apple ID; читает только Sinhron; в приложении «Пароли» её не видно, Safari её не предлагает. Сохранение — без системного окна (сразу «сохранено»). «Вставить из связки ключей» берёт самую новую такую запись.
- **Старая запись (сохранённая до этой версии) — один раз переносится.** Если новой записи нет, «Вставить…» открывает прежний выбор паролей (`ASAuthorizationPasswordProvider`); выбранные слова сразу кладутся в новую запись, а пароль сайта удаляется (`SecAddSharedWebCredential(домен, логин, nil)`; iOS может спросить подтверждение). В «Настройки → Секретные слова» у человека, сохранившего слова старым способом, есть строка «Перенести в связку ключей iCloud». Других двойных путей нет (владелец: «убери все легаси»).
- **Хранимое:** `access_saved` в настройках получает новое значение `keychain:<мс>` (iPhone); `passwords:<мс>` на iPhone теперь значит «ещё в «Паролях», перенести». Android не меняется (Credential Manager привязан к приложению, домена нет).
- **Экран 24 слов** (`storage-devices:8`; отступление от «снимки не запрещаем» ADR-059 — только на этом экране): Android — `FLAG_SECURE`, пока экран открыт (нет снимка, записи, показа экрана в звонке, картинки в «Недавних»); iPhone — пока экран записывается или транслируется (`UIScreen.isCaptured`), слова закрыты (снимок экрана на iPhone не запретить — строка о нём осталась). «Скопировать» — через канал `dev.sinhron/privacy` (`lib/core/screen_privacy.dart`): iPhone — `localOnly` (не уходит на Mac/iPad) и `expirationDate` 60 с; Android — `EXTRA_IS_SENSITIVE` (Android 13+: без превью, не в истории клавиатуры).
- **«Недавние» на Android** (`storage-devices:19`): с блокировкой приложения и «Скрывать в переключателе» — `setRecentsScreenshotEnabled(false)` (Android 13+); старше — `FLAG_SECURE`, пока приложение в фоне (лучшее, что есть: снимок может успеть раньше).

### Alternatives
- **Свой домен разработчика только с AASA** — слова всё равно были бы паролем сайта; меньше риск, тот же класс атаки.
- **Оставить «Пароли», но предупредить** — не закрывает атаку.
- **Запрет снимков во всём приложении** — против ADR-059; закрыли только экран слов.

### Consequences
- **+** Ни одна страница не может попросить слова через автозаполнение.
- **+** Слова не уходят в буфер обмена Mac/iPad и в историю клавиатуры Android; экран слов не попадает в показ экрана и «Недавние».
- **−** Запись не видна в приложении «Пароли» — посмотреть её глазами нельзя, только «Вставить…» в Sinhron. Если связка ключей iCloud выключена, запись только на этом iPhone (как и раньше).
- **−** Несколько аккаунтов на одном Apple ID: «Вставить…» берёт самую новую запись; чужие слова «Проверить слова» отвергнет.
- **−** `webcredentials:` в `Runner.entitlements` и `SinhronPasswordDomain` остаются, пока у всех не перенесены старые записи (нужны, чтобы прочитать и удалить их); потом — убрать (и `webcredentials` из AASA сервера).
- **−** Swift и Kotlin здесь не собирались: проверка — сборка Android в CI и Xcode на Mac; на телефоне — по `open-items.md`.

**Дата принятия:** 2026-11-04.
## ADR-082 · Ключ доставки подписан хозяином: превью уведомления — только на проверенный ключ (2026-11-04)

Дополняет ADR-023 (sealed sender), ADR-025/027 (устройства), ADR-056 (превью в push). Проверка безопасности `docs/security-review-2026-11.md`, `mls-identity:4` = `sealed-push:1` (старый P0 п. 2 из `security-review-2026-11-02.md`).

### Context
Отправитель берёт недельный ключ доставки собеседника с сервера (`GET /v1/sealed-keys`) и ничем его не проверял. Сервер (или взломщик сервера) мог отдать **свой** ключ вместо ключа Боба: отправитель запечатывал на него превью уведомления — кто пишет, в какой чат и до 320 байт текста — сервер его открывал, а конверт перезапечатывал на настоящий ключ Боба. Сообщение доходило, никто ничего не замечал; у Боба только «Новое сообщение» вместо текста.

### Decision (владелец, 2026-11-04: «Делай»)
- **Подпись на каждом ключе.** При публикации (`PUT /v1/sealed-keys`) у каждого ключа новое поле `sig_hex` — Ed25519 над `"sinhron-delivery-key-v1:" ‖ ключ личности (32) ‖ неделя (4, BE) ‖ ключ (32)`. Подписывает тот же ключ, что и сам запрос: ключ личности, а на устройстве, привязанном по QR (ключа личности нет), — ключ устройства; тогда в запросе ещё `cert_hex` — его сертификат устройства (тот же формат, что в MLS, `identity::device_of_certificate`). Код: `sinhron_sync::sealed::{sign_delivery_key, delivery_key_signed}`, `HttpApi::publish_sealed_keys(…, cert)`, `SyncClient::signer_certificate`.
- **Сервер хранит и отдаёт.** Две новые колонки `sealed_keys.sig`, `sealed_keys.cert` (могут быть пустыми — старые приложения), миграция `20261104120000_sealed_key_sig.sql`; `GET` отдаёт `sig_hex` / `cert_hex`, если они есть. Сервер подпись не проверяет (проверяют отправители — ему и так не доверяем); ключ, уже лежащий без подписи, получает её при следующей публикации.
- **Проверка у отправителя.** `fetch_sealed_keys` помечает ключ «подписан», только если подпись верна для той личности, у которой ключ числится (или для устройства, чей сертификат выдан этой личностью). `sealed_plan` кладёт превью **только** на подписанный ключ. Без подписи или с неверной — сообщение уходит как раньше (запечатанным), но без превью: уведомление «Новое сообщение». Неверная подпись пишется в журнал.

### Совместимость
- Старое приложение → новый сервер: PUT без подписи принимается, как раньше.
- Старое приложение читает новый GET: лишние поля serde пропускает (у старой структуры нет `deny_unknown_fields`).
- Новое приложение → собеседник со старым приложением: у его ключа нет подписи → уведомление без текста, пока он не обновится.
- Новое приложение → старый сервер: подписи теряются → уведомления без текста, пока сервер не обновлён. Обновлять сервер вместе с приложениями.

### Честные пределы
- Сервер по-прежнему может отдать **неподписанный** чужой ключ: превью он уже не получит, но конверт запечатан на его ключ — он узнает, в какой чат сообщение (как без sealed sender), и может не доставить. Когда все обновятся, можно перестать запечатывать на неподписанные ключи совсем (одна строка) — отдельным решением.
- Сервер может срезать подписи у настоящих ключей — тогда уведомления без текста (неприятно, но тайну не нарушает).
- Отключённое устройство (ADR-075) по-прежнему знает `delivery_root` и может подписать ключи — как и раньше, оно знает и сами ключи.

### Alternatives
- **Просто не прикладывать превью** (одна строка) — закрывает утечку, но текста в уведомлениях не будет ни у кого. Отклонено: подпись почти так же проста и сохраняет текст.
- **Подписывать ключ доставки внутри MLS** (отдать его в `Access`) — больше кода и состояние на каждый чат; ключ всё равно недельный.

### Consequences
- **+** Сервер больше не читает превью сообщений, если обе стороны обновлены.
- **−** Одно новое поле в PUT и GET, две колонки. Пока собеседник или сервер не обновлены — уведомления без текста.

**Дата принятия:** 2026-11-04.
- **Без совместимости (владелец, 04.11: «убери всё легаси, это пока 3 человека»):** ключ без подписи (или с неверной) приложение не использует вовсе — сообщение идёт обычным путём, не запечатанным к ключу, который мог подложить сервер. Все телефоны обновляются вместе.

## ADR-084 · Отключил устройство — у аккаунта новые ключи доставки и копии, которых у отключённого нет (2026-11-04)

*Уточнено ADR-103 (2026-11-12): всё своим устройствам (синхронизация, перенос, история) запечатывается ключом доставки поколения 0, и после смены поколения публикуются также ключи поколения 0. Уточнено ADR-105: новое поколение ключей аккаунта делается ещё и после восстановления из облачной копии.*

Дополняет ADR-023 (ключи доставки), ADR-027 (пакет связанного устройства), ADR-064 (синхронизация моих устройств), ADR-073 (копия в облаке). Проверка безопасности `docs/security-review-2026-11.md`: `mls-identity:2`, `storage-devices:10` (старый P1 «отозванное устройство сохраняет общие ключи аккаунта»).

### Context
Пакет связанного устройства несёт корень ключей доставки (`delivery_root`) и ключ облачной копии (`cloud_key`) — одинаковые у всех устройств, из 24 слов, никогда не меняются. Отключение (`revokeDevice`) меняло только версию ключа доступа. Значит, отключённый (украденный) iPad навсегда: (а) вычисляет мои будущие недельные ключи доставки и открывает превью уведомлений и конверты, если добудет их (сервер, Apple); (б) открывает каждую будущую копию переписки в iCloud / Google Диске моих других устройств — без нашего сервера вовсе, штатной кнопкой «Восстановить» (если на нём тот же Apple ID). Владелец: «Делай всё чтобы исправиться» — менять формат можно.

### Decision
**1. Поколение корней.** Поколение 0 — как было: корень доставки и ключ копии из 24 слов (ничего не меняется у аккаунтов, где ни одно устройство не отключали). При отключении устройство, которое отключает (любое моё, со словами или без), берёт **32 свежих случайных байта** `R` и номер `g = старый + 1`; корень доставки и ключ копии поколения — `HKDF(R, "sinhron-delivery/v1" ‖ be32(g))` и `HKDF(R, "sinhron-cloud-backup/v1" ‖ be32(g))` (`sinhron_crypto::identity::RootsGen`). Из 24 слов их не вычислить — у отключённого есть только поколение 0.

**2. Как доходит до моих устройств.** Новая синхронизируемая настройка `account_roots` = `<g>:<hex R>` (ADR-064): уходит сразу (`device_sync_flush`) в группу «только мои устройства», из которой отключённое уже удалено (тот же `devicesRevoke`), а не к нему. Новое устройство получает её в переносе, телефон, восстановленный из копии, — вместе с остальными настройками. Новых таблиц, маршрутов и форматов сообщений нет. Пакет нового устройства (QR) по-прежнему несёт поколение 0 — ключ его базы не меняется; текущее поколение приходит переносом.

**3. Ключи доставки.** Публикуются ключи текущего поколения; открываются конверты на ключи текущего, двух прежних (локально, `account_roots_old` — собеседник мог запомнить старый ключ на 1–2 недели) и поколения 0. Сервер теперь отдаёт **последний опубликованный** ключ недели первым (`ORDER BY … created_at DESC`; повторная публикация обновляет `created_at`) — без этого старый ключ той же недели, опубликованный раньше, так и оставался бы первым.

**4. Копия.** Пока поколения нет — `root.sinhron` прежнего формата. С поколением ≥ 1 корень начинается с заголовка `SNB2 ‖ g ‖ HPKE(X25519-ключ аккаунта, R)`, остальное — прежний корень под ключом поколения, заголовок входит в AAD. Мои устройства открывают его своим поколением; **одни 24 слова** (новый телефон) — сначала достают `R` из заголовка секретным X25519-ключом аккаунта (он есть только у слов), а связанные пакеты несут только открытый. Отключённое не открывает ни то, ни другое.

### Честные пределы
- **Копии и ключи до отключения** отключённое по-прежнему открывает — там то, что оно и так видело. Старые файлы копии удаляются следующей копией.
- **Окно перехода:** пока другое моё устройство не получило новое поколение (выключено, нет связи), оно публикует ключи и делает копии поколения 0 — их отключённое открывает. Устройство без обновления (старая версия) нового поколения не понимает: публикует ключи поколения 0 и **не открывает** сообщения на новые ключи — обновлять все свои устройства.
- **Собеседник с запомненным старым ключом** (до ~2 недель) запечатывает превью на ключ, который отключённое вычисляет.
- **Два отключения одновременно на двух устройствах** — побеждает позднее (LWW); ключи проигравшего остаются у него в «прежних».
- **Не сделано:** ключ доступа (`access_root`) не меняется — отключённое может вычислить следующую версию и писать мне без входа (спам, не чтение); ключ базы связанного устройства по-прежнему вычисляется из поколения 0 (`storage-devices:20`, нужна копия файла базы); откат копии к старой (`storage-devices:14`) — нужна метка свежести вне облака.

### Alternatives
- **Новые корни из 24 слов + счётчик** — отключённое вычислило бы и их (у него те же корни поколения 0).
- **Хранить поколение на сервере** (новый маршрут) — сервер не нужен: своя группа устройств уже есть.
- **Положить поколение в пакет связанного устройства** — меняет ключ его базы (он считается от пакета); перенос и так несёт настройки.

### Consequences
- **+** Отключённое устройство не открывает копии и не вычисляет ключи доставки, сделанные после отключения.
- **+** У аккаунтов без отключений ничего не меняется (поколение 0, прежний формат корня).
- **−** Все свои устройства надо обновить, иначе необновлённое теряет запечатанные сообщения после отключения другого.

**Дата принятия:** 2026-11-04.

---

## ADR-094 · Очередь приглашений меньше предела соединения; копии по устройствам (2026-11-12)

### Context
Аудит 04-server-ws, WS-07/08/09: очередь Welcome на человека была 64 МиБ, предел очереди одного соединения — 32 МиБ. Человеку с двумя устройствами Welcome без адресата хранился весь срок (год) и при каждом входе вываливался целиком во все его соединения: 33 кадра от любого аккаунта — и человек не может держать соединение. Поле `group_id` в квоте не считалось.

### Decision
1. `MAX_PENDING_WELCOME_BYTES` = 8 МиБ (Welcome — до 1 МиБ, как было); в квоте считается `welcome_bytes + group_id`; `group_id` ≤ 255 байт.
2. Welcome без `recipient_device_pks` человеку с несколькими устройствами сервер сам адресует каждому его активному устройству (существующая ветка «по устройствам»): каждая копия выдаётся один раз и удаляется. Устройство, привязанное позже, старых приглашений не получит — оно и не могло их открыть (Welcome зашифрован для пакетов ключей прежних устройств).
3. При входе читается не больше 8 МиБ очереди (новейшие) и отдаётся только вошедшему устройству.

### Consequences
- **−** Копий на диске больше (по одной на устройство), но в пределах тех же 8 МиБ на человека. При потоке чужих Welcome настоящие вытесняются быстрее, чем при 64 МиБ (WS-20 остаётся открытой).

### Alternatives
- Отказывать новым Welcome при полной очереди — посторонний на год закрыл бы человеку приглашения.

**Дата принятия:** 2026-11-12.

---

## ADR-095 · Бюджеты WebSocket: байты в час, Commit'ы, соединения, страницы очереди (2026-11-12)

### Context
WS-03/04/06/10/11: единственными пределами были 4 МиБ на кадр и 600 кадров в минуту; вход и Resume читали до 1000 строк любого размера; число соединений не ограничено; все Commit'ы ждут один замок.

### Decision
Всё — готовым `StaticLimiter`, без новых таблиц:
- `SINHRON_RATE_WS_BULK` = 2000/3600: кадр Submit / SealedSubmit до 64 КиБ бесплатен, больший платит жетон за каждые 256 КиБ (~500 МиБ в час на аккаунт). Пачки истории для нового устройства — по 256 КиБ, то есть ~1000 пачек в час.
- `SINHRON_RATE_WS_COMMIT` = 120/60 на аккаунт.
- `SINHRON_RATE_WS_CONNECT` = 600/60 на адрес клиента (IPv6 — /64), до апгрейда; без заголовка адреса (прямое подключение, тесты) не действует.
- 16 соединений на человека; новое закрывает самое старое (новое всегда побеждает — «мёртвые» соединения не запирают вход).
- Вход и Resume: страница ≤ 16 МиБ (+ одна строка, до 4 МиБ). 16 + 8 (приглашения) < 32 МиБ предела соединения, поэтому вход сам себя не «застревает».
- Соединение сверх 32 МиБ закрывается после того, как всё поставленное в очередь записано в сокет (WS-02).

### Alternatives
- Жёсткий предел размера конверта/сообщения (1 МиБ) — рискует сломать пачки истории у уже установленных приложений. Квота недоставленного на получателя — см. tech-debt (нужен выбор владельца).

**Дата принятия:** 2026-11-12.

---

## ADR-096 · Commit принимается, только если дошёл до каждого получателя (2026-11-12)

### Context
WS-05, обход ADR-092: участник шлёт обычное сообщение с номером X, затем Commit с тем же X. Строки доставки уже есть (`ON CONFLICT DO NOTHING`), Commit никому не уходит, но записан в `group_commits` и сдвинул эпоху. Честные телефоны не могут назвать его «отвергнутым» и получают 409 навсегда.

### Decision
В `handle_submit`: если у Commit'а число созданных доставок не равно числу получателей — откат транзакции и ответ 400 «message_id already used». Проверка стоит после вставок, поэтому закрывает и гонку с параллельным сообщением с тем же номером, и случай, когда номер занят запечатанным конвертом у части получателей.

**Повтор после потерянного ответа.** Тот же Commit ещё раз (тот же `message_id`, то же устройство, те же байты, пока строка сообщения хранится) — ответ 0, как в первый раз; ничего не пишется и не рассылается. Проверка повтора ищет по эпохе самого Commit'а и стоит до проверки «есть невиденные», поэтому ответ 0 и тогда, когда чат уже ушёл на эпоху дальше (если отправителя за это время удалили из чата — 403: проверка членства раньше). Тот же номер от другого устройства или с другими байтами — 400. Раньше повтор получал 409, и приложение выбрасывало Commit, который остальные уже применили.

### Consequences
- **−** Второй, другой Commit того же устройства для той же эпохи по-прежнему 409 (ADR-092).

**Дата принятия:** 2026-11-12.

---

## ADR-098 · Блокировка аккаунта: строка в `users` со `status = 'banned'` (2026-11-12)

Аудит 2026-11b, область 03 (сервер, HTTP API), находка ACCT-2: бан оператора не держался — ключ регистрировался заново.

### Context
`scripts/reports.sh ban <ключ>` удалял аккаунт целиком, и тот же ключ можно было тут же зарегистрировать снова. Колонка `users.status` уже была.

### Decision
Бан оператора (`scripts/reports.sh ban <ключ>`) удаляет аккаунт, как раньше, и оставляет в `users` строку с тем же ключом и `status = 'banned'`. Сервер не регистрирует такой ключ (403), не пускает его по WS и в подписанные запросы, не даёт привязать устройство и не даёт удалить эту строку через «Удалить аккаунт». Колонка уже была — новой таблицы и миграции не нужно; всё, что хранилось для человека, стирается теми же каскадами.

Снять бан: `DELETE FROM users WHERE identity_pubkey = decode('<ключ>', 'hex') AND status = 'banned';`.

### Alternatives
- **Отдельная таблица заблокированных ключей.** Отклонено: новая таблица ради одной колонки.

### Consequences
- Блокируется ключ, а не человек: новые секретные слова дают новый аккаунт (без контактов и чатов); от этого защищают только лимиты регистрации.
- Самоудаление остаётся обратимым: тот же ключ можно зарегистрировать снова.
- `reports.sh` выкладывается вместе с сервером: старый сервер принял бы строку-блокировку за обычный аккаунт. Ключи, забаненные раньше, не заблокированы — при желании забанить заново.
- Приложение на 403 от `POST /v1/identity` пишет ошибку в журнал и остаётся «нет связи»; отдельного текста «аккаунт заблокирован» нет.

---

## ADR-099 · Общий предел объёма медиа на сервере (2026-11-12)

Аудит 2026-11b, область 03 (сервер, HTTP API), находка MEDIA-10 (+PREV-5).

### Context
Медиа лежат на одном диске с базой; полный диск останавливает Postgres — нет сообщений и звонков у всех. Квота на человека диск не защищает: регистрация открыта, каждый новый аккаунт приносит свои 4 ГиБ в сутки.

### Decision
Все зашифрованные вложения вместе занимают не больше `SINHRON_MEDIA_TOTAL_BYTES` (по умолчанию 50 ГиБ). Загрузка сверх предела отклоняется кодом 429 (как суточная квота); место освобождается само — файлы, которые никто не открывал 90 дней, удаляются.

**Почему 50 ГиБ.** Сначала было 10 ГиБ (под минимальный диск 20 ГБ), но независимая проверка показала: семья из пяти человек при хранении 90 дней честно набирает 10 ГиБ за ~3 недели, и загрузки встали бы у всех. 50 ГиБ честной работой не достигается; на маленьком диске предел опускается переменной `SINHRON_MEDIA_TOTAL_BYTES` (проброшена в `docker-compose.yml`, описана в `.env.example`).

### Alternatives
- **Код 507 вместо 429.** Отклонено: приложение из main уже показывает 429 понятным текстом; отдельный код потребовал бы правки приложения.
- **Предел 10 ГиБ.** Отклонено после независимой проверки (см. выше).

### Consequences
- Один `SUM(size_bytes)` по таблице `media` на каждую новую загрузку (таблица маленькая).
- Предел считает строки базы, а не сам диск: файлы без строки (MEDIA-3) он не видит — их убирает уборка.
- Если диск сервера меньше ~70 ГБ — задать `SINHRON_MEDIA_TOTAL_BYTES` в `.env` меньше.

---

## ADR-100 · Вход в чат: карточку берём только от своего устройства; истёкший срок чужого листа входу не мешает (2026-11-12)

### Context
Аудит 2026-11b: CM-01 (high), CM-02, CM-05, CM-04. Телефон без MLS-состояния чата (восстановлен из копии) входил по «карточке» (GroupInfo), которую отдаёт сервер, и проверял только «в дереве есть другой лист моей личности». Но сервер хранит KeyPackage моих устройств: он собирал СВОЮ группу с номером настоящего чата, клал туда мой настоящий пакет и отдавал как карточку. Телефон входил, сервер читал всё, что с него пишут, и мог писать «от собеседника» (тест `audit_b_server_forged_card_reads_victim`). ADR-093 называл это лишь отказом в обслуживании — неверно. Кроме того: номер чата в карточке не сверялся до входа — карточка чата Y, выданная за карточку чата X, затирала живой чат Y (CM-05); не было нижней границы эпохи (CM-02); а Welcome и карточка переставали открываться, когда у любого старого участника истекал срок листа (84 дня от KeyPackage, обновляется только собственным Commit'ом — CM-04, подтверждено тестом с пакетом на 2 секунды: `Lifetime(Expired)`).

### Decision
1. `GroupHandle::join_by_card` берёт карточку, только если её подписало ДРУГОЕ УСТРОЙСТВО МОЕГО ЖЕ ЧЕЛОВЕКА (лист-подписант из хвоста GroupInfo: OpenMLS проверяет подпись по этому листу, мы проверяем, что лист — мой и не этот аппарат). Такую подпись сервер подделать не может. Голосование ADR-093 («мой человек или большинство») больше не решает: чужие карточки, сколько бы их ни было, не повод входить; приложение передаёт в выбор только карточки своего человека.
2. До построения и записи чего-либо: номер чата в карточке = номер чата, который просили; на телефоне нет живого состояния этого чата; карточка не старше мёртвой копии чата на этом телефоне (его убрали — он знает эпоху).
3. Как и для Welcome — каждый лист дерева карточки должен называть человека.
4. При входе по Welcome и по карточке срок действия чужих листьев не проверяется (`skip_lifetime_validation`, готовая настройка OpenMLS). Срок добавляемого пакета по-прежнему проверяет тот, кто добавляет.

### Alternatives
Отвергнутые варианты в заметках сессии не записаны.

### Consequences
- **Цена (сказать владельцу).** Вход по карточке «пока все спят» теперь работает, только если на сервере есть карточка МОЕГО другого устройства текущей эпохи: второе устройство живо, либо потерянный телефон ещё не отключён и чат с тех пор не менялся. Сервер отдаёт карточки только не отключённых устройств — поэтому порядок такой: сначала войти на новом телефоне (чаты подтянутся), потом отключать потерянный. Иначе новый телефон ждёт, пока его добавит любой участник, зашедший в сеть (ADR-074) — как и раньше для чатов без карточки.

- **Что осталось.** CM-02 для телефона совсем без состояния (чистое восстановление): сервер в сговоре с удалённым участником может отдать подлинную, но старую карточку моего же устройства. Нужна «последняя известная эпоха чата» в резервной копии (формат копии — зона соседней сессии); не сделано. Формат карточек, сервер и протокол не менялись.

### Где в коде
`sinhron_sync/src/group.rs` (`join_by_card`, `card_signer`), `client.rs` (`join_by_card(group_id, card)`, `join_via_welcome` через `JoinBuilder`), `src/api/simple.rs` (`join_by_cards`), `card_choice.rs` (шапка), `examples/rejoin_e2e.rs`.

- **Проверено:** `audit_b_server_forged_card_reads_victim`, `audit_b_card_of_other_chat_wipes_live_group_{single_device,after_restart,via_caller_forget}`, `a_card_older_than_the_chat_this_device_knew_is_refused`, `a_members_expired_leaf_does_not_lock_the_chat_for_newcomers`, обновлённые `a_new_phone_joins_by_the_card_most_people_left`, `a_new_phone_joins_by_the_chats_card_and_strangers_dont`. `rejoin_e2e` переписан (сначала вход, потом отключение), через живой сервер НЕ запускался. На телефонах не проверено.

**Дата принятия:** 2026-11-12.

---

## ADR-101 · Commit без ответа сервера не выбрасывается: применяется по своему эху или отправляется ещё раз (2026-11-12)

### Context
Аудит CM-03 (самое вероятное в жизни, без нападающего) и CM-06. Если Ack на наш Commit не приходил за 20 с, приложение выбрасывало Commit. Но сервер мог его уже принять и разослать: остальные переходили в новую эпоху, а этот телефон молча и навсегда оставался в старой (входящие терялись, его сообщения переставали читаться, новый Commit — 409 навсегда: один Commit устройства на эпоху). ADR-092 описывал это мягче, чем было. CM-06: «своим эхом» считался любой кадр, называющий наш лист, — участник мог слать мусор «от нас», и мы не записывали его как «не взял».

### Decision
1. Нет ответа за 20 с (кадр отправлен) → Commit остаётся ожидающим в MLS-состоянии; его байты, номер, Welcome и список добавляемых устройств пишутся в настройки (`commit_unanswered`) — переживает перезапуск.
2. С сервера вернулись ровно те байты, что мы отправили (сравнение побайтно; сервер рассылает только принятый Commit) → применяем свой Commit сразу, с Ack или без. Это же закрывает гонку «чужой Commit поверх нашего пришёл раньше нашего Ack».
3. При следующей синхронизации устройств (`settle_unanswered`, до любых новых Commit'ов в чате): Commit ещё ждёт → отправляем ТОТ ЖЕ Commit с тем же номером и теми же байтами. Правило ответа (`after_resend`): **свой Commit применяется только по Ack 0** (сервер 0.12.0 на повтор уже принятого Commit того же устройства снова отвечает 0 и ничего не рассылает повторно; не виденный — принимает) **или по своему эху**; 409 — победило чужое изменение, выбрасываем, как на первой отправке; 400/403 — выбрасываем; 429, 5xx, тишина — ждём дальше. Когда наш применён — досылаем Welcome добавленным устройствам и сообщаем серверу состав.
4. «Своё эхо» (не записывать как «не взял») — только кадр, совпавший с отправленным нами (CM-06).

5. **Нужен сервер 0.12.0** (ветка `claude/fix-012-server-ws`, a5cf806: идемпотентный повтор Commit). Сервер обновляется первым. Со старым сервером повтор принятого Commit получил бы 409, Commit был бы выброшен и телефон отстал бы — как до правки, не хуже.

### Alternatives
Отвергнутые варианты в заметках сессии не записаны.

### Consequences
- **Цена.** Пока Commit ждёт, этот телефон не может отправлять в этот чат (MLS не шифрует при ожидающем Commit) — обычно секунды до эха или до следующей синхронизации; раньше вместо видимой задержки была тихая и вечная потеря чата. История для своего нового устройства и перенос (ADR-064) в ветке «досылаем Welcome» не повторяются — придут со следующей синхронизацией/копией.

- **Что осталось.** Логика тайм-аута и повтора в `simple.rs` юнит-тестом покрыта только в части правила ответа (`after_resend`) — нужен прогон на телефонах/живом сервере.

### Где в коде
`src/api/simple.rs` (`send_commit_as`, `submit_pending_commit`, `settle_unanswered`, `after_resend`, `is_our_sent_commit`, обработка Push), `sinhron_sync/src/group.rs` (`pending_adds`), `client.rs` (`pending_adds`).

- **Проверено:** `api::simple::tests::a_commit_sent_again_is_applied_only_on_ack_0` (правило ответа), `client::tests::a_commit_whose_ack_was_lost_is_applied_when_it_comes_back` (настоящий MLS: Commit оставлен, эхо, подтверждение, дальше чат живёт; Commit с добавлением — известно, кого приветствовать). Сама логика в `simple.rs` (тайм-аут, настройки, повтор) юнит-тестом не покрыта — нужен прогон на телефонах/живом сервере.

**Дата принятия:** 2026-11-12.

---

## ADR-102 · Правила входящего Commit: свой лист нельзя отдать другому человеку; сообщение без отправителя не показывается (2026-11-12)

### Context
Аудит CM-07, CM-09 (участник с изменённым приложением). CM-07: Commit участника мог нести на его новом листе ДРУГУЮ личность — новый человек входил без админа и без строки в чате. CM-09: сообщение, отправителя которого определить не удалось (удалённый участник пишет в старой эпохе, ключи которой ещё хранятся), всё равно показывалось — в личном чате как «от собеседника».

### Decision
1. Новый лист автора Commit (и лист в Update) должен называть того же человека, что и его текущий лист; иначе Commit не берём.
2. Вход по карточке (внешний Commit) может убирать только устройства самого входящего (RFC 9420 оставляет эту проверку приложению).
3. Сообщение без подтверждённого отправителя не отдаётся приложению.

### Alternatives
Правило «админа убирает только Commit после его „выхожу“» (CM-08) было сделано и откатано по итогам независимой проверки: телефон, добавленный между «выхожу» админа и его удалением, оставался бы в старой эпохе без чата, а если админ потерял телефон и слова — группа навсегда без админа и без новых людей. Для семьи это хуже исходной дыры.

### Consequences
- **Цена.** Сообщение, отправленное человеком за миг до его удаления и пришедшее после, теперь не показывается.

- **CM-08 НЕ закрыт — ждёт решения владельца.** «Любой участник может убрать админа и по правилу ADR-088 стать админом» оставлено как в main. Варианты для владельца: оставить как есть (и поправить текст ADR-088 «изменённое приложение не сделает себя админом» — это неверно); либо MLS SelfRemove для выхода + «убирает только админ».

### Где в коде
`sinhron_sync/src/group.rs` (`process_incoming_with_sender`).

- **Проверено:** `a_member_cannot_hand_their_leaf_to_another_person_and_the_removed_are_not_heard`.

**Дата принятия:** 2026-11-12.

---

## ADR-103 · Сообщения своим устройствам запечатываются ключом поколения 0 (2026-11-12)

Аудит 2026-11b, находка DEV-1 (запись 257). Уточняет ADR-084.

### Context
ADR-084: после «Отключить» телефон делает новое поколение ключей аккаунта и рассылает его своим устройствам через группу своих устройств. Но внешний конверт (sealed sender) для своих устройств запечатывался уже ключом доставки НОВОГО поколения. Остальные мои устройства знают только старые поколения, а только что привязанное по QR — только поколение 0: письмо с новыми ключами и предложение переноса не открывались («no current delivery key matches»). После первого же отключения синхронизация своих устройств и перенос ломались.

### Decision
Всё, что идёт своим устройствам (`send_own`: синхронизация, перенос; история новому устройству), запечатывается ключом доставки **поколения 0** этой недели (`SyncClient::own_devices_key`). Он есть у каждого моего устройства всегда (ADR-084 п.3: поколение 0 хранится вечно). Содержимое защищает MLS группы своих устройств, из которой отключённое устройство уже удалено, — внешний ключ ничего сверх этого не скрывал. Сервер направляет конверт по идентификатору ключа, поэтому после смены поколения телефон публикует и ключи поколения 0 (`SyncClient::sealed_keys_to_publish`): первыми в запросе, чтобы новое поколение было записано последним и отдавалось собеседникам первым (сервер: «кто опубликовал последним — тот первый в списке»). Получается 4 ключа — ровно предел `MAX_KEYS_PER_PUT`; сервер менять не нужно.

### Alternatives
Отвергнутые варианты в заметках сессии не записаны.

### Где в коде
`sinhron_sync/src/client.rs` (`own_devices_key`, `sealed_keys_to_publish`), `src/api/simple.rs` (`own_delivery_key`, `publish_sealed_keys`). Тест: `sinhron_sync/tests/dev1_own_devices_key.rs` (3).

### Consequences
- **+** После «Отключить» новые ключи аккаунта и перенос доходят до всех моих устройств, включая только что привязанное.
- **−** Отключённое устройство по-прежнему может вычислить открытый ключ поколения 0 — как и раньше; закрытого содержимого это ему не даёт (MLS).
- **−** Собеседник, которому сервер отдал ключ поколения 0 вместо нового, запечатает им — это открывается всеми моими устройствами (как и до правки).
- На телефоне не проверено.

---

## ADR-104 · Телефон помнит свои отключённые устройства (2026-11-12)

Аудит 2026-11b, находки PAIR-1 и XFER-7 (запись 257).

### Context
Сертификат устройства бессрочный, а список устройств телефон брал у сервера без подписи. Сервер (взломанный или нечестный), снова показав отключённое устройство, заставлял телефон вернуть его во все чаты и отправить ему историю и перенос.

### Decision
Без нового формата и таблицы: настройка `device_revoked:<ключ устройства>` = `1` в зашифрованной базе. Ставится при успешном «Отключить» (`devices_revoke`, `devices_revoke_with_phrase`), синхронизируется между своими устройствами как `device_name:` (ADR-064). `sync_devices` убирает такие ключи из списка сервера (`devsync::without_revoked_devices`): устройство не добавляется (нет ни истории, ни переноса), а его оставшийся лист удаляется из групп. Привязка того же ключа заново по QR (`pairing_send*`) — решение владельца — снимает отметку (`""`).

### Alternatives
Отвергнутые варианты в заметках сессии не записаны.

### Где в коде
`sinhron_storage/src/devsync.rs`, `src/api/simple.rs` (`sync_devices`, `devices_revoke*`, `pairing_send*`). Тест: `devsync::tests::a_disconnected_device_is_remembered_and_synced`.

### Consequences
- **+** Отключённое устройство не возвращается в чаты, что бы ни показал сервер: ни истории, ни переноса.
- **−** Устройство, которое отключили, а потом вошли на нём по 24 словам, не стерев данные приложения (тот же ключ устройства в связке ключей), останется вне чатов: надо «Выйти» на нём (ключ устройства сотрётся) и войти снова, либо привязать по QR. Обычные пути (экран «Устройство отключено → стереть», выход, QR) всегда дают новый ключ.
- **Честные пределы.** Телефон, вошедший по 24 словам на пустое место, списка отключённых не знает, пока не получит его от другого своего устройства. Собеседники по-прежнему полагаются на подписанный отзыв (ADR-075).
- На телефоне не проверено.

---

## ADR-105 · Облачная копия считается недоверенной по происхождению (2026-11-12)

Аудит 2026-11b, находка BKP-1 (запись 257). Простой вариант, без смены формата — старые копии открываются как раньше.

### Context
Корень копии запечатан на открытый ключ аккаунта и не подписан устройством. Бывшее устройство с доступом на запись в облако владельца может подложить «копию», которую откроют 24 слова, и через неё — свои ключи аккаунта, отметки «проверено», часы из будущего.

### Decision
1. Закончив восстановление из облака, телефон сам делает **новое поколение** ключей аккаунта (то, что принесла копия, остаётся только для открытия старых конвертов и копий). Остальные устройства получают его через группу своих устройств (ADR-103 делает это рабочим).
2. Отметки `verified:*` из облачной копии не берутся (`storage::transfer::strip_for_backup`); из переноса с моего устройства по MLS — берутся.
3. Часы настроек из копии и переноса обрезаются до «сейчас + сутки»; запись синхронизации с часами дальше этого не применяется (DEV-2); номер поколения не переполняется.
4. Корень с датой дальше «сейчас + сутки» не считается копией (`chat_restore_info`).

### Alternatives
- **Подпись корня ключом устройства** — не сделано: пока принимаются старые неподписанные копии, она ничего не закрывает. Требует отказа от старых копий (решение владельца).

### Где в коде
`sinhron_sync/src/{backup.rs,transfer.rs}`, `sinhron_storage/src/transfer.rs`, `src/api/{backup.rs,simple.rs}`. Тесты: `transfer::tests::a_backup_brings_no_verified_marks_and_no_future_clocks`, `two_clients_actions_end_to_end`.

### Consequences
- **+** Подложенная копия не закрепляет чужие ключи аккаунта, отметки «проверено» и часы из будущего.
- **−** После восстановления из облака отметки «проверено» пропадают.
- **Честные пределы.** Поддельные сообщения и имена из подложенной копии по-прежнему попадут в историю — это требует подписи и отказа от старых копий (решение владельца).
- На телефоне не проверено.

---

## ADR-109 · Предупреждение RUSTSEC-2026-0459 (SQLite) игнорируем до 2027-02-01; установщик при сомнении останавливается, а не продолжает молча (2026-11-12)

Аудит безопасности 2026-11b, области 10-deploy и 11-supply-chain. Уточняет пункт 5 ADR-090 (`install.sh --commit`).

### Context
Еженедельная проверка библиотек (`.github/workflows/audit.yml`) красная с 9 ноября: вышло предупреждение RUSTSEC-2026-0459 про C-библиотеку SQLite (`libsqlite3-sys` < 0.39, подделанный файл -wal). Всегда красная проверка перестаёт быть сигналом. Аудит 2026-11b (области 10-deploy и 11-supply-chain) критичных и высоких находок не дал; из остальных нужно было выбрать, что чинить за час до выкладки, которую владелец делает сам.

### Decision
1. **`RUSTSEC-2026-0459` внесён в игноры `audit.yml`** с причиной и сроком пересмотра **2027-02-01** (или раньше — при следующем подъёме openmls / rusqlite). Причина: в сервере библиотека не собирается (только строка в lock от необязательного sqlx-sqlite); в телефоне она есть (SQLCipher), но приложение открывает только свои, локально созданные зашифрованные базы; исправленная версия требует rusqlite 0.41 / Rust 1.89, которые не берёт `openmls_sqlite_storage 0.3.0`.
2. **Установщик и скрипт копий при сбое останавливаются с понятным сообщением**, а не доводят дело до «Sinhron работает»: пустой результат не пишется поверх `.env`; `--commit` при локальных правках — стоп; неудачный `pg_dump` не получает имя хорошей копии.
3. **Всё, что меняет поведение работающего сервера и не проверяется здесь тестом** (Caddy, compose, ntfy, coturn, образы Docker, `--locked` в Dockerfile), **не тронуто** — записано в tech-debt.

**Проще не бывает:** одна строка игнора; правки установщика — по 3–10 строк, каждая с тестом в `server/scripts/install_test.sh`. Новых служб, инструментов и настроек нет.

### Alternatives
- **Раздельные списки игноров `cargo audit` для сервера и телефона** (rs-server:7). Не делались: игнор общий для обоих lock-файлов, как и остальные четыре; записано в tech-debt.
- **Поднять rusqlite до исправленной версии сейчас.** Нельзя: нужна rusqlite 0.41 / Rust 1.89, их не берёт `openmls_sqlite_storage 0.3.0`.

### Где в коде
`.github/workflows/audit.yml` (игнор); `server/install.sh` (`write_file`, `write_env`, `setup_backups`, `fetch_code`, `prepare_config_dir`); `server/scripts/backup.sh` (`save`, `keep`); `server/scripts/install_test.sh`.

### Consequences
- **+** Еженедельная проверка библиотек снова зелёная и снова сигнал.
- **+** Сбой при установке или ночной копии виден сразу: `.env` и хорошая копия дня не затираются.
- **−** Игнор общий для обоих lock-файлов (rs-server:7, в tech-debt).
- **−** Если владелец когда-нибудь запустит обновление с `--commit` из папки с локальной правкой, установщик теперь остановится и скажет, что сделать (раньше молча оставлял старый код).
- **Проверено:** `bash server/scripts/install_test.sh` — 169 passed, 0 failed; `cargo audit` с ключами из `audit.yml` — exit 0 на обоих lock-файлах; настоящий `install.sh --dry-run` на Ubuntu 24.04 — выход 0. На работающем сервере не проверено.

**Дата принятия:** 2026-11-12.


---

## ADR-110 · Звонки: dynacast выключен; неподтверждённая сервером дорожка останавливается, микрофон — завершает звонок (2026-11-12)

Аудит 2026-11b, область 05 (звонки), находки 05/C-11 (CALL-darte2ee-1) и 05/C-12 (CALL-darte2ee-2).

### Context
Сервер LiveKit мог получить звук/видео без шифрования кадров двумя способами (livekit_client 2.7.0):
- **(а) попросив «резервный кодек»** (C-12): при `dynacast: true` одно сообщение `SubscribedQualityUpdate` с другим кодеком открывает второй отправитель той же камеры/экрана; `BackupVideoCodec.enabled` на этом пути не читается, шифратор на него не ставится.
- **(б) промолчав в ответ на публикацию** (C-11): дорожка попадает на соединение до ответа сервера, шифратор кадров ставится только по `LocalTrackPublishedEvent`; сервер молчит → через 10 с `TrackPublishException`, отправитель остаётся без шифратора, приложение только писало в лог.

### Decision
1. **`dynacast: false`** в `callRoomOptions`; моя видеодорожка принимается (`callTrackEncrypted`) только с кодеком VP8 / H.264 / H.265. VP9/AV1, навязанные сервером, включают dynacast обратно — звонок завершается как «не зашифрован».
2. **После любой неудачной публикации** (микрофон, камера, экран, смена камеры) — `callPublishFailed(room)`: отправитель с «ничьей» дорожкой (ею не владеет ни одна публикация) останавливается всегда. Камера или показ экрана — звонок идёт дальше со звуком (потерянный ответ на плохой сети не должен обрывать звонок); микрофон — звонок завершается с причиной `e2ee_downgrade`. Обычный отказ (нет камеры, нет разрешения, отмена выбора экрана) отправителя не оставляет — звонок идёт дальше.

Обе правки — в приложении, без своей копии livekit_client.

### Alternatives
- **Своя копия livekit_client** (шифратор до negotiate, выход из `publishAdditionalCodecForPublication`) — надёжнее, но большая; решение владельца.

### Где в коде
`client_flutter/lib/features/calls/livekit_engine.dart` (`callRoomOptions` с `dynacast: false`, `callTrackEncrypted`, `callPublishFailed`), `call_quality.dart`, `active_call_provider.dart`, `call_screen_share.dart`; тесты `test/features/calls/call_backup_codec_test.dart`, `call_publish_guard_test.dart`.

### Consequences
- **+** Сервер звонков не может одним сообщением получить вторую, незашифрованную копию видео; дорожка, которую сервер не подтвердил, не идёт открытой весь звонок.
- **−** Без dynacast сервер не может попросить телефон не слать слои видео, которые никто не смотрит: чуть больше трафика и батареи в групповых видеозвонках. Вернуть dynacast можно только вместе со своей копией livekit_client.
- **−** Окно до 10 с при молчащем сервере остаётся (tech-debt 2.64).
- **−** Честный тайм-аут публикации на плохой сети: камера/экран не включается, звонок идёт со звуком; неподтверждённый микрофон завершает звонок как «не зашифрован» (повторной попытки и честного текста про связь нет) — редко, fail closed.
- **−** `callPublishFailed` читает внутреннее поле библиотеки (`room.engine.publisher.pc`) — при обновлении livekit_client перепроверить.
