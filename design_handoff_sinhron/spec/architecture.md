# Техническая спецификация: open-source self-hosted E2E-шифрованный мессенджер

**Имя проекта:** `Sinhron` (далее по тексту — Продукт).
**Версия документа:** 1.0 (от 18 мая 2026 г.).
**Адресат документа:** Claude Code (исполнитель реализации) и Владелец (архитектор/ревьюер).
**Назначение:** единая, исчерпывающая архитектурно-техническая спецификация. Документ содержит решения, принятые архитектором; Claude Code на его основе пишет код. Кода в документе нет принципиально — только архитектура, обоснования, имена и точные версии библиотек, ограничения, антипаттерны и план работ.

---

## 1. Executive Summary

Продукт — кроссплатформенный (iOS, Android, Windows, macOS, Linux) E2E-шифрованный мессенджер с собственным сервером, который должен быть развёрнут силами self-hoster'а одной командой `docker compose up -d`. Продукт ориентирован на масштаб **до 10 000 активных пользователей на инстанс**, не предполагает федерации, и спроектирован так, что владелец сервера **не имеет технической возможности прочитать содержимое сообщений** — сервер обрабатывает исключительно шифротекст и метаданные доставки, минимизированные настолько, насколько это технически разумно.

**Ключевые технологические решения (зафиксированы; пересмотру в рамках 1.0 не подлежат):**

* **UI:** Flutter (стабильная ветка 3.41.5; Dart 3.11) — единая кодовая база на пять платформ. Поверх Flutter применяется собственная дизайн-система; `material.dart`/`cupertino.dart` используются **только** как источник примитивных виджетов в редких случаях, виджеты `Scaffold`/`AppBar`/`CupertinoNavigationBar` и пр. со значениями по умолчанию запрещены.
* **Общая бизнес-логика и криптография:** Rust-библиотека (далее — Core), линкуемая в Flutter через **flutter_rust_bridge 2.11.1** (на момент написания — официальный Flutter Favorite; зрелое, активно сопровождаемое FFI-bridge решение, обеспечивающее автоматическую генерацию связки Rust↔Dart, поддержку async/await в обе стороны, опаковые типы, потоки `Stream` и нулевой ручной FFI-boilerplate).
* **Backend:** Rust + **Axum 0.8.9** + **Tokio 1.47.3 LTS** (LTS до сентября 2026, MSRV 1.70) + **sqlx 0.8.6** для PostgreSQL.
* **СУБД:** **PostgreSQL 16+** (использование специфичных для PG функций — `LISTEN/NOTIFY`, JSONB, partitioning, generated columns — разрешено и приветствуется; SQLite на сервере не используется).
* **Медиа-сервер для аудио/видео:** self-hosted **LiveKit v1.11.0** (SFU на Go, выпуск 17 апреля 2026 г.). Клиентская интеграция — через Rust SDK `livekit` (0.7.x) внутри Core либо через готовый Flutter SDK `livekit_client` — окончательный выбор зафиксирован в §10.
* **TURN/STUN:** **coturn 4.6.3** в Docker, режим `network_mode: host` обязателен из-за широкого диапазона media-портов.
* **Reverse proxy / TLS:** **Caddy 2.x** с автоматическим Let's Encrypt (TLS-ALPN-01 и/или HTTP-01).
* **Криптопротокол:** MLS — **RFC 9420** в реализации **OpenMLS 0.8.1** (Rust, MIT-лицензия, разрабатывается Cryspen / Phoenix R&D, поддержанные Sovereign Tech Fund; основная шифрсюита `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`). Никаких самописных Double Ratchet и Sender Keys.
* **E2EE для медиа в звонках:** **SFrame — RFC 9605** (август 2024 г.), ключи выводятся из MLS exporter согласно §5.2 RFC 9605.
* **Развёртывание:** Docker Compose (single-host self-hoster). Kubernetes на этом масштабе не нужен и не поддерживается официально.

---

## 2. Глоссарий (контекст для Claude Code)

* **MLS (Messaging Layer Security, RFC 9420)** — IETF-стандарт E2E-шифрования групповых сообщений, опубликован 19 июля 2023 г. Заменяет в нашем проекте все классические подходы Signal (Double Ratchet, Sender Keys, X3DH) единым протоколом, обеспечивающим forward secrecy, post-compromise security, асинхронность и масштабируемость до десятков тысяч членов.
* **TreeKEM** — древовидная структура распределения ключей внутри MLS-группы; обеспечивает логарифмическую стоимость операций add/remove/update по числу членов.
* **Epoch / Commit / Welcome / KeyPackage / Proposal** — базовые понятия MLS (RFC 9420 §5–§12). Каждое изменение состава группы или ротация ключей переводит группу в новую epoch; новый член получает текущий стейт через `Welcome`-сообщение; будущие участники заранее публикуют `KeyPackage` на сервере.
* **Exporter Secret / MLS-Exporter** — функция RFC 9420 §8.5, выводящая прикладные ключи из текущей epoch:
  `MLS-Exporter(Label, Context, Length) = ExpandWithLabel(DeriveSecret(exporter_secret, Label), "exported", Context, Length)`.
  Внутренний префикс ExpandWithLabel — `"MLS 1.0 " + Label`.
* **HPKE (RFC 9180)** — гибридное публичное шифрование, на котором строится `KeyPackage` MLS.
* **Sealed Sender** — концепция, заимствованная у Signal (2018, реализована Signal officially rolled out for multi-device in 2024), при которой идентификатор отправителя зашифрован внутри конверта от получателя так, что сервер не знает, кто отправил конкретное сообщение. В нашем дизайне реализуется поверх MLS (см. §6.5).
* **SFrame (RFC 9605)** — Lightweight Authenticated Encryption для media-фреймов, разработан в IETF SFRAME WG (Cisco/RingCentral), стандартизован в августе 2024. Применяется поверх SRTP в звонках через SFU. Криптоключи выводятся из `MLS-Exporter("SFrame 1.0 Base Key", "", AEAD.Nk)` (RFC 9605 §5.2).
* **SFU (Selective Forwarding Unit)** — медиа-сервер, который пересылает зашифрованные media-пакеты, не имея доступа к содержимому. LiveKit — наш SFU.
* **FFI (Foreign Function Interface)** — механизм вызова кода Rust из Dart. В нашем случае инкапсулирован flutter_rust_bridge.
* **flutter_rust_bridge (frb)** — кодогенератор FFI-биндингов между Rust и Dart, получивший статус **Flutter Favorite** в первой партии из 7 пакетов при перезапуске программы. Текущая стабильная — 2.11.1 (релиз 1 октября 2025 г.).
* **OpenMLS** — Rust-имплементация RFC 9420 от Phoenix R&D и Cryspen, под MIT-лицензией. Текущая стабильная — 0.8.1 (на crates.io; pre-release 0.7.0-pre.1 — 15 июля 2025, 0.6.0 — 4 сентября 2024).
* **mls-rs** — альтернативная имплементация MLS от AWS Labs. Не используется (см. §5.3 «обоснование выбора»), но упомянута здесь, чтобы Claude Code не подменял её случайно.
* **PCS (Post-Compromise Security)** — свойство протокола восстанавливать конфиденциальность после компрометации ключа в результате последующего update'а; в MLS обеспечивается операциями `Update` и `Commit`.
* **BIP-39** — стандарт мнемонических фраз восстановления (12/24 английских слова), применяется для resilient recovery приватного ключа идентичности пользователя. Крейт — `bip39 2.2.2` (rust-bitcoin/rust-bip39).
* **BlurHash** — компактное представление превью изображения (~20–30 ASCII-символов), используется как плейсхолдер до загрузки шифрованного thumbnail.
* **HKDF / AEAD / Nk / Nn** — стандартные обозначения KDF, симметричного аутентифицированного шифрования и длины ключа/nonce, см. RFC 5869, RFC 5116.

---

## 3. Product Vision и непереговариваемые принципы

1. **E2EE always on.** Plaintext-режима в Продукте нет, ни «для удобства», ни «для отладки», ни «для админов». Любая функция, которая концептуально не может работать в E2EE-модели (полнотекстовый поиск по серверу, server-side preview), не реализуется на сервере и решается локально на клиенте либо не реализуется вовсе.
2. **Сервер не доверенный.** Архитектура исходит из того, что владелец сервера, root-доступ к серверу и сам бинарь сервера потенциально враждебны. Сервер видит: метаданные доставки (отправитель → получатели → размер шифротекста → таймстемп), KeyPackages, шифротексты сообщений, шифротексты blob'ов. Сервер не видит: содержимое сообщений, имена пользователей в открытом виде в payload'ах (только их хеши/UUID при необходимости), список контактов пользователя, фактический состав групп с точки зрения plaintext display name.
3. **No telemetry, no analytics, no «phone home».** Клиент не отправляет на разработчика никаких данных. Опциональный crash reporting — только локально в файл; пользователь может вручную приложить лог к bug report.
4. **Premium UX.** Продукт сравнивается не с Element/Wire, а с Telegram и Signal по плавности анимаций, отзывчивости, качеству типографики и звуковому/тактильному дизайну. UI на Material-defaults недопустим.
5. **Простой self-host.** Целевая аудитория self-hoster'а — IT/DevOps-инженер уровня middle+. Развёртывание = `git clone && cp .env.example .env && edit .env (3 переменные) && docker compose up -d`. Никакого Kubernetes, никаких Helm-чартов, никакой Ansible-обвязки в комплекте.
6. **Reproducible builds.** К версии 1.0 клиентские бинарники должны быть воспроизводимы из исходников (соответствующие CI-пайплайны и SOURCE_DATE_EPOCH).

---

## 4. Обзор системной архитектуры

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              КЛИЕНТЫ (Flutter UI + Rust Core)                │
│  iOS │ Android │ Windows │ macOS │ Linux                                     │
│  ┌─────────────────────────┐    ┌────────────────────────────────────────┐   │
│  │   Flutter UI (Dart)     │◄──►│   Rust Core (libsinhron_core.{a,so,…}) │   │
│  │   Riverpod 3 / go_router│ FFI│   OpenMLS · sqlx(SQLite) · tokio       │   │
│  │   кастомный design syst.│ frb│   sframe-rs · livekit · sealed-sender  │   │
│  └─────────────────────────┘    └────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────────┘
                  ▲                          ▲                       ▲
                  │ WebSocket (wss://)       │ HTTPS (REST)          │ WebRTC (DTLS-SRTP)
                  │ subprotocol: sinhron.v1  │ keypackages, uploads, │ + SFrame E2EE
                  │                          │ pagination history    │ (ключ из MLS-exporter)
                  ▼                          ▼                       ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                                  Caddy (TLS-edge)                            │
│         автоматический Let's Encrypt, HTTP/2 + HTTP/3, security headers      │
│                                       │                                      │
│      ┌────────────────────────────────┼─────────────────────────────────┐    │
│      ▼                                ▼                                 ▼    │
│ ┌──────────────────────┐  ┌────────────────────────┐  ┌──────────────────┐   │
│ │  sinhron-server      │  │  LiveKit v1.11.0       │  │  coturn 4.6.3    │   │
│ │  (Rust+Axum 0.8.9)   │  │  SFU (Go)              │  │  TURN/STUN (host │   │
│ │  WS + REST + push    │  │  WHIP/WebRTC           │  │  network mode)   │   │
│ └──────────┬───────────┘  └────────────────────────┘  └──────────────────┘   │
│            │                                                                 │
│            ▼                                                                 │
│ ┌──────────────────────┐  ┌────────────────────────┐                         │
│ │  PostgreSQL 16+      │  │  Object storage        │                         │
│ │  ciphertext, meta    │  │  (local FS volume,     │                         │
│ │  partitioned tables  │  │   content-addressed by │                         │
│ │                      │  │   SHA-256 ciphertext)  │                         │
│ └──────────────────────┘  └────────────────────────┘                         │
└──────────────────────────────────────────────────────────────────────────────┘
                                       │
                                       ▼
                          ┌─────────────────────────┐
                          │   Push notification     │
                          │   gateways (FCM, APNs)  │
                          │   — encrypted payload   │
                          └─────────────────────────┘
```

**Принципиальная схема потоков данных:**

* **Управляющий канал клиент↔сервер** — единый WebSocket, поверх которого ходят: входящие/исходящие MLS-фреймы, presence, typing, signaling для звонков (LiveKit token issuance + ICE-кандидаты передаются через сервер мессенджера, но затем медиа уходит напрямую клиент↔LiveKit).
* **Загрузка/выгрузка медиа** — отдельные HTTPS-запросы к sinhron-server. Шифрование медиа делается **до** отправки на сервер; имя файла на сервере = SHA-256(ciphertext).
* **Real-time медиа** — WebRTC, ключи SFrame выведены из MLS-exporter текущей epoch соответствующей группы/комнаты.
* **Push notifications** — payload не содержит plaintext; всегда контейнер `{"chat_id": <opaque>, "message_uuid": <uuid>}`, который заставляет клиент проснуться и забрать шифротекст через WS.

---

## 5. Спецификация Rust Core

### 5.1. Назначение

Rust Core — единственный носитель криптографии, бизнес-логики, локального хранилища и сетевого транспорта на клиенте. Dart-слой не должен содержать ничего, кроме UI, навигации и тонкого state-management над данными, поставляемыми из Core. Plaintext длительного хранения не должен попадать в Dart heap; всё, что Dart получает, — это View-Model'и, которые Core готовит специально для UI.

### 5.2. Структура крейтов (Cargo workspace)

Workspace на клиенте состоит из нескольких крейтов; верхнеуровневый крейт `sinhron_core` — фасад с публичным frb-API.

* `sinhron_core` — фасад, экспонируемый в Flutter. Только этот крейт знает про `flutter_rust_bridge`.
* `sinhron_crypto` — обёртки над OpenMLS, sframe-rs, BIP-39, sealed sender envelope. Изолированный, не зависит ни от транспорта, ни от хранилища.
* `sinhron_storage` — local persistence (sqlx с SQLite-driver на клиенте; encrypted-at-rest через SQLCipher либо через application-level AES-GCM поверх sqlite — см. §6.7). Schema migrations через `sqlx::migrate!`.
* `sinhron_net` — WebSocket-клиент (tokio-tungstenite), HTTP-клиент (reqwest с rustls), reconnection/heartbeat-state-machine.
* `sinhron_sync` — sync state machine: применение входящих MLS-фреймов, deduplication, ack/resume tokens, ордеринг.
* `sinhron_call` — интеграция с LiveKit, SFrame, key management для media.
* `sinhron_cli` — отдельный бинарь `sinhron-cli` для интеграционных тестов криптографии и ручного отладочного использования (Фаза 1 заканчивается рабочим CLI, в котором две инстанции в одном Docker Compose обмениваются MLS-сообщениями).

### 5.3. Обоснование выбора OpenMLS, а не mls-rs

* OpenMLS старше как проект, имеет публичный academic-аудит, авторы (Phoenix R&D, Cryspen) — соавторы спецификации RFC 9420.
* OpenMLS уже имеет экспериментальную PQ-поддержку (X-Wing KEM, merge #1546), что важно для пункта 19 (post-quantum migration).
* mls-rs (awslabs/mls-rs) — отличный проект, но он более тесно увязан с экосистемой AWS Wickr и имеет иную модель storage providers; миграция между ними нетривиальна, поэтому выбор делается **сейчас и однозначно** в пользу OpenMLS.

### 5.4. Точные версии (pin exact!)

В `Cargo.toml` все версии указываются **точно** (без `^`, `~`, без range), как того требует §18.

| Крейт | Версия (на 18 мая 2026) | Назначение |
|---|---|---|
| `openmls` | `0.8.1` | MLS engine |
| `openmls_rust_crypto` | совместимая с 0.8.1 | RustCrypto-based MLS provider |
| `openmls_basic_credential` | совместимая | BasicCredential + Ed25519 |
| `tokio` | `1.47.3` (LTS до сентября 2026, MSRV 1.70) | Async runtime |
| `axum` | `0.8.9` | HTTP/WS на бэкенде |
| `tokio-tungstenite` | `0.29.x` (как требует axum 0.8.9 и совместимый клиент) | WS на клиенте |
| `sqlx` | `0.8.6` | DB-driver (postgres на сервере, sqlite на клиенте) |
| `flutter_rust_bridge` | `2.11.1` | FFI bridge |
| `bip39` | `2.2.2` | Recovery phrase |
| `sframe` | актуальный стабильный 0.6.x (см. крейт `sframe` в crates.io, github.com/TobTheRock/sframe-rs) — версия пинуется на момент скаффолдинга | SFrame RFC 9605 |
| `livekit` | `0.7.34` (релиз 23 марта 2026, livekit-api 0.4.14) — внутренне production-used, но 0.x, поэтому версия пинуется, бамп — отдельным MR | LiveKit Rust SDK |
| `tracing` + `tracing-subscriber` | актуальные | Structured logging |
| `ring` | актуальный | дополнительные крипто-примитивы (random, HKDF), только если не покрыто RustCrypto |
| `serde`, `serde_json`, `prost` | актуальные | сериализация |
| `uuid` | актуальный (v7 для message_id) | идентификаторы |

> **DO NOT** автоматически апгрейдить `openmls` или `flutter_rust_bridge` минорной версии: оба пре-1.0 и могут содержать ломающие изменения. Любой апгрейд — отдельный тикет с написанием migration-теста.

### 5.5. Принципы публичного API (Rust → Flutter)

* **Все долгие операции — async.** Возвращают `Future<T, CoreError>`. Синхронный API допустим только для тривиальных геттеров (например, «дай мне локальный user_id»).
* **Streams для live-данных.** Список чатов, входящие сообщения, presence-апдейты, статус соединения — экспонируются как `Stream<…>`, реализованные через frb-stream-sink, в Dart представлены как `Stream<…>`.
* **Единый тип ошибки.** `CoreError` — enum с дискриминантами (`NetworkError`, `CryptoError`, `StorageError`, `ProtocolViolation`, `NotFound`, `Forbidden`, `Unrecoverable`). В Dart он приходит как `sealed class`/`freezed`-эквивалент (frb 2.x умеет это нативно).
* **Опаковые типы.** Идентификаторы (UserId, ChatId, MessageId, MlsGroupId) — `RustOpaque` либо тонкие newtype-структуры, **не** просто `String` в Dart. Это предотвращает случайное конкатенирование/логирование плэйнтекста.
* **Никаких `unwrap()`/`expect()`** в публичном API. Внутренние инварианты — да; на границе FFI — никогда.
* **Threading model:** frb 2.x по умолчанию исполняет async-Rust в worker-пуле tokio. UI-thread (Dart main isolate) **никогда** не блокируется на тяжёлых криптооперациях. Для зеркальных вызовов Rust→Dart (например, «реактивно вытолкни этот ChatPreview в UI») используется механизм frb «Rust call Dart».

### 5.6. Memory ownership (критично, см. §18)

* Все буферы с plaintext в Rust обёрнуты в `secrecy::Secret<…>` / `Zeroizing<Vec<u8>>` и зануляются при drop'е.
* Если plaintext **обязан** покинуть Rust для отрисовки в Dart (текст сообщения в виджет), он копируется один раз в Dart heap и помечается так, чтобы не задерживаться: View-Model'и, содержащие plaintext, имеют короткое время жизни (до выхода из экрана). На клавиатуре/в полях ввода Dart не делает persisted draft без сознательного решения и шифрования через Core.
* Передача crypto-материала (приватных ключей, exporter_secret) из Rust в Dart **запрещена**. Все операции, требующие приватного ключа, выполняются внутри Rust.

---

## 6. Криптографический дизайн

### 6.1. Identity

* Пользователь = долговременная пара ключей подписи (Ed25519) + Basic MLS credential, хранящая отображаемое имя (или его псевдоним) и user-id (UUIDv7).
* Регистрация: клиент локально генерирует ключи, отправляет на сервер `KeyPackageBundle` + публичную часть identity. Сервер хранит только публичную часть; для аутентификации применяется challenge-response: сервер шлёт случайный nonce, клиент подписывает identity-ключом, сервер проверяет подпись (никаких паролей).
* Альтернативный режим — для self-hoster'а, который хочет «инвайт по ссылке»: сервер генерирует одноразовый invite-token, привязанный к будущему identity-ключу.

### 6.2. Multi-device

* **Каждое устройство — отдельный leaf** в MLS-группе. Это решение принципиально и зафиксировано: «общий» приватный ключ между устройствами **не используется** (что отличает нас от исторически принятых Signal-схем и совпадает с современной Signal-рекомендацией 2024 г. на multi-account/per-device sessions).
* У одного пользователя — один identity-ключ (используется только как подпись над device-keypackage'ами + для отображаемого fingerprint). Каждое устройство имеет собственный device-keypackage, который сертифицируется identity-ключом.
* Сопряжение устройств — QR-код: новое устройство показывает QR с публичным device-key + одноразовым challenge; уже авторизованное устройство сканирует, подписывает, и через сервер протаскивается `Welcome`-сообщение во все существующие MLS-группы пользователя.
* Удалённый «kick» устройства — это MLS-Commit с `Remove(leaf=that_device)` во всех группах, инициированный с другого устройства того же пользователя.

### 6.3. Жизненный цикл MLS-группы

* **1:1-чат** — это MLS-группа из 2N leaf'ов, где N — число устройств у каждого пользователя.
* **Group chat (до 100 членов в MVP, верхняя архитектурная граница — 1000)** — MLS-группа, где каждый член может иметь несколько leaf'ов.
* **Add member:** инициатор шлёт `Add` proposal + `Commit` на Delivery Service (наш сервер), сервер фан-аутит `Commit` всем существующим членам и `Welcome` — новому.
* **Remove member:** `Remove` proposal + `Commit` инициатора (с правами админа группы; права хранятся в group context extension).
* **Update (ротация ключей):** периодический `Update`-`Commit`, обеспечивающий PCS. Политика: каждое устройство выполняет `Update` не реже 1 раза в 7 дней при наличии активности (см. §6.6 про epoch lifetime).
* **Reinit:** запасной механизм для миграции на новую шифрсюиту/версию протокола; в MVP не используется, но архитектурно поддерживается OpenMLS 0.8.1.

### 6.4. Шифрсюиты

* **Основная (mandatory-to-implement):** `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`. Это MTI для RFC 9420 и для OpenMLS 0.8.1.
* **Опционально включаемая в 1.x:** `MLS_256_DHKEMP384_AES256GCM_SHA384_Ed25519` для регулируемых отраслей. На MVP не нужна.
* **Post-quantum:** не для 1.0. См. §19.

### 6.5. Sealed Sender envelope

Концептуально совместим с Signal Sealed Sender, но переосмыслен под MLS-only мир.

* Внутренний шифр: MLS application message от отправителя к группе. Содержит `{sender_leaf_index, payload}`.
* Внешний конверт: HPKE-шифровка `{group_id, application_message_blob}` под ключом получателя, который сервер использует как «токен доставки». Этот HPKE-ключ — отдельный, недолговечный ключ доставки, ротируемый раз в неделю; сервер видит только, что «кому-то с такой-то delivery-key» пришёл блоб такого-то размера.
* Сервер не видит ни `sender_leaf_index`, ни `group_id`, ни payload.
* Замечание из криптоанализа: учёные эпрейнт-репорта IACR 2026/484 «Signal Lost (Integrity)» показали, что в реализации Signal Sealed Sender в Android была возможность инъекции сообщений из-за пропущенных проверок ключей и потери контекста при пересечении границ между крипто-компонентами. Мы **выводим из этого жёсткое правило**: все криптопроверки на пути decap → MLS-decrypt → identity-verify выполняются **внутри одного Rust-модуля без сериализации/десериализации в промежуточных состояниях**.

### 6.6. Epoch lifetime и storage commit policy

* Сервер хранит **минимум 14 дней** последних MLS-фреймов на группу (для оффлайн-доставки), но при этом forward-secrecy MLS работает корректно: даже имея весь архив шифротекстов, по факту увода ключа уже произошёл `Update` — прошлые сообщения не расшифровываются.
* Клиент периодически делает `Update` (см. §6.3), но не чаще, чем имеет смысл — иначе серверу прилетает паразитный трафик. Политика: один `Update` в день, если в этот день был хоть один отправленный application message; иначе раз в 7 дней.

### 6.7. Локальное защищённое хранилище на клиенте

* **iOS/macOS:** Keychain (через `flutter_secure_storage 10.2.0`). Используется только для master-key, которым на старте дешифруется основная DB.
* **Android:** Android KeyStore (тот же `flutter_secure_storage 10.2.0`). Версия 10.x использует кастомные шифры (по умолчанию RSA-OAEP + AES-GCM) после депрекации Jetpack Crypto; обязательно отключить Google Drive backup для секретов (`android:allowBackup="false"` + `fullBackupContent` exclude rules).
* **Windows:** DPAPI (CurrentUser) через `flutter_secure_storage`.
* **macOS additional:** Keychain Sharing capability должна быть прописана и в Debug, и в Release entitlements (распространённая ошибка: на Hot Restart ключи возвращают null именно из-за этого).
* **Linux:** Secret Service / libsecret (флэтпэк/snap-варианты — отдельная пакетная политика).
* **Основное хранилище** — SQLite в локальной директории приложения, **зашифрованный целиком** через application-level AES-256-GCM от master-key из Keychain. SQLCipher как альтернатива допустим, но не обязателен — single binary без C-зависимости предпочтительнее, поэтому базовый план: чистый SQLite + слой AES-GCM в Rust поверх pages? — нет, это нелепо. Решено: применяем **SQLCipher** в режиме fully-encrypted database, через `rusqlite` с feature `bundled-sqlcipher-vendored-openssl`, и параллельно держим в качестве запасного канала отдельный JSON-blob с журналом ключей. На клиенте `rusqlite` (синхронный) допустим вместо sqlx, поскольку клиентский поток I/O невелик и блокирующие операции выносятся в `spawn_blocking`. Финальное решение зафиксировано так: **на клиенте — `rusqlite` 0.38 + sqlcipher**; **на сервере — `sqlx` 0.8.6 + PostgreSQL**. Эти крейты не конфликтуют, поскольку находятся в разных Cargo-workspace.

### 6.8. Recovery phrase (BIP-39) и owner-encrypted state backup

При создании identity клиент генерирует 24-словную BIP-39 фразу (256 бит энтропии). Из неё через HKDF-Expand(SHA-256, IKM=seed_from_phrase, salt="Sinhron 1.0", info="recovery-key") выводится **recovery-key** (32 байта, AEAD-grade). Эта же фраза при потере всех устройств — единственный источник восстановления recovery-key.

Recovery-key служит сразу двум целям:

1. **Identity recovery** — оборачивает локальный backup долговременного Ed25519 identity-ключа. На устройстве сам identity-ключ хранится в Keychain (см. §6.7); recovery-key оборачивает его копию в локальном файле `identity_backup.enc` для случая «Keychain очищен, но DB цела».
2. **MLS-state recovery** — оборачивает периодически загружаемый на сервер blob с актуальным MLS-состоянием всех групп пользователя (см. §6.8.1 ниже).

Рабочая копия recovery-key хранится в Keychain на каждом авторизованном устройстве — иначе клиент не сможет асинхронно обновлять server-side state-backup. Фраза в открытом виде не сохраняется нигде после первичной демонстрации.

Прочие правила:

* Фраза не сохраняется на сервер. Никогда. Пользователю показывается ровно один раз с обязательным screenshot-блокером (FLAG_SECURE на Android, screen capture protection через `FlutterSecureScreen`-эквивалент). Признаём, что 100% защиты от скриншота не существует; делаем best-effort.
* Крейт — `bip39 2.2.2`, опубликован 5 месяцев назад на момент составления документа; пинуем точную версию.

#### 6.8.1. Owner-encrypted MLS-state backup

**Цель.** При полной потере устройств пользователь, вводя 24-словную фразу на новом устройстве, восстанавливает не только identity, но и **членство во всех MLS-группах** — без необходимости быть «приглашённым заново» каждым контактом. UX-паритет с WhatsApp (где группы возвращаются при re-регистрации по номеру), но без server-mediated trust: сервер не доверенный, он хранит только шифротекст blob'а.

**Что бэкапится.** Локальное MLS-состояние пользователя:

* Для каждой MLS-группы, в которой пользователь является членом: текущий leaf private key (epoch N), group context, ratchet tree (если применимо к provider'у), epoch-secrets, derive history достаточной глубины для catch-up.
* Список pending KeyPackages (своих), которые ещё не были потрачены.
* Логические маппинги: group_id ↔ display-name (display-name хранится только локально, см. §6.5/§7.4), participant aliases и т.п. — то, что нужно UI, чтобы после recovery показать «Family» вместо opaque group_id.

**Что НЕ бэкапится** (умышленно):

* **История сообщений (application-payloads).** Это отдельный, потенциально большой объём (сотни МБ при активной переписке); encrypted history backup — отдельная 1.x фича (см. §19).
* **Локальные drafts, settings UI**, прочая презентационная мелочёвка.
* **Push-tokens, FCM registration IDs** — серверная сторона держит их в `push_subscriptions` (§7.4), при recovery они обнуляются и регистрируются заново.

**Формат blob'а.** CBOR-сериализованная структура, AES-256-GCM-шифрованная под recovery-key:

```
StateBackupBlob {
  version: u32,          // формат самого blob'а, начиная с 1
  version_seq: u64,      // монотонный счётчик ревизий этого пользователя
  identity_pub: bytes,   // публичная часть identity-ключа (для sanity-check)
  groups: [GroupSnapshot { group_id, leaf_index, leaf_priv, epoch_secrets, ratchet_tree_or_view, ... }],
  pending_keypackages: [KeyPackageBundle],
  ui_aliases: { group_id → encrypted display-name, ... }
}
```

Nonce — 12 байт random, AAD — `version_seq` в big-endian (привязывает шифротекст к версии, защищает от rollback-атак сервера).

**Жизненный цикл — клиент.**

* На каждое успешное применение MLS-Commit (любая группа, любая операция) клиент **планирует** новое заполнение blob'а.
* Throttling: не чаще 1 раза в 30 секунд независимо от числа Commit'ов. Если за 30 секунд накопилось много изменений — батчатся в один blob.
* Загрузка через WS-фрейм `StateBackup { version_seq, blob }` (см. §7.3). Сервер проверяет, что `version_seq > последнего сохранённого` (предотвращает race между двумя устройствами одного юзера; см. §6.8.2).
* Размер blob'а в режиме «1-10 групп, до 100 членов в каждой» ожидается 10-100 КБ. Сервер ограничивает максимум **1 МБ** (см. §7.4). При превышении — клиент логирует ошибку и предлагает пользователю покинуть редко используемые группы.

**Жизненный цикл — сервер.**

* Хранение: одна запись на пользователя в таблице `state_backups` (см. §7.4). При получении `StateBackup` с большим `version_seq` сервер **PUT-replace**'ит существующий blob — история не хранится. Это снижает поверхность утечки и упрощает квоты.
* Сервер **никогда** не читает содержимое blob'а — только метаданные (`user_pk`, размер, `version_seq`, `updated_at`).

**Recovery-flow.**

1. Юзер на новом устройстве выбирает «Restore from recovery phrase» (см. §8 UI-spec).
2. Вводит 24 слова → клиент локально выводит `recovery-key`.
3. Клиент логинится на сервере через challenge-response, подписанный заранее восстановленным identity-ключом из встроенного в blob `identity_pub` (нюанс: identity_pub есть в открытом виде в `users` таблице, см. §7.4; identity-priv восстанавливается из BIP-39 seed по стандартной HKDF-схеме, не из blob'а — blob нужен только для MLS-состояния).
4. Клиент запрашивает `GET /v1/state_backup` → сервер отдаёт blob.
5. AEAD-расшифровка → получаем `StateBackupBlob`.
6. Для каждой группы из `blob.groups`: восстанавливаем MLS leaf, запрашиваем у сервера все Commit'ы для этого group_id с `epoch > blob.groups[i].epoch` (сервер хранит их per retention §7.6), применяем по порядку → leaf оказывается в актуальном epoch.
7. После catch-up'а юзер сразу «в группах», получает входящие application-messages с текущего момента (история до момента backup'а на других устройствах — недоступна, но если хоть одно старое устройство ещё цело, оно может re-share через стандартный application-уровневый «share message history» поток — это **out of scope для 1.0**).

**Криптографические гарантии.**

* Сервер видит: размер blob'а, частоту его обновлений, монотонный `version_seq`. Содержимое — нет.
* Утеря recovery phrase = blob становится непрочитаемым мусором (KDF не обратима, ключа нет). Это сознательный trade-off в пользу минимизации серверного доверия: лучше потерять группы, чем дать ключ серверу или облачному key-recovery-сервису.
* Компрометация сервера + утечка recovery phrase (например, social engineering) = полное вскрытие state'а. Эквивалентно компрометации одного из устройств пользователя — после чего юзер выполняет MLS Remove (PCS) и forward secrecy продолжает работать вперёд.
* Замечание из §6.5: все криптопроверки на пути decap → MLS-decrypt → identity-verify также применяются на recovery-flow при первом приёме application-messages новым устройством.

#### 6.8.2. Multi-device race на одном пользователе

Когда у пользователя два устройства A и B (оба live), оба пишут в свой локальный MLS-state и оба пытаются обновлять server-side blob:

* Сервер хранит **один** blob на пользователя, разрешает только monotone-increasing `version_seq`.
* Каждое устройство ведёт собственный `version_seq` (например, 64-битная hibyte-устройство-id + lobyte-локальный-счётчик). Это даёт total order даже без координации между устройствами.
* При коллизии (`version_seq` уже отстаёт): клиент GET'ит текущий blob, мерджит свои локальные изменения (фактически просто пересоздаёт snapshot из своего MLS-state), увеличивает `version_seq` за пределы текущего серверного, PUT'ит заново.
* В терминах CAP: state-backup eventually-consistent; целостность гарантирована тем, что MLS-state на устройстве — source of truth, а blob — кэш для recovery. При recovery приходит whichever blob был последним, и MLS catch-up через сервер закрывает gap.

Это решение **не идеально** в edge-case'е «оба устройства умерли с разным состоянием в один и тот же момент»: возьмётся blob того устройства, что записал последним. Архитектурно приемлемо; в 1.x можно добавить per-group versioning, чтобы мерджить state по группам индивидуально.

### 6.9. Шифрование медиафайлов

* Перед загрузкой клиент генерирует random `media_key` (32 байта). Файл шифруется AES-256-GCM с этим ключом, nonce — 12 байт random, AAD — пустой.
* Имя на сервере = SHA-256(ciphertext).
* В сопровождающем MLS-сообщении (приложение-уровень) передаются: `{file_uri, media_key, sha256, mime_type, size, optional_thumbnail_blurhash}`.
* Превью (если применимо): отдельный маленький зашифрованный blob, плюс BlurHash-хеш в metadata для мгновенного UI-плейсхолдера.

---

## 7. Спецификация Backend

### 7.1. Общая структура Axum-сервиса

* Бинарь — `sinhron-server`. Cargo workspace с крейтами `server-bin`, `server-http`, `server-ws`, `server-db`, `server-push`.
* HTTP-стек: Axum 0.8.9 + Tower middlewares (tracing, compression `tower-http`, rate-limit, request-id). MSRV — 1.75 (требование axum 0.8).
* TLS терминируется на Caddy; Axum слушает plain HTTP на `127.0.0.1:<port>` за reverse-proxy. Внутри Docker network — без TLS, наружу — только через Caddy.

### 7.2. Категории эндпоинтов

* **Auth и identity:**
  * Регистрация по invite-token (опц.) либо по открытой регистрации (флаг конфигурации).
  * Challenge-response для signature-auth.
  * Publication of `KeyPackages` (PUT новых; pre-keys имеют TTL и количество, ниже которого сервер не падает, но клиент пополняет).
* **MLS delivery:**
  * Отправка `Commit`/`Welcome`/`application_message` (POST).
  * Подписка на входящий поток — через WS (см. §7.4).
* **Group state:**
  * Получение текущего `GroupInfo` (для join-by-link сценариев — отдельный «external join» поток MLS).
* **Media:**
  * `POST /media` — chunked upload зашифрованного блоба. Хеш проверяется на серверной стороне (это не криптографическая проверка содержимого, а только защита от bit-flip и от двойной загрузки).
  * `GET /media/{sha256}` — раздача шифротекста с долгоживущим Cache-Control. Авторизация — bearer-token на ту же WS-сессию.
* **Push token registration:** клиент регистрирует свой FCM/APNs token; сервер хранит mapping `delivery_key → token` (см. §9).
* **Health:** `/healthz`, `/readyz` — стандартные probe-endpoints.
* **Метрики:** `/metrics` (см. §12).

### 7.3. WebSocket-протокол

* URL: `wss://<host>/v1/sync`.
* Subprotocol negotiation: `Sec-WebSocket-Protocol: sinhron.v1`.
* Кадры: бинарные, формат — Protobuf (или CBOR — выбор за Claude Code, но **один формат** на весь продукт, не смешивать; рекомендация: Protobuf, потому что есть schema-registry и кодогенерация для Dart/Rust).
* Типы кадров: `Hello`, `Auth`, `Heartbeat` (раз в 30 с, таймаут 75 с), `Resume`, `Ack`, `Push` (server→client с новым MLS-фреймом), `Submit` (client→server с исходящим фреймом), `Presence`, `Typing`, `Receipt`.
* **Resume token.** При обрыве соединения клиент при reconnect передаёт `last_acked_seq` per stream. Сервер либо доставляет недостающее (если cursor в пределах хранения), либо отвечает `ResumeImpossible` и клиент уходит в full-resync.
* Delivery semantics: **at-least-once**, дедупликация — по UUID v7 message_id, который клиент кладёт в обёртку. Дедуп — на клиенте при применении в Core.
* Очерёдность: внутри MLS-группы — строгий порядок (MLS требует in-order delivery `Commit`'ов; сервер сериализует их).

### 7.4. Схема PostgreSQL (описательно)

DDL не приводим — Claude Code пишет миграции через `sqlx migrate`. Описание сущностей:

* `users` — UUIDv7 PK, identity public key, registration timestamp, status. **Без display name в открытом виде**; если self-hoster хочет search-by-handle, handle хранится отдельно с явным согласием пользователя и помечается флагом.
* `devices` — devices таблица: device_pk → user_pk, device-credential, last_seen, push_token (если есть).
* `keypackages` — pool заранее опубликованных KeyPackage'ов; row-level lock при выдаче (consume-once semantics).
* `mls_groups` — group_id (opaque opacque blob, не plaintext название), создатель, время создания.
* `group_members` — derived view, серверная сторона знает «кто в какой группе» по факту fan-out'а; **plaintext название группы сервер не хранит**.
* `messages` — message_id (UUIDv7), group_id, sender_device_pk (или null при Sealed Sender), ciphertext (bytea), ts. **Партиционирование по месяцу** (PostgreSQL native range partitioning). Retention — конфигурируемый, по умолчанию 14 дней; cron-job дропает старые партиции.
* `media` — sha256 (PK), size, uploaded_by, ts, ref_count. Уборка — по ref_count==0 спустя TTL.
* `push_subscriptions` — отдельная таблица сопоставлений «delivery_key → fcm_or_apns_token». Сама delivery_key opaque.
* `state_backups` — owner-encrypted backup MLS-состояния пользователя (см. §6.8.1). Одна запись на пользователя: PK = `user_pk`, `blob` (bytea, AES-256-GCM-шифротекст ≤ **1 МБ**, иначе INSERT/UPDATE отклоняется), `version_seq` (bigint, монотонный — UPDATE принимается только если `NEW.version_seq > OLD.version_seq`), `updated_at` (timestamptz). PUT-replace семантика; история ревизий не хранится. Без партиционирования (один row на юзера, мало строк).

Все таблицы с большим оборотом (`messages`) — партиционируются. `keypackages` — горячая, лёгкая, без партиционирования. `state_backups` — лёгкая, ~10-100 КБ на запись.

### 7.5. Миграции

`sqlx migrate`. Все миграции — forward-only. Откат — через явный inverse-migration новой миграцией, а не `down.sql`. Каждая миграция файлируется с `<timestamp>_<purpose>.up.sql` и сопровождается интеграционным тестом, что миграция применима на пустой и на заполненной testing-fixture базе.

### 7.6. Retention и хранение

* Сообщения: 14 дней по умолчанию, конфигурируемо через env `SINHRON_MESSAGE_RETENTION_DAYS`.
* KeyPackages: TTL 30 дней, либо до consume.
* Media: 90 дней с момента последнего GET, либо немедленно при ref_count==0.
* Аккаунты неактивные >365 дней — soft-mark, через 30 дней — purge (опц., конфигурируется).

---

## 8. Спецификация Flutter-клиента

### 8.1. Структура каталогов

```
client_flutter/
  pubspec.yaml                       # все версии пинуются точно
  lib/
    main.dart                        # точка входа, инициализация Core, ProviderScope
    app/
      app.dart                       # MaterialApp.router → но с кастомной темой "из пустого"
      router.dart                    # go_router 17.1.0 — declarative
      theme/                         # design tokens
    core/
      ffi/                           # сгенерированные frb-биндинги (НЕ редактировать руками)
      providers/                     # Riverpod-провайдеры тонкого слоя над Core
    features/
      chat_list/
      chat_view/
      composer/
      call/
      settings/
      device_pairing/
    widgets/
      ds_*                           # design-system widgets (DsButton, DsAvatar, …)
    l10n/                            # ICU ARB-файлы
  test/
  integration_test/
  android/ ios/ macos/ windows/ linux/
```

### 8.2. State management — Riverpod 3.0

Riverpod 3.0 (стабильный релиз сентябрь 2025) — текущий де-факто стандарт. Используются:

* `@riverpod`-annotation-based провайдеры (генерация через `build_runner`).
* Async-провайдеры с `ref.retry` и встроенным reactive caching.
* Pause/Resume при невидимости виджета используется по умолчанию.
* `Notifier`/`AsyncNotifier` — основной паттерн.
* Mutations API — для исходящих операций («послать сообщение», «создать группу»).
* **Запрещены:** legacy `StateProvider`, `StateNotifierProvider` (они переехали в `package:flutter_riverpod/legacy.dart` и помечены как переходные).

### 8.3. Навигация — go_router 17.1.0

go_router 17.1.0 (последний стабильный на pub.dev, опубликован верифицированным паблишером flutter.dev). Используется declarative-конфигурация + `go_router_builder` для type-safe маршрутов через `@TypedGoRoute`.

* Stateful shell routes для нижней навигации (Chats / Calls / Settings).
* Redirect-логика на auth gate.
* Deep links: обрабатываются для invite-token URL.

### 8.4. Интеграция с Rust Core через flutter_rust_bridge

* Версия frb — **2.11.1** (стабильная, Flutter Favorite).
* Сгенерированные биндинги лежат в `lib/core/ffi/` и **не редактируются руками**; перегенерация — `flutter_rust_bridge_codegen generate`.
* Long-lived streams (входящие сообщения, presence) маппятся в Dart `Stream<T>` и подписываются через Riverpod-провайдеры.
* Async-методы (`sendMessage`, `createGroup`, `addMember`) возвращают `Future<Result>`; ошибки — sealed `CoreError`.
* **DO NOT** использовать прямой `dart:ffi` — frb выбран сознательно за управление жизненным циклом, изоляты и type-safe codegen. Голый ffi — это: ручной memory management, отсутствие async без отдельного isolate, риск use-after-free.

### 8.5. UI и design system

* Кастомные виджеты: `DsButton`, `DsTextField`, `DsAvatar`, `DsListTile`, `DsAppBar`, `DsBottomSheet`, …
* Темы — light/dark/system; токены (цвета, отступы, типографика) — в `theme/tokens.dart`.
* Анимации — `flutter_animate` (или нативные `AnimatedContainer`/`ImplicitlyAnimatedWidget`); все переходы между экранами кастомные (не Material `MaterialPageRoute`).
* Список чатов и список сообщений — **виртуализованы** через `ListView.builder` + `SliverList` + ключи по message_id; для очень больших чатов (>10k сообщений) — `super_sliver_list` пакет (рекомендуется к рассмотрению, но не обязателен в MVP).

### 8.6. Картинки и медиа в UI

* Кэш зашифрованных blob'ов — собственная реализация (cached_network_image **не годится**, т.к. он скачивает по URL и хранит plaintext). Алгоритм: Core отдаёт Dart байты уже расшифрованного изображения; Dart хранит их в `LRUCache<MessageId, Uint8List>` в RAM; на диск — никогда, иначе обходим всю модель шифрования.
* BlurHash рендерится из строкового хеша мгновенно, до того как Core доставит расшифрованный thumbnail.

### 8.7. Перечень Flutter-пакетов (с пинами)

| Пакет | Версия (на 18 мая 2026) | Назначение |
|---|---|---|
| `flutter_riverpod` | `3.0.x` (последний стабильный 3.0) | state management |
| `riverpod_annotation` + `riverpod_generator` | соответствующие 3.0 | codegen |
| `go_router` | `17.1.0` | routing |
| `go_router_builder` | совместимая с 17.1.0 | type-safe routes |
| `flutter_rust_bridge` | `2.11.1` | FFI |
| `flutter_secure_storage` | `10.2.0` | secure storage |
| `freezed` + `json_serializable` | актуальные | модели/DTO |
| `flutter_blurhash` | актуальная | placeholders |
| `flutter_animate` | актуальная (опционально) | анимации |
| `intl` | актуальная | локализация |

---

## 9. Real-time communication

### 9.1. Доставка сообщений

* Транспорт — WebSocket, см. §7.3.
* Семантика — at-least-once + UUIDv7-deduplication на клиенте.
* При оффлайн-периоде клиент при подключении присылает `Resume{last_acked_seq}`. Сервер пушит весь хвост.

### 9.2. Typing indicators и presence

* Эфемерные (не сохраняются на сервере, не доставляются на оффлайн-устройства).
* **С учётом приватности:** Presence (online/offline/last seen) — opt-in (по умолчанию **выключено**); если включено, last seen имеет гранулярность «недавно» / «давно» / «никогда не показывать».
* Typing — посылается только в активный 1:1 или group chat (не broadcast); в группах больше 25 человек typing-indicator подавляется (privacy + spam).

### 9.3. Push notifications

* FCM (Android) и APNs (iOS) — единственная цель сервера; десктоп получает уведомления только пока WS открыт.
* **Payload зашифрован.** Содержит только `{chat_id_opaque, message_uuid}`. Plaintext превью «N: Привет» **никогда не отправляется через push**, потому что push-инфраструктура — это третьи стороны (Google/Apple), которые их видят в plain.
* Клиент при получении push: будит фоновое isolate, открывает WS, забирает шифротекст, дешифрует через Core, формирует local notification с расшифрованным превью. Если фон убит и WS не успевает, пользователь видит «New message» без превью.

### 9.4. Reconciliation при оффлайн-возврате

* Простейший happy path: resume-token валиден, сервер отдаёт хвост за последнюю минуту.
* Long offline (часы/дни): резюм валиден, отдаётся весь хвост, клиент применяет в порядке `Commit` → `application_message` (MLS требует строгого порядка `Commit`'ов).
* Out-of-retention: сервер отвечает `ResumeImpossible`, клиент делает full state refresh (новый pull всех групп). Сообщения за пределами retention потеряны на сервере, но если они уже доставлены на хотя бы одно из устройств пользователя — там они остаются (multi-device best effort sync — feature не для MVP).

---

## 10. Аудио/видео-звонки

### 10.1. Стек

* **Media server:** LiveKit v1.11.0 (Go, self-hosted в Docker), SFU-режим.
* **Транспорт:** WebRTC (DTLS-SRTP hop-by-hop) — между клиентом и LiveKit. Это HBH-уровень шифрования.
* **E2EE:** поверх SRTP — SFrame (RFC 9605) с ключами, выведенными из MLS-экспортёра соответствующей группы.

### 10.2. Сигнализация

* Token issuance — sinhron-server генерирует LiveKit join-token (JWT) и передаёт клиенту через WS. LiveKit API key/secret хранятся в Docker secrets, клиенту не видны.
* ICE-кандидаты ходят между клиентом и LiveKit по их штатному WebSocket-каналу.
* TURN-конфигурация: sinhron-server отдаёт клиенту `iceServers` с coturn-URL и временным TURN-credential (REST-API shared-secret based, поддерживается coturn штатно).

### 10.3. SFrame + MLS — точная схема ключей

Реализуется ровно по RFC 9605 §5.2:

* `sframe_epoch_secret = MLS-Exporter("SFrame 1.0 Base Key", "", AEAD.Nk)` — выводится из текущего `exporter_secret` MLS-группы, соответствующей звонку.
* `sender_base_key[i] = HKDF-Expand(sframe_epoch_secret, encode_big_endian(i, 4), AEAD.Nk)` для каждого члена с индексом `i`.
* Per-KID:
  `sframe_secret = HKDF-Extract("", base_key)`
  `sframe_key = HKDF-Expand(sframe_secret, "SFrame 1.0 Secret key " + KID + cipher_suite, AEAD.Nk)`
  `sframe_salt = HKDF-Expand(sframe_secret, "SFrame 1.0 Secret salt " + KID + cipher_suite, AEAD.Nn)`
* KID-layout: `(context << (S+E)) + (sender_index << E) + (epoch mod 2^E)` (Figure 8 RFC 9605). В нашей реализации `S = 6` (до 64 одновременных активных leaf'ов в звонке достаточно для MVP), `E` подобрать так, чтобы `keyRingSize ≥ 2^E` соответствовал размеру keyring'а LiveKit (по умолчанию 16 → `E = 4`).

### 10.4. Интеграция с LiveKit Key Provider

LiveKit штатно поддерживает MEGOLM- и MLS-style key rotation через extension `BaseKeyProvider` (см. https://docs.livekit.io/transport/encryption/start/, секция «using a custom key provider»). Из официальной документации:

> «If your application requires key rotation during the lifetime of a single room or unique keys per participant (such as when implementing the MEGOLM or MLS protocol), you'll need to implement your own key provider.»

Архитектура интеграции (концептуально):

* Наследуемся от `BaseKeyProvider`.
* На каждое успешное применение MLS-Commit (т. е. переход в epoch N+1) Core:
  1. Вычисляет `sframe_epoch_secret` для новой epoch.
  2. Выводит `sender_base_key[i]` для каждого активного члена.
  3. Через FFI пушит ключи в LiveKit-клиент через `setKey(participant_id, key_index, key)`. `key_index = epoch mod keyRingSize`.
  4. **Отложенный переключ на новый ключ для исходящего трафика** до тех пор, пока все участники не подтвердят прием нового ключа, либо до таймаута (по RFC 9605 §4.4.1).
  5. Старая epoch держится в keyring'е короткое overlap-окно (для in-flight кадров), затем удаляется (forward secrecy).
* **`ratchetWindowSize = 0`** — отключаем встроенный LiveKit-ratchet: ротация управляется MLS, второго ratchet'а поверх не нужно.

### 10.5. 1:1 vs групповой звонок

* 1:1 звонок — MLS-группа из 2 leaf-ов уже есть (это сам 1:1-чат) → переиспользуем её exporter_secret. Простой случай.
* Групповой звонок — MLS-группа того же чата (group chat). Те же ключи. В звонок не обязательно входят **все** члены группы; LiveKit и MLS — ортогональны: MLS-группа определяет «кто может расшифровать», LiveKit-room определяет «кто фактически медиа-публикует/потребляет». Тот, кто не присоединился к звонку, ничего не теряет; тот, кто присоединился, но удалён из MLS, ключей не получит.

### 10.6. Полезные оговорки

* Rust SDK LiveKit (`livekit` 0.7.34, livekit-api 0.4.14) — на 0.x, активно сопровождается (релизы каждые 1–4 недели), production-used внутри LiveKit Agents, но пре-1.0. На стороне клиента **разумно** использовать готовый Flutter SDK `livekit_client` (а не пробрасывать WebRTC через Core), а Core отдаёт ему только сгенерированные ключи через frb-API. Это снижает поверхность интеграции и не тянет libwebrtc-зависимости в наш собственный Rust-крейт.

---

## 11. Хранение и обработка медиа

### 11.1. Принципы

* Шифрование — на клиенте, до выхода в сеть.
* Сервер хранит только шифротекст; имя файла = `sha256(ciphertext)`. Если два разных клиента случайно зашифровали один и тот же plaintext тем же случайным ключом и nonce (вероятность ~0), у них будет коллизия — это допустимо и обрабатывается через `ref_count`.
* Локальное содержимое блобов на устройстве — только зашифрованные кэши; расшифрованные байты живут в RAM на время отображения.

### 11.2. Превью

* Маленький отдельный зашифрованный thumbnail-blob (≤32 КБ).
* BlurHash-строка в metadata application-сообщения — для мгновенного UI placeholder.
* Голосовые сообщения: waveform-preview (массив амплитуд 50–100 точек) включается в metadata.

### 11.3. Retention и удаление

* Сервер: 90 дней после последнего GET либо немедленно при ref_count→0 (см. §7.6).
* Клиент: пользователь может вручную вычистить кэш; политика по умолчанию — LRU при превышении настраиваемого лимита (по умолчанию 2 ГБ).

---

## 12. Спецификация развёртывания

### 12.1. Сервисы Docker Compose

```
services:
  caddy        — image: caddy:2 (актуальный)
  sinhron-app  — image: sinhron/server:<tag>  (наш образ)
  livekit      — image: livekit/livekit-server:v1.11.0
  coturn       — image: coturn/coturn:4.6.3, network_mode: host (обязательно)
  postgres     — image: postgres:16-alpine
  (опц.) backup-cron — pg_dump раз в сутки на смонтированный том
```

### 12.2. Переменные окружения

* Все переменные начинаются с префикса `SINHRON_*`.
* В репозитории — только `.env.example` (с placeholder-значениями). **Никогда** не коммитить `.env` в git.
* Для production **обязательно** использовать **Docker secrets** (Swarm-style file-mounted secrets читаются как файлы) **или sops-encrypted-files** (mozilla/sops + age/gpg-key). Plain `.env` в production — запрещено.
* Минимально требуемые переменные:
  * `SINHRON_PUBLIC_HOSTNAME` — для Caddy и для генерации turn-credentials.
  * `SINHRON_DB_URL` — указатель на postgres сервис.
  * `SINHRON_LIVEKIT_API_KEY` / `SINHRON_LIVEKIT_API_SECRET` — для JWT issuance.
  * `SINHRON_TURN_SHARED_SECRET` — для REST-credential обмена.
  * `SINHRON_LETSENCRYPT_EMAIL` — для Caddy.
  * `SINHRON_LOG_LEVEL` — `info` по умолчанию.

### 12.3. Caddy

* Caddyfile конфигурируется минимально: один host-блок на `SINHRON_PUBLIC_HOSTNAME`, `reverse_proxy /v1/* sinhron-app:8080`, `reverse_proxy /livekit/* livekit:7880` (LiveKit WS), отдельный путь под media.
* Security headers устанавливаются принудительно: `Strict-Transport-Security max-age=31536000; includeSubDomains; preload`, `X-Content-Type-Options nosniff`, `X-Frame-Options DENY`, `Referrer-Policy strict-origin-when-cross-origin`, `-Server` (стрипаем).
* HTTP/3 включается (`servers { protocols h1 h2 h3 }`).

### 12.4. Backup

* `pg_dump` раз в сутки на смонтированный том, retention 14 дней inkrementov.
* Бэкап не включает ключевой материал (его на сервере нет в plaintext).
* Бэкап **обязательно** шифруется при отгрузке наружу (если self-hoster таскает в S3) — рекомендация: `age` или `gpg`.

### 12.5. Upgrade strategy

* Версии всех образов — пин по SHA digest (`image: sinhron/server@sha256:...`) в production-compose.
* Rolling upgrade невозможен в single-host Docker Compose; делаем «stop → up» с `docker compose pull && docker compose up -d` и опираемся на короткое окно простоя (<10 c). Клиент должен переживать reconnect WS прозрачно.
* DB migrations выполняются автоматически при старте `sinhron-app` и идемпотентны.
* Health-check'и: `/healthz` (liveness), `/readyz` (включает «PG доступен», «LiveKit reachable»).

### 12.6. Observability

* Структурированное логирование через `tracing` crate, JSON-формат по умолчанию (для прода), pretty — для разработки.
* Метрики Prometheus-формата на `/metrics`. **Минимально достаточно** — количество подключённых WS, доставленных сообщений, размер очереди оффлайн-доставки, p95 latency POST `/messages`. Полный Prometheus+Grafana **не входит в комплект** — это решение self-hoster'а.
* Аппликативные ошибки бэкенда — Sentry-совместимый sink опционален, отключён по умолчанию.

---

## 13. Модель угроз

### 13.1. В рамках модели

* **Компрометация сервера (root, БД-дамп, бэкап):** не приводит к компрометации содержимого сообщений (ciphertext-only). Утечка metadata — да: пары (delivery_key → push_token), времена доставки, размеры blob'ов, граф «delivery_key A посылает delivery_key B». Минимизация — sealed sender, periodic rotation delivery_key, оптические задержки доставки (out of scope в 1.0).
* **Сетевой противник (MITM, ISP, DPI):** mitigated — TLS (Caddy, automatic LE), WSS, certificate-pinning на клиенте к самоподписанному CA self-hoster'а **опционально** (для параноидального режима). По умолчанию — pinning на корневые store ОС.
* **Потеря устройства:** MLS-Remove с другого устройства; устройство теряет возможность дешифровать любые сообщения **после** Commit-Remove (PCS). История на самом устройстве остаётся читаемой, если устройство не залочено — поэтому требуется screen-lock пользователя; своими силами мы дополнительно требуем PIN/biometric на запуск приложения (опционально).
* **Враждебный сосед на shared-устройстве:** не рассматриваем как высокоприоритетный, но базовые меры — PIN-lock и app-level encryption local DB — мы реализуем.
* **Supply chain attack (зависимости):** mitigated через (а) пиннинг точных версий, (б) `cargo audit` в CI, (в) `cargo-vet` для third-party аудит-сертификатов, (г) `cargo-deny` для лицензионной чистоты, (д) reproducible builds для финальных артефактов.
* **Утечка в push-нотификациях:** payload — opaque, plaintext в push не уходит никогда.
* **Атаки на Sealed Sender (как в IACR 2026/484 на Signal):** mitigated архитектурно — все криптопроверки на пути decap → MLS-decrypt → identity-verify выполняются единым Rust-модулем без сериализации в промежуточных состояниях; нет ситуации «один процесс декапсулирует, другой проверяет identity» (как было в Android-имплементации Signal до 2024 г.).
* **Утечка метаданных через `state_backups` (см. §6.8.1):** сервер видит размер blob'а пользователя, частоту его обновлений и монотонный `version_seq`. Это даёт proxy-сигнал «активность юзера в MLS-группах»: большой blob = много групп, частые updates = много исходящих Commit'ов. Содержимое blob'а сервер не видит (AES-256-GCM-tag-protected). Митигация **out of scope для 1.0**, но архитектурно возможна: padding blob'а до фиксированных бакетов (32 КБ / 128 КБ / 512 КБ / 1 МБ) + дозировка updates через джиттер (например, не чаще 1 раза в 5 минут даже при бурной активности). Эти меры — кандидат на 1.x.
* **Recovery-phrase compromise:** если злоумышленник получает 24-словную фразу пользователя (social engineering, физический доступ к записанной фразе), он может полностью восстановить state-backup и identity. Дальнейшая защита — стандартная: пользователь делает MLS Remove своих скомпрометированных устройств с другого устройства (PCS), forward secrecy продолжает работать с момента Remove'а. Сам факт компрометации фразы пользователю обнаружить **невозможно** без аудита поведения других членов групп (что вне нашей телеметрии). Рекомендации UX: при операции «restore from phrase» система предлагает немедленно пересоздать фразу (rotate recovery phrase) — это форсирует ротацию state-backup-key и снимает старую фразу с защитной роли.

### 13.2. Вне модели (явно)

* Nation-state с TEE/side-channel-атаками на конкретное устройство.
* Аппаратные кейлоггеры и физический доступ к разлоченному устройству.
* Скриншоты и фотографии экрана от добросовестного контр-агента (это not-our-threat-model).
* Социальная инженерия для получения recovery-фразы.
* Поэтапные атаки на пользователей с уже скомпрометированной ОС.
* Метаданные сетевого уровня (Tor/onion routing) — не покрываем; self-hoster может использовать любую сетевую обвязку.

---

## 14. Подписание кода и дистрибуция

### 14.1. Windows

* **OV (Organization Validation) Code Signing** через провайдеров вроде DigiCert/Sectigo, **либо** **Azure Trusted Signing** (новое имя Azure Code Signing, GA в 2024 г.; дешевле, поддерживается signtool из Win SDK).
* Подпись применяется к `.exe`, `.msix` и, если применимо, к bootstrapper'у.
* SmartScreen-репутация набирается со временем; на ранних релизах ожидается warning «Unknown publisher».

### 14.2. macOS

* Apple Developer ID (Application + Installer).
* `codesign` + `notarytool submit` + `stapler staple` — обязательный конвейер.
* Hardened runtime + entitlements (`com.apple.security.app-sandbox` опционально; Keychain Sharing — обязательно).
* Дистрибуция: `.dmg` (release-builds) + Sparkle 2.9.2 для авто-обновлений (`appcast.xml`, EdDSA-подпись).

### 14.3. iOS

* App Store. TestFlight — для бета-каналов.
* Если выкладка в App Store невозможна (политика): альтернатива — AltStore/sideload, но это не считаем поддерживаемым каналом.

### 14.4. Android

* Google Play (release) + APK на GitHub Releases (для тех, кто избегает Play) + **F-Droid** при условии reproducible-builds и независимого APK-репозитория.
* Подпись Play App Signing (managed by Google) + upload key, либо self-managed signing — на усмотрение релизного инженера.

### 14.5. Linux

* `.deb` и `.rpm` — на собственный apt/yum-репозиторий, **подписанные GPG-ключом** проекта. Открытая публикация публичного ключа на сайте проекта.
* `Flatpak` — на Flathub (отдельный manifest), `Snap` — опционально.
* AppImage — как backup-канал.
* Sparkle 2.9.2 — **только macOS**, на Linux/Windows используются нативные пакетные менеджеры (apt/yum/winget/msix-store).

### 14.6. Прозрачность

* Все release-артефакты публикуются с SHA-256 чексуммой и (для воспроизводимых сборок) с реквизитами CI-runner'а.
* Roadmap по reproducible-builds — Фаза 9.

---

## 15. Стратегия тестирования

### 15.1. Юнит-тесты (Rust)

* Криптографические state-машины (MLS group lifecycle, sframe key derivation, sealed sender) покрываются property-based тестами через `proptest`. Особое внимание — invariant'ам:
  * После Remove(X) X не может расшифровать любые application messages, отправленные после Commit'а.
  * После Update epoch +1 любой member, не получивший Commit, не может ни шифровать, ни дешифровать.
* Test vectors RFC 9420 и RFC 9605 — обязательно прогоняются (OpenMLS поставляет вектора).

### 15.2. Интеграционные тесты (Docker Compose)

* Отдельный `docker-compose.test.yml`, поднимающий postgres + sinhron-app + два экземпляра `sinhron-cli`.
* Тесты: создание группы, добавление/удаление членов, доставка через WS, оффлайн-доставка, resume token, медиа-аплоад.
* Все интеграционные тесты идемпотентны; БД сбрасывается между прогонами.

### 15.3. Flutter widget tests

* Каждый виджет `Ds*` имеет widget-test с golden-снимком.
* State-providers покрываются `ProviderContainer.test()` (новое API Riverpod 3.0).

### 15.4. E2E

* Два настоящих клиентских билда (например, macOS-app и Android-emulator) под управлением Patrol/Appium. Сценарии: регистрация → pairing второго устройства → отправка/приём сообщений → создание группы → звонок.

### 15.5. Security regression tests

* Каждая исправленная CVE/security-bug превращается в test-case, который остаётся в репозитории навсегда.

### 15.6. Fuzz testing

* `cargo-fuzz` на парсерах: входящие WS-кадры (Protobuf), MLS-фреймы (минимум — fuzz через интерфейс OpenMLS), media-headers.
* Запускается в CI на ночных билдах, time-budget 30 мин на target.

---

## 16. Roadmap по фазам (под Claude-Code-driven development)

Принцип: **сначала интеграционный тест, потом реализация**. Каждый «тикет» формулируется как «вот тест, который сейчас падает, — заставь его пройти». Это снижает галлюцинации Claude Code и упрощает review.

### Фаза 0 (недели 1–2): scaffolding

* Cargo workspace на сервер и на Core.
* Flutter app skeleton.
* CI/CD: GitHub Actions matrix (Linux/macOS/Windows для Flutter, Linux для Rust).
* `docker-compose.yml` (skeleton) и `docker-compose.test.yml`.
* `cargo audit`, `cargo deny`, `flutter analyze` — все обязательны для зелёного CI.
* Pre-commit hooks: `cargo fmt`, `dart format`, `flutter test`.

### Фаза 1 (недели 2–6): Rust Core — 1:1 MLS

* Интеграция OpenMLS 0.8.1.
* Identity + key package generation + storage (SQLCipher).
* `sinhron-cli` — две инстанции, между которыми создаётся MLS-группа из двух членов и обменивается application-сообщениями (без сети, через файловую почту в начале).
* Add CI test vectors из OpenMLS test suite.

### Фаза 2 (недели 6–10): Axum-бэкенд

* Skeleton Axum 0.8.9 с auth challenge-response.
* WebSocket subprotocol sinhron.v1.
* PostgreSQL schema (через sqlx migrate); партиционирование `messages`.
* Push reception endpoint (без real FCM пока).
* `sinhron-cli` от Фазы 1 теперь работает через реальный сервер.

### Фаза 3 (недели 10–16): Flutter UI + FFI

* frb 2.11.1 интеграция, кодоген.
* Chat list, chat view, composer на кастомных Ds*-виджетах.
* Riverpod-провайдеры над Core-streams.
* Один-на-один чат работает end-to-end на macOS и Linux build'ах (десктоп — быстрее для итераций, чем мобайл).

### Фаза 4 (недели 16–22): multi-device

* QR-pairing flow.
* Каждое устройство = отдельный leaf в MLS-группе.
* Remote-revoke устройства.
* Recovery phrase BIP-39, UI с предупреждениями.

### Фаза 5 (недели 22–28): группы + Sealed Sender

* Group create / add / remove / leave.
* Sealed Sender envelope (HPKE-обёртка вокруг MLS-application messages).
* Delivery key rotation (раз в 7 дней).

### Фаза 6 (недели 28–36): медиа

* Encrypted blob upload/download.
* Голосовые сообщения, изображения, документы.
* BlurHash + zashifrovannyy thumbnail.
* Media retention.

### Фаза 7 (недели 36–44): 1:1-звонки через LiveKit

* LiveKit token-issuing.
* coturn в Docker.
* SFrame intergration с MLS-exporter (точно по RFC 9605 §5.2).
* Ratchet'ы LiveKit отключены, всю ротацию делает MLS.

### Фаза 8 (недели 44–50): групповые звонки + push

* Group calls (key index = epoch mod keyRingSize).
* FCM + APNs production-integration.
* End-to-end тесты двух устройств в звонке через staging-сервер.

### Фаза 9 (недели 50–56): security audit prep, reproducible builds, signing, distribution

* Внешний security-аудит (сценарий — статический + dynamic review, плюс red-team).
* Reproducible builds (SOURCE_DATE_EPOCH, `-Cmetadata`, фиксированный toolchain).
* Code signing на всех платформах.
* Публикация в каналы (App Store, Play, F-Droid, apt/yum repo, Sparkle appcast).

---

## 17. Работа с Claude Code (best practices этого проекта)

### 17.1. Структура промпта

При постановке тикета Claude Code в качестве контекста подаётся:

1. Этот документ целиком (или соответствующий раздел).
2. Конкретный «work unit» с критериями приёмки.
3. Уже существующий failing-test (если применимо).
4. Список «затронутых файлов» и список «файлов, в которые трогать нельзя» (например, frb-сгенерированные).

### 17.2. Что Claude Code решает самостоятельно

* Имена internal-функций, имена переменных.
* Раскладку модулей внутри одного крейта.
* Выбор между `if let`/`match`/`?`.
* Структуру тестовых fixture'ов.

### 17.3. Что эскалируется владельцу

* **Любое** изменение перечня крейтов или версий — только через явное согласование (см. §18).
* Любое расширение public Core-API: новый метод или Stream.
* Изменение wire-format'а (Protobuf-схемы) — только обратносовместимые добавления полей, ломающие изменения только через мажорный bump протокола.
* Изменения в криптографических state-машинах: добавление proposal-типов, изменение KDF-меток, любая работа с exporter_secret вне утверждённого использования (SFrame, sealed sender).
* Включение новой постоянной отрисовки plaintext-данных в долгоживущих UI-кэшах.
* Любая работа с identity-ключом помимо уже описанной (новые операции signing).

### 17.4. Чеклист ревью криптокода (для владельца над PR'ом от Claude Code)

* [ ] Нет ручной криптографии (всё — через OpenMLS, sframe, RustCrypto, ring).
* [ ] Все секретные буферы — в `Zeroizing<…>` / `Secret<…>`.
* [ ] Нет логирования секретов даже в `tracing::debug!`.
* [ ] Проверки подписи и identity — атомарны (один Rust-модуль, без выхода в Dart, без сериализации в промежуточных состояниях).
* [ ] Все error-пути сохраняют constant-time свойства, где это требуется (`subtle::ConstantTimeEq`).
* [ ] Новый код покрыт property-based тестами на ключевые инварианты.
* [ ] При работе с MLS — Commit/Welcome/Proposal в правильном порядке; не теряется промежуточное состояние при панике.

### 17.5. Рекомендуемые верификационные приёмы

* **Test-first.** Перед каждым feature-ticket'ом Claude Code сначала пишет интеграционный тест, который **сразу падает**. Только после его проверки человеком — переходит к реализации.
* **Diff-минимализм.** Любой PR должен быть минимально-инвазивным. Лучше пять маленьких PR'ов, чем один на 2 тыс. строк.
* **Двойная сверка с RFC.** Для криптоопераций Claude Code в комментарии ссылается на конкретный пункт RFC (например, `// RFC 9605 §5.2`).

### 17.6. Конструктивное возражение

Claude Code **обязан** возражать архитектору, если видит, что предложенный подход хуже доступной альтернативы — по техническим, эксплуатационным или security-причинам. Молчаливое подчинение, когда у исполнителя есть обоснованные возражения, — антипаттерн на уровне рабочего процесса этого проекта.

Формат возражения:

1. **Что именно предлагается изменить** (конкретно, не «давайте перепроектируем X»).
2. **Почему текущий вариант хуже** — со ссылкой на источник: пункт RFC, известный issue/CVE крейта, бенчмарк, публикация, опыт другого проекта.
3. **Что предлагается взамен** — с тем же уровнем конкретики, что и в исходной спеке (имена крейтов, точные версии, схема data flow).
4. **Цена миграции, если возражение приходит post factum** (после того, как часть кода уже написана).

Финальное решение всегда остаётся за владельцем. Если архитектор подтверждает изначальный вариант после возражения — оно фиксируется в issue/PR-комментарии (а не в этом документе) для будущей трассируемости.

Возражения **не** уместны по поводу:

* §3 «Непереговариваемые принципы» — это product-level invariant'ы, не технические трейд-оффы.
* §18 «DO NOT list» — это red lines; каждая обоснована конкретной угрозой и не предмет компромисса в рамках 1.0.
* Стиля кода и именования внутри одного крейта (см. §17.2).

---

## 18. DO NOT list (явные антипаттерны)

Этот раздел — императивный. Каждый пункт — стоп-флаг для любого PR.

1. **DO NOT use Electron / CEF / WebView2 для UI.** Только Flutter. Любое предложение «давайте сделаем веб-вью» — отклонять.
2. **DO NOT roll your own crypto.** Никаких ручных AES-CTR, никаких самописных Diffie-Hellman, никаких «оптимизированных» HKDF. Всё — через OpenMLS, sframe-rs, ring, RustCrypto.
3. **DO NOT use Signal-style Sender Keys или Double Ratchet** напрямую. MLS заменяет их. Все группы — MLS-группы, включая 1:1.
4. **DO NOT** хранить расшифрованный plaintext в Dart heap дольше времени жизни одного UI-фрейма дольше, чем необходимо для отрисовки. Никакой долгоживущей `Map<String, DecryptedMessage>` в Dart.
5. **DO NOT** нарушать FFI memory ownership: всё, что выделено в Rust, освобождается в Rust. Через frb 2.x это происходит автоматически — но не пытайтесь «оптимизировать», передавая сырые указатели вручную через dart:ffi.
6. **DO NOT** делать HTTP polling вместо WebSocket. Polling недопустим даже как fallback — лучше пусть приложение покажет «нет связи».
7. **DO NOT federate.** Никаких ActivityPub-bridges, никаких Matrix-bridges. Однажды self-hosted инстанс — изолирован.
8. **DO NOT** позволять серверу видеть plaintext. Любой код, который шлёт на сервер что-либо, кроме шифротекста и opaque-метаданных, — review-block.
9. **DO NOT** использовать диапазоны версий (`^`, `~`, `>=`, `*`) в `Cargo.toml` и `pubspec.yaml`. **Пинуем точную версию.** Bump — отдельный commit с migration test.
10. **DO NOT** использовать `cached_network_image` для отрисовки media (он персистит plaintext в кэш на диск). Только собственная in-memory LRU.
11. **DO NOT** включать crash-reporting/telemetry «по умолчанию on». Это даже не opt-out — это полностью локально.
12. **DO NOT** хранить recovery-фразу нигде, кроме головы пользователя. Никаких «encrypted backup в облако» в 1.0.
13. **DO NOT** доверять `WebSocket.onmessage` без deduplication. Delivery — at-least-once, дедуп — обязателен.
14. **DO NOT** доверять системному времени для криптоопераций (например, для проверки KeyPackage expiry). Использовать монотонный clock + sanity-check + явные допуски (±5 минут drift).
15. **DO NOT** включать дебаг-логи с раскрытием criptomateriala даже в debug-build'ах публикуемых на TestFlight/Play.
16. **DO NOT** перепутывать `sqlx` и `rusqlite` в одном Cargo-workspace: они оба имеют транзитивную зависимость `libsqlite3-sys` с одинаковым `links = "sqlite3"`, и собрать их вместе не удаётся (см. публичную дискуссию `launchbadge/sqlx#3295`). Решение: на сервере — только `sqlx`, на клиенте — только `rusqlite`, и они физически разнесены по разным cargo-workspace'ам.
17. **DO NOT** использовать Material/Cupertino-defaults. Каждый виджет должен быть `Ds*` либо явный примитив (`Container`, `Row`, `Column`).
18. **DO NOT** запускать в production Plain `.env` файлы. Только Docker secrets или sops.
19. **DO NOT** забывать про Keychain Sharing entitlements на macOS и iOS во всех трёх build-конфигурациях (Debug, Profile, Release) — это самая частая причина «после hot restart ключи возвращают null» на физических устройствах.

---

## 19. Открытые вопросы (для будущих итераций после 1.0)

* **Post-Quantum migration.** OpenMLS уже имеет экспериментальную поддержку X-Wing KEM (HNDL-secure combiner), merge #1546. К 1.x — план: ввести вторую опциональную шифрсюиту на гибридном KEM, не ломая основной MTI. PQ signatures (ML-DSA) — отдельно, ждать стандартизации внутри MLS-WG.
* **Federation.** Возможно через MLS distribution service federation (sketch IETF). На 1.0 — нет. Любой self-hoster — отдельный остров. Рассмотреть после 1.5.
* **Web client.** Открытый вопрос. Дополнительные сложности: WebCrypto vs WASM-MLS, отсутствие нормального secure storage в браузере, supply-chain через npm. Если делать — Flutter Web с тем же Rust-Core, компилированным в WASM. Это нетривиально (frb поддерживает WASM, но требует серьёзной отладки).
* **Bot framework.** Программируемые «account-боты» (бот = MLS-leaf со скриптуемой логикой) — отличная фича для self-hoster'ов. Архитектура должна допускать «headless» билд Core. Тикет на 1.x.
* **Disappearing messages / view-once.** Архитектурно тривиально (TTL на application-уровне, локальный таймер), но требует UX-проработки.
* **Message reactions, replies, edits.** Поверх MLS application-сообщений; никаких новых криптопримитивов; вопрос в основном UI.
* **Search.** Полнотекстовый поиск — только локально, в зашифрованном индексе (Tantivy с зашифрованным storage layer). Серверный поиск исключён by design.
* **Reproducible builds на iOS.** Apple toolchain — не reproducible полностью; добиваться bit-exact reproducibility на iOS пока нереалистично. К 1.0 — best-effort на Android / Linux / Windows; iOS — отложено.
* **Encrypted message history backup.** В 1.0 включён только **MLS-state backup** (см. §6.8.1) — он восстанавливает членство в группах и MLS-leaf'ы, но не историю application-сообщений. Encrypted history backup всех локальных сообщений (с тем же recovery-key, что и state-backup) — отдельная 1.x фича. Технически тривиально (CBOR-сериализация message-store, AES-256-GCM, чанкование на ~10 МБ, заливка на S3-совместимое хранилище), ограничение — объём (сотни МБ-ГБ на активного пользователя) и UX-проработка «выберите, какие чаты бэкапить».

---

**Конец документа.** На основании этой спецификации Claude Code приступает к Фазе 0 (см. §16). Любые вопросы, требующие архитектурных решений, эскалируются согласно §17.3.