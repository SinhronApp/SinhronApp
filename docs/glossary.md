# Sinhron · glossary

> Терминология и acronyms которые встречаются в коде, спеке, документации.
> Если ты Claude после compact и видишь "frb" или "KP" или "WAL" — это здесь.
>
> <!-- SYNCED FROM PROJECT.md §4 --> **Tech stack versions** упомянутые в определениях ниже — synced from [`PROJECT.md` §4](PROJECT.md#4-tech-stack-pin-точные-версии). Source of truth — там. При version bump обновляй PROJECT.md §4 + сюда параллельно.

---

## A

**Action proof** — Ed25519 подпись над `domain_prefix || ':' || sha256(body) || ':' || be8(timestamp)`. Используется для всех mutating HTTP/WS operations (KP upload, state_backup PUT, etc.) чтобы server мог verify сообщение от ownership of identity privkey + bind подпись к конкретному body + защита от replay через timestamp window. См. `server/src/handlers/proof.rs`.

**ADR** — Architecture Decision Record. Записи в `docs/decisions.md`, формат "контекст → альтернативы → решение → последствия". У нас сейчас ADR-001 ... ADR-015 (ADR-015 = LiveKit + SFrame architecture для Phase 3 calls).

**AEAD** — Authenticated Encryption with Associated Data. Шифрование с встроенной проверкой integrity. У нас — AES-256-GCM (state backup) и AES-128-GCM (MLS app messages).

**APNs** — Apple Push Notification service. Apple's push delivery. Сервер шлёт payload (без plaintext per spec §13.x) → APNs → iPhone wake.

**Axum** — Rust web framework. Серверный HTTP + WS. Версия 0.8.9 (axum 0.8 требует MSRV 1.75).

---

## B

**Backup key** — `DerivedIdentity::backup_key`. 32-byte AEAD key из HKDF(seed, "sinhron-state-backup/v1"). Используется для encrypt всего MLS state перед upload на сервер (spec §6.8.1). См. `sinhron_sync/src/state_backup.rs`. Из него — **cloud backup key** (ADR-073): HKDF(backup_key, "sinhron-cloud-backup/v1"), запечатывает `root.sinhron` копии переписки; связанные устройства получают только его (`LinkedBundle::cloud_key`), не сам backup key.

**BaseKeyProvider (LiveKit)** — abstract class в `livekit_client` SDK для feeding E2EE keys в SFrame layer. У нас custom impl создаётся в `lib/features/calls/livekit_engine.dart::LiveKitCallEngine.connect` через `BaseKeyProvider.create(sharedKey: false, ratchetWindowSize: 0)` + `setRawKey(Uint8List)`. Key bytes derived из `sframe_derive_key_pair(...)` (FFI → `sinhron_call::sframe`).

**BIP-39** — Bitcoin Improvement Proposal 39. Mnemonic phrase standard, 12/24 words из словаря 2048 слов с checksum. Мы используем 24 слова = 256 бит энтропии. Phrase → seed → all sub-keys derived via HKDF.

**Broadcast Upload Extension (ReplayKit)** — отдельная цель iOS (`ios/ScreenShare`), которой система отдаёт кадры всего экрана, пока идёт «Трансляция экрана», — и когда Sinhron в фоне. У нас пересылает их приложению по сокету в App Group `group.com.sinhron.sinhron`; там они становятся дорожкой показа экрана в звонке (ADR-061). На Android то же делает **MediaProjection** (+ foreground service типа `mediaProjection`).

**Bundled-sqlcipher-vendored-openssl** — rusqlite feature flag. Статически линкует SQLCipher (encryption-aware SQLite fork) + OpenSSL в наш binary. Zero system deps на iOS/macOS.

---

## C

**BlurHash** — короткая строка (~30 символов), из которой мгновенно рисуется размытый плейсхолдер фото до загрузки превью (спека §8.6). Считается в Rust (`photo.rs`, крейт `blurhash` 0.2.3), едет в envelope; рендер — `media_blurhash_png` → PNG ≤64 px.

**Caddy** — automatic HTTPS reverse proxy. У нас в docker-compose — своя сборка с модулем `caddy-l4` (`server/Dockerfile.caddy`, Caddy 2.11.7 + caddy-l4 v0.1.2): TCP 443 делится по SNI — TURN/TLS → coturn, остальное → HTTP-часть (API → sinhron-server, LiveKit-сигналинг → livekit). Let's Encrypt auto. См. ADR-016.

**CallKit** — Apple framework для VoIP-style calls на iOS. Native lock-screen UI, ring sounds. Spec §10 требует для production calls. **У нас реализован foreground-only** через `ios/Runner/CallKitBridge.swift` (~237 LOC, CXProvider + CXCallController + CXProviderDelegate) + Dart wrapper `lib/features/calls/callkit_bridge.dart`. **Lock-screen incoming требует PushKit VoIP push**, который требует Apple Developer cert ($99/yr) — это DEFERRED (operator decision 2026-05-23). См. ADR-015 + tech-debt 4.3.

**Call bar (строка звонка)** — ADR-063. Зелёная строка под статус-баром над всеми экранами, пока идёт звонок, а его экран закрыт («⌄» или входящий в CallKit): «Идёт звонок · 02:14 · вернуться». `CallBarHost` в `lib/features/calls/live_call_bar.dart`, обёрнут вокруг навигатора в `app.dart`. Видеозвонок — плюс окошко камеры собеседника. У собеседника выключен микрофон — перечёркнутый микрофон вместо точки; после конца — «Звонок завершён · 02:37» (status 168).

**Talk time (длительность разговора)** — status 168. `ActiveCallState.talkTime`: от звука собеседника (`audioAt`, иначе от ответа `connectedAt`) до конца (`endedAt`). Одно число на экране «Звонок завершён», в строке звонка и во вкладке «Звонки».

**CallTimeline** — ADR-063. Шаги звонка от ответа в миллисекундах: `prep` (токен + TURN), `accept` (сервер получил ответ), `room` (вход в комнату LiveKit), `mic` (мой микрофон идёт), `sound` (пришёл звук собеседника). Строка «setup:» в диагностике «i», `[call-timing]` в логе. `lib/features/calls/call_timeline.dart`.

**CallSession registry** — server-side state `Arc<RwLock<HashMap<Uuid, CallSession>>>` в `server/src/call_session.rs`. Tracks Ringing → Active → Ended с idempotence для race conditions. `RINGING_TIMEOUT_SECS=30`, `GRACE_SECS=5`. Watchdog задача (`spawn_call_watchdog`) ticks 1s + fanouts `CallEnd{reason="no_answer"}` для expired ringing sessions.

**Исход звонка (статус в истории)** — `callStatusFromReason` (ночь 15→16, пункт 5): `completed` (соединились), `declined` (кто-то отказался), `busy` (у того идёт другой звонок — он отвечает `CallEnd{busy}`), `no_answer` (мой звонок никто не взял), `cancelled` (я положил трубку до ответа), `missed` (звонок мне, который я не взял, — по любой причине; ещё и строка «Пропущенный звонок» в чате).

**CXProvider / CXCallController** — CallKit primitives. `CXProvider` reports incoming/outgoing calls to system UI; `CXCallController` requests transactions (start/end). Delegate handles user Accept/End/Mute actions через CXAction subclasses. См. `CallKitBridge.swift`.

**AdaptiveSplit / две колонки (ADR-076)** — на iPad (окно ≥ 700×500 pt) вкладка показывает свой список слева, открытое — справа в своём навигаторе (`lib/app/adaptive.dart`); уже — как на iPhone. «Правая колонка» в документах — это она.

**Caller-binding pattern** — Flutter `_wireXxxBuilder()` функции в `lib/app/navigation.dart`. Каждая возвращает `WidgetBuilder` который правильно wires callbacks для конкретной route. Альтернатива routes-with-args, которая обычно ломается типизацией.

**Ciphersuite (MLS)** — комбинация (KEM, signature alg, AEAD, hash). Мы используем `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519` (RFC 9420). Pinned в `sinhron_sync::identity::CIPHERSUITE`.

**Clock drift correction** — `sinhron_net::clock_drift` module. Tracks `server_unix - local_unix` delta из Hello.server_time + HTTP Date header. Used by action-proof timestamps. Risk #4 fix.

**Commit (MLS)** — sealed agreement that changes group state (add/remove member, update key). Каждый Commit advances `epoch` by 1.

**coturn** — TURN/STUN server для NAT traversal в WebRTC. **Реализован в Phase 3** через docker-compose service `coturn/coturn:4.6.3-r3-alpine`, `network_mode: host` (per spec §12), `--external-ip=${TURN_EXTERNAL_IP}`, relay 49152–49999/udp, config `server/turnserver.conf`. TURN-over-TLS на 443 приходит через Caddy layer4 (`turns:<SINHRON_TURN_HOSTNAME>:443`). Credentials minted server-side по REST-API HMAC-SHA1 паттерну (RFC 5766) через `GET /v1/call/turn` — TTL `TURN_TTL_SECS`, по умолчанию 24h.

**CSPRNG** — Cryptographically Secure Pseudo-Random Number Generator. Используется для challenge nonces, AEAD nonces, etc. Via `rand_core::OsRng` (uses /dev/urandom / SecureRandomCopyBytes).

---

## D

**`device_revoked:<ключ>`** — ADR-104 (0.12.0). Отметка в синхронизации своих устройств (`sinhron_storage/src/devsync.rs`): телефон запоминает устройства, которые сам отключил, и не возвращает их в чаты, что бы ни показал сервер (ни истории, ни переноса; оставшийся лист удаляется). Привязка того же ключа по QR снимает отметку. Тест `devsync::tests::a_disconnected_device_is_remembered_and_synced`.

**Dart-define** — `flutter run --dart-define=KEY=VALUE` — compile-time constants accessible через `String.fromEnvironment('KEY')`. С ADR-032 `SINHRON_WS_URL` только подставляет адрес в поле сервера в dev-сборке — адрес выбирает человек.

**Commit ordering (порядок коммитов)** — ADR-022, ADR-092. Телефоны применяют первый годный MLS Commit своей эпохи; сервер берёт Commit (`Submit.is_commit`, `commit_epoch`) только от устройства, которое видело и не применило все Commit'ы этой эпохи после своего «родителя» (`parent_commit_id`, `refused_commit_ids`, таблица `group_commits`), иначе 409; клиент держит свой Commit «отложенным» (`invite_to_group_pending`) до ответа. Без этого одновременные изменения раздваивали группу, а мусорный Commit участника замораживал её.

**Журнал Commit'ов (CommitLog)** — ADR-092. На телефоне, по чату: какой Commit привёл в эпоху и какие Commit'ы этой эпохи не применены (`sinhron_sync::commit_order`, настройка `commit_log`); уходит с каждым нашим Commit'ом. «Лечить» — после неприменённого Commit'а сделать свой пустой (`self_update_pending`).

**Device key (ключ устройства)** — ADR-021. 64-байтный BIP-39 seed строкой `sinhron-device-key:v1:<hex>`: из фразы выводится необратимо (PBKDF2), из него — все ключи аккаунта. Хранится в iOS Keychain (`AfterFirstUnlockThisDeviceOnly`), чтобы после перезапуска открыть базу и подключиться без фразы. Все FFI-функции, принимающие `phrase`, принимают и его. Код: `sinhron_crypto::identity::device_key_from_phrase`, `lib/core/session.dart`.

**DerivedIdentity** — struct в `sinhron_crypto::identity`. 4 sub-keys derived from BIP-39 phrase via HKDF: ed25519_secret/public (signing), x25519_secret/public (HPKE), backup_key (state backup AEAD), storage_key (SQLCipher).

**Disappearing messages** — per-chat TTL короче чем global retention. У нас server side база (T3.4 — `groups.disappearing_after_secs` column + retention sweep). UI setting endpoint deferred.

**Domain prefix** — string prefix в bytes signature transcript, чтобы signature minted under один domain не валидировалась под другой. У нас 4 prefixes: `sinhron-register-v1:`, `sinhron-upload-kp-v1`, `sinhron-state-backup-put-v1`, `sinhron-ws-auth-v1:`. Pairwise-non-prefix invariant (Risk #2 test).

**Привязка подписи к серверу** — ADR-086. Всё, что проверяет сервер, подписано как `sinhron-server-host-v1:` ‖ имя сервера ‖ 0 ‖ сообщение: имя — из адреса сервера в приложении, сервер принимает только свои (`SINHRON_PUBLIC_HOSTNAME`). Подпись для одного сервера не годится на другом.

**Drop guard** — Rust pattern. Struct которая в Drop делает cleanup. У нас `SessionGuard` (un-registers WS session при Drop), `SyncClient`'s mutex guard, etc.

**DoH (DNS-over-HTTPS) / проверенный адрес** — ADR-072. Когда DNS телефона (провайдер, роутер) отдаёт для нашего хоста чужой адрес — у одного провайдера хост с чужим сертификатом, — приложение спрашивает адрес у Cloudflare (`https://1.1.1.1/dns-query`) или Google (`https://8.8.8.8/resolve`). Любой адрес (системный тоже) сначала **проверяется**: TLS-рукопожатие с SNI и проверкой сертификата на наше имя. Подключение идёт на проверенный IP, но TLS — по-прежнему с нашим именем, так что чужой сертификат не проходит. Проверенный адрес помнится (`net_dns_cache`). Код: `sinhron_net::dns`, `lib/core/server_dns.dart`.

**DTLS-SRTP** — hop-by-hop encryption для WebRTC. Между client и LiveKit SFU. **Не** E2EE — sees encrypted media decrypted. E2EE на top → SFrame.

---

## E

**E2EE** — End-to-End Encryption. Только endpoints читают plaintext. Server / middleware видит ciphertext. У нас MLS даёт это для chat; SFrame даст для calls.

**edge (Docker-сеть)** — внешняя сеть Docker на сервере, общая для Caddy Sinhron и веб-контейнеров соседних проектов (status 203): их сайты Caddy обслуживает по файлам `/etc/sinhron/caddy-sites/*.caddy`. Создаёт `install.sh`. См. deploy-guide §4.1.

**Ed25519** — Edwards curve digital signature algorithm. Используется для identity signatures, action proofs, WS auth challenge. Library: `ed25519-dalek 2.1.1`.

**Упоминание (@)** — `@[ключ личности]` внутри зашифрованного текста; показывается как «@Имя» (имя, которое человек сам сообщил). Упоминание меня ставит бейдж «@» в списке (хранилище v13) и пробивает выключенный звук чата.

**FTS5-индекс поиска** — `messages_fts` в локальной базе SQLCipher (хранилище v10): полнотекстовый индекс SQLite с токенизатором trigram (поиск подстроки, без учёта регистра в Unicode). Сервер ничего не ищет — расшифрованный текст есть только на устройстве.

**Группа из нескольких человек / имя группы** — ADR-034. Создаётся одним Commit на всех (KeyPackage каждого устройства каждого человека → `invite_devices` → один Welcome, копия каждому). Имя — сообщение `GroupName` (tag 17, действие `group_name`) сквозь MLS сразу после Welcome и после каждого добавления; у получателя переименовывает группу или превращает в группу чат с заглушкой «Группа ab12cd34». Добавить людей позже — Commit по порядку сервера (ADR-022), доходит до всех участников.

**Ссылка-приглашение** — ADR-043. `https://<сервер>/join#…`: нажал — сервер выставлен, пригласивший предложен в контакты (новичок — после имени и 24 слов). Подписана ключом пригласившего; изменённую приложение не открывает. «Мой QR-код» → «Поделиться» отправляет её — короткой: `https://<сервер>/i/<id>#<ключ>` (длинная лежит на сервере зашифрованной, год; не сохранилась — уходит длинная).

**FCM (push Google)** — ADR-057. На Android с сервисами Google сервер будит телефон data-сообщением Google с одним полем `s` — запечатанным ключом телефона (AES-256-GCM); Google видит только «что-то для Sinhron» и время. id проекта Firebase приходят с сервера (`/v1/push/info`), в APK их нет. Push **будит соединение** приложения на несколько секунд (`PushWake`) — приложение само показывает «Имя: текст». **«Звонки дойдут»** — раздел в «Настройки → Уведомления» с вердиктом и кнопками исправить.

**UnifiedPush / ntfy** — ADR-040. Push на Android без Google: приложение-дистрибьютор (ntfy, сервер — свой у оператора, `push.<домен>`) даёт телефону адрес; сервер Sinhron POST'ит на него `{"t":"msg","n":…}` / `{"t":"call",…}` — только на хосты из `SINHRON_UNIFIEDPUSH_HOSTS`, зашифровав ключом телефона (**Web Push, RFC 8291** — ntfy видит только шифртекст); уведомление рисует сам Sinhron. **«Всегда на связи»** — запасной путь без ntfy (foreground service держит соединение).

**VoIP-push / забирание звонка** — ADR-039. Приглашённому с закрытым приложением сервер шлёт PushKit-push (`{call_id, video}`), iPhone сразу показывает звонок «Sinhron» в CallKit; приложение подключается, получает повтор приглашения и «забирает» звонок (имя чата, нажатые «Ответить» / «Отклонить»). Не забранный за 45 с — закрывается. С ADR-056 push несёт **метку звонка** `h` (HMAC ключа телефона над call id ‖ group id) — CallKit сразу показывает имя чата.

**Push / «срочная» доставка** — ADR-038. Отправитель помечает доставку «срочной» (`urgent`), только если это настоящее сообщение (не квитанция, «печатает», присутствие); получатель без соединения получает APNs-уведомление «Новое сообщение» и бейдж — без текста и чата. Токен — `PUT /v1/push-token` (`apns_tokens`: alert / voip, sandbox, язык).

**«Поделиться» в Sinhron / расширение «Поделиться»** — ADR-060. Из меню «Поделиться» другого приложения: на Android — `ShareActivity` (передаёт в `MainActivity`, копии в кэше), на iPhone — **Share Extension** (`ios/ShareExtension`, без Rust и базы) кладёт копии в **App Group** `group.com.sinhron.sinhron` и открывает `sinhron://share?id=…`. В приложении — экран **«Отправить в…»** (`features/share_into`).

**Самообновление Android / android.json** — ADR-058. Рядом с APK на сервере лежит манифест `/download/android.json` (версия, сборка, для каждого ABI — адрес, SHA-256, размер). Приложение из нашего APK раз в 6 ч смотрит его; сборка новее — карточка «Доступно обновление», скачивание, проверка хеша и **нашей подписи**, системный установщик (одно нажатие «Установить» — всегда).

**Ответ из уведомления / «Ответить»** — ADR-066. Поле «Ответить» на уведомлении о сообщении (Android — `RemoteInput`, iPhone — категория `sinhron-message`): ответ уходит обычным зашифрованным сообщением, приложение не открывается; уведомление исчезает или говорит «уйдёт, как только Sinhron подключится» / «не отправлен — откройте чат». Нет при «показывать: ничего» и включённой блокировке приложения. На iPhone, закрытом системой, ответ уходит при следующем открытии. **Нажатие на уведомление** открывает его чат (и при холодном старте), пропущенный звонок — тоже.

**Превью push / расширение уведомлений (NSE)** — ADR-056. Отправитель прикладывает к срочной запечатанной доставке **превью** (вид, начало текста, чат, подпись), запечатанное HPKE на ключ доставки получателя, всегда 689 байт; сервер кладёт его в push не читая. **Notification Service Extension** (`ios/NotificationService`) на телефоне вскрывает его (CryptoKit) и пишет «<имя>: <текст>» по настройке «Уведомления показывают». Что ему нужно (ключи, имена, кто заблокирован) приложение кладёт в общую **Keychain-группу** `com.sinhron.shared` (`ios/Shared/PushShared.swift`).

**Администратор сервера / чат «Сервер»** — ADR-077. Человек, чей адрес оператор вписал в настройки сервера (`ADMIN_KEYS` → `SINHRON_ADMIN_IDENTITIES`). Только ему вверху «Чатов» видна строка «Сервер» — служебные уведомления сервера (тревоги о нагрузке, жалобы с IP), только чтение; таблица `admin_notices`, 30 дней.

**Удаление аккаунта / жалоба** — ADR-037. Удаление — сразу: `POST /v1/account/delete`, подпись ключом личности (на устройстве, привязанном по QR, — 24 слова); сервер стирает человека, медиа остаются у получателей; телефон стирается после ответа сервера. Жалоба — оператору своего сервера (`POST /v1/reports`): причина и, по выбору, текст сообщения; таблица `abuse_reports`, просмотр — SQL (onboarding §6.7) или чат «Сервер» у администратора (ADR-077).

**Админ группы / выход / удаление** — ADR-035. Админ записан в контексте группы MLS (ADR-088): сначала создатель; когда админ уходит, роль переходит к самому раннему оставшемуся человеку. Все телефоны читают одно и то же и согласны без лишних сообщений; Commit, ставящий админа не по правилу, не применяется. Нового человека приносит только Commit того, кто может управлять (запись 231); строки «X добавил(а) / удалил(а): Y» пишет сам Commit. Удаление — Commit админа (+ строка `removed` для старых приложений); выход — сообщение `leave`, удаление коммитит кто-то из оставшихся, а сам вышедший подписывает `POST /v1/groups/{id}/leave`. Удалённый видит «Вы больше не участник этой группы».
**Админ группы / выход / удаление** — ADR-035. Админ — создатель группы (лист 0 дерева MLS; все участники видят одно дерево и согласны без лишних сообщений); после его ухода управлять может любой. Удаление — Commit админа + строка `removed`; выход — сообщение `leave`, удаление коммитит кто-то из оставшихся, а сам вышедший подписывает `POST /v1/groups/{id}/leave`; удаливший — `POST /v1/groups/{id}/remove` (ADR-083), и сервер больше не шлёт удалённому ничего из чата. Удалённый видит «Вы больше не участник этой группы».
**Админ группы / выход / удаление** — ADR-035. Админ записан в контексте группы MLS (ADR-088): сначала создатель; когда админ уходит, роль переходит к самому раннему оставшемуся человеку. Все телефоны читают одно и то же и согласны без лишних сообщений; Commit, ставящий админа не по правилу, не применяется. Нового человека приносит только Commit того, кто может управлять (запись 231); строки «X добавил(а) / удалил(а): Y» пишет сам Commit. Удаление — Commit админа (+ строка `removed` для старых приложений); выход — сообщение `leave`, удаление коммитит кто-то из оставшихся, а сам вышедший подписывает `POST /v1/groups/{id}/leave`; удаливший — `POST /v1/groups/{id}/remove` (ADR-083), и сервер больше не шлёт удалённому ничего из чата. Удалённый видит «Вы больше не участник этой группы».

**Запрос на переписку (message request)** — чат, который начал кто-то другой (появился через Welcome), пока я его не принял(а) или не написал(а) в нём: `chats.request` (хранилище v11). Пока это запрос — не уходят отчёты о прочтении, «печатает» и моё имя, звонки не звонят; в чате вместо поля ввода — «Принять / Заблокировать / Удалить». Проверка — `isMessageRequest`.

**Снимок экрана (действие `screenshot`)** — ADR-030: `AppMessage.Screenshot` (tag 15). Уходит, когда снимок экрана сделан в открытом чате с исчезающими сообщениями; у всех появляется системная строка (`screenshot:me` / `screenshot:peer:<имя>`). С полем `recording` — запись (или трансляция) экрана: один раз на запись в каждом открытом таком чате, строки `recording:me` / `recording:peer:<имя>`. Предупреждение, не запрет.

**Profile (действие)** — `AppMessage.Profile{name, avatar, bio}` (tag 13): человек сам сообщает чату своё имя и, если есть, фото (JPEG ≤32 КБ, перекодирован без метаданных) и «О себе» (поле 3, ADR-052: одна строка ≤200 символов, хранится в `peer_bios`); отправляется в каждый чат один раз на имя, версию фото / «О себе» и состав участников (`chats.profile_sent` хранит раунд, имя, отпечатки и отпечаток участников: кто вступил позже, получает его сразу; новый раунд `People._profileRound` — всем ещё раз) и перед первым сообщением. Фото хранится в `peer_avatars`, снова перекодированное получателем. Хранится по ключу личности (`peer_names`). Имя — заявление, не проверка: отличает людей только код безопасности. Без имени показывается короткий ключ «ab12 cd34».

**Контакт** (ADR-052) — человек, которого я добавил сам (QR, ссылка, ключ, «Принять» запрос, «Добавить в контакты»); запись `contacts` на этом устройстве, независимая от чатов: удалил чат — контакт остался, «Удалить из контактов» — отдельно. Запрос на переписку и участники групп — не контакты.

**Моё имя для человека (alias)** — owner, 2026-11-03. «Изменить имя» в профиле человека и в «О чате» личного чата: имя видно только мне, хранится в настройке `contact_aliases` (JSON: ключ личности → имя, до 64 символов) на этом устройстве, никуда не отправляется. Везде, где показано имя (`peerNamesProvider`, название личного чата, баннер), оно поверх его собственного; «Вернуть имя «…»» (или пустое / его же имя) — убирает.

**Блокировка** — локальная, на этом устройстве (`blocked_peers`): `NetService` отбрасывает сообщения и действия заблокированного до UI; в личный чат с ним (`blocked_chats`, записи `чат=ключ`) не уходят отчёты о прочтении, «печатает», реакции, имя; его звонки там игнорируются (не звонят и не отклоняются). ADR-071: ключ доступа, который я дал этому человеку, отзывается на сервере — его сообщения выбрасываются молча, ничего от него не будит телефон, его звонок не доходит. Сервер видит «хэш отозван», но не чей; в группе заблокированный по-прежнему получает ваши сообщения.

**Presence / «в сети», контакт** — ADR-031. Контакт — собеседник личного чата, не запрос и не заблокирован. Если включено «Показывать, что я в сети» (`show_online`, по умолчанию выключено), приложение шлёт контактам действие `presence` (tag 16: `online` / `hidden`) сквозь MLS; «в сети» держится 55 с от серверного времени последнего сообщения (повтор — каждые 25 с, пока приложение на экране), потом — «был(а) …»; уход в фон шлёт «вышел» сразу (запись 170). Выключение рассылает `hidden`: контакты забывают «был(а)». Сервер не знает, кому статус виден.

**Скоропортящаяся доставка / `drop_after_secs`** — tech-debt 2.53. Поле запечатанной доставки (`SealedDelivery`, поле 6; `POST /v1/sealed`): сервер выбрасывает её, если получатель не забрал за N с от записи (`message_deliveries.expires_at`). Отправитель ставит 120 с для «в сети» и «печатает» (`envelope::drop_after_secs`); «вышел», `hidden` и всё остальное — 0 (храним до доставки).

**QR сервера / `sinhron-server:`** — ADR-032. Текст `sinhron-server:https://<домен>`, который печатает установщик (`server/install.sh`) и сканирует первый шаг онбординга. Адрес можно и ввести: домен, `https://…` или `wss://…/v1/sync`. Перед сохранением приложение проверяет `/_healthz` (`"service":"sinhron-server"`).

**Установщик (`server/install.sh`)** — ADR-032. Чистая Ubuntu 22.04/24.04 → работающий сервер: вопросы или `/etc/sinhron/sinhron.conf`, пакеты, Docker, ufw, fail2ban, автообновления, пароли (`server/.env`, создаются один раз), DNS-проверка, сборка, проверка снаружи, ночные копии, адрес и QR. Повтор — обновление; `--dry-run` — ничего не меняет.

**Envelope (app message)** — формат plaintext внутри MLS application message (ADR-017): `0xFF · версия · protobuf(AppMessage{Text|Media})`. `0xFF` невозможен в UTF-8, поэтому legacy-текст без конверта распознаётся однозначно. Код: `sinhron_sync/src/envelope.rs`.

**Epoch (MLS)** — sequential number, advances on every Commit. Все группа members share same epoch. Frame с wrong epoch → `WrongEpoch` error.

**Exporter (MLS)** — group key material exported для consumption по out-of-band protocols. Spec §10.4 — SFrame keys derived from MLS exporter.

---

## F

**Formatting entities / диапазоны форматирования** — ADR-070. Форматирование сообщения как список `(вид, начало, длина[, адрес | язык])` рядом с чистым текстом (как в Telegram); смещения — в единицах UTF-16. JSON-форма между Rust и Dart и в базе — `entities_json` (`[{"t":"bold","o":0,"l":4}]`); NULL — сообщение старого приложения (маркеры `*…*` читаются при показе). **`rich`** — флаг конверта «диапазоны — это всё форматирование».

**Fanout** — server-side broadcast: один Submit → multiple Push frames к members of group. См. `server/src/ws.rs::handle_submit`.

**FCM** — Firebase Cloud Messaging. Android push delivery. Not implemented; iOS-first.

**FFI** — Foreign Function Interface. Граница между Rust и Dart. У нас через flutter_rust_bridge.

**Fingerprint** — 12-char hex string (3 groups of 4) — `SHA-256(ed25519_pub || x25519_pub)[..6]` formatted. Used для UX identity display — в приложении «адрес» (Мой профиль, Контакты).

**Folder layout (раскладка папок)** — `FolderLayout` в `lib/features/chat_list/folders.dart`: порядок всех папок (встроенных и своих) и множество скрытых, настройка `chat_folder_layout` (JSON в зашифрованной таблице `settings`). Папки, не названные в порядке (новые), идут в конце. Вкладки над списком — не скрытые (`tabFoldersProvider`); всё скрыто → «Все» без полосы вкладок.

**FolderRule** — что папка делает с заглушёнными / архивными чатами: `show` (показывать), `hide` (скрывать), `only` (только они). По умолчанию заглушённые показываются, архивные — нет.

**Forward secrecy (FS)** — past messages remain confidential even if current key compromised. MLS gives this through Update commits.

**FRB** = flutter_rust_bridge. Tool for FFI codegen. Version 2.11.1.

**FRB drift** — Dart bindings (`lib/src/rust/`) out-of-sync with Rust API (`rust/src/api/`). Runtime crash on first call. `scripts/check_frb_drift.sh` детектит.

---

## G

**Ghost devices («призрачные» устройства)** — PREV-8 (0.12.0). Строки `devices` без сертификата с ключом, который не является ключом личности аккаунта: до 2026-11 их могла оставить регистрация. Миграция `20261112200500_revoke_ghost_devices.sql` — один `UPDATE`, помечает их отключёнными (`revoked_at`); честных устройств не задевает, применяется сама при запуске сервера.

**Golden test** — Flutter widget snapshot test. Renders widget to PNG, compares to checked-in reference. У нас 41 в `test/widgets/`.

**Group state (MLS)** — ratchet tree + epoch secrets + signature keys + proposal queue. Stored по openmls_sqlite_storage в SQLite.

**Group ID** — opaque bytes (32 typically), uniquely identifies MLS group across all clients + server. У нас hex-encoded as `group_id_hex` где надо string repr.

---

## H

**HKDF** — HMAC-based Key Derivation Function (RFC 5869). Используется для deriving sub-keys из BIP-39 seed. Format: `HKDF-Extract(salt, IKM)` → PRK; `HKDF-Expand(PRK, info, L)` → output.

**HMAC** — Hash-based Message Authentication Code. Crypto building block. У нас в HKDF.

**HPKE** — Hybrid Public Key Encryption (RFC 9180). Asymmetric encryption combining KEM + AEAD. У нас в MLS internals и во внешнем конверте sealed sender (ADR-023: X25519-HKDF-SHA256-AES128GCM).

**Hello frame** — first WS frame server → client. Carries `challenge_nonce` (32 random bytes) + `server_time` (UTC unix) + version. Client signs challenge for Auth.

---

## I

**IMF-fixdate** — RFC 7231 §7.1.1.1 HTTP Date header format. `"Sun, 06 Nov 1994 08:49:37 GMT"`. Parsed в `sinhron_sync::http_api::parse_imf_fixdate`.

**Identity** — abstract: user's persona. Concrete: `DerivedIdentity` struct + `BasicCredential` MLS credential.

**Locked storage** — ADR-021: база зашифрована, а ключа на телефоне нет (или он не тот). `sinhron_storage` возвращает `StorageError::Locked` и ничего не стирает; приложение показывает экран «Разблокировать». Раньше в этом случае база удалялась.

**Idempotent** — operation that produces same result if applied multiple times. Important для retry safety. Examples: register_identity (replay returns `already_existed: true`), publish_keypackage, storageInit.

**Invariant** — property that must always hold. См. `docs/threat-model.md` §4 для 10 security invariants.

---

## J

**`join_by_card`** — `sinhron_sync/src/client.rs`, вход в чат по карточке чата (external commit). С ADR-100 (0.12.0) берёт карточку, только если её подписало другое устройство того же человека; чужие карточки не берутся, номер чата сверяется до построения, живой чат на телефоне карточкой не трогается, чужие устройства при таком входе не убираются. Следствие: вход «пока все спят» работает только при карточке своего другого устройства текущей эпохи — сначала войти на новом телефоне, потом отключать потерянный.

**JsonCodec** — serde_json-based codec для openmls_sqlite_storage. Reads/writes MLS entities as JSON blobs in SQLite rows. См. `sinhron_sync/src/provider.rs::JsonCodec`.

**JWT** — JSON Web Token. Используется для LiveKit room join authorization. HS256 mint вручную через `hmac+sha2` крейты (без `jsonwebtoken` deps) в `server/src/handlers/call.rs::issue_token`. TTL 1h. Claims: iss/sub/nbf/exp + video.{room, roomJoin, canPublish, canSubscribe} + metadata=group_id_hex. Shared secret в env `LIVEKIT_KEYS`.

---

## K

**Keychain** — защищённое хранилище iOS. У нас там только ключ устройства (ADR-021), канал `dev.sinhron/keychain` в `AppDelegate.swift`.

**KEM** — Key Encapsulation Mechanism. Asymmetric key agreement primitive. В MLS ciphersuite — `DHKEMX25519`.

**KeyPackage (KP)** — pre-published MLS handshake material. Bob publishes 1+ KPs → Alice can Add Bob без round-trip. У нас в `sinhron_sync::create_keypackage` + `POST /v1/keypackages`.

**KID (SFrame)** — Key ID. Used to disambiguate which SFrame key to use for decrypt. Layout per RFC 9605: `(context << (S+E)) + (sender_index << E) + (epoch mod 2^E)`. **У нас S=6 (64 sender_index) + E=4 (16 epoch slots)** — per spec §10.3. Implementation в `sinhron_call::sframe::Kid::compose`. На клиенте rotation via 1s epoch-poll Timer в `LiveKitCallEngine`, plus LiveKit's built-in 16-slot keyring handles overlap window automatically.

---

## L

**Lottie** — формат векторной анимации (JSON, «bodymovin»). Рисует пакет `lottie` (Dart). Стикеры `.tgs` — это Lottie в gzip (ADR-049).

**LAN IP** — local network IP. Mac например `192.168.1.10` или `172.20.10.3` (iPhone hotspot tethering). Need для физический iPhone testing — `--dart-define=SINHRON_WS_URL=ws://<lan-ip>:8080/v1/sync`.

**Audio-only fallback / качество связи** — ADR-041. LiveKit оценивает связь каждого участника (`ConnectionQuality`: excellent / good / poor / lost); экран звонка показывает полоски и «Слабая связь». Если моя связь poor/lost 8 с подряд при включённой камере, приложение выключает камеру (`AudioOnlyFallback`), чтобы не пропадал звук. Пресеты камеры (ADR-046): до 1080p мощные телефоны, до 720p обычные, 360p слабые Android; **потолок видео** (`videoCeilingFor`) опускает верхний слой по связи и нагреву; H.264 где есть аппаратный кодер; резервный кодек выключен (мимо SFrame). На сервере `allow_pause` — SFU ставит чужое видео на паузу при узком канале.

**LiveKit** — open-source WebRTC SFU. Go binary. **У нас v1.11.0 в docker-compose** (`server/docker-compose.yml`: сигналинг 7880 только внутри, клиентам — `wss://<SINHRON_LIVEKIT_HOSTNAME>` через Caddy; медиа 7882/udp + 7881/tcp). Config `server/livekit.yaml` per spec §10.1. Client SDK `livekit_client: 2.7.0` (Flutter). Token mint server-side через HS256 в `server/src/handlers/call.rs`. Mode = SFU forwards encrypted media; E2EE on top через SFrame (custom `BaseKeyProvider` в `lib/features/calls/livekit_engine.dart`).

**LTS** — Long-Term Support. tokio 1.51.6 LTS — supported until March 2027 (было 1.47.3, запись 246).

---

## M

**Migration (DB)** — schema change script. У нас 14 в `server/migrations/` (PostgreSQL; список — code-map.md) + 2 internal "user_version" steps в sinhron_storage (SQLite).

**Капсула-уведомление** (`AppNoticeHost`) — короткое сообщение сверху приложения: «готово» (`showDone`, ✓), заметка или ошибка (`appNotice`); прячется само. Код: `lib/widgets/app_notice_host.dart`.

**Media blob** — зашифрованный файл (фото/голос/документ) на сервере (ADR-017): `nonce‖AES-256-GCM(ct)‖tag` со свежим ключом на каждый блоб, имя = `sha256(blob)`, файл в `SINHRON_MEDIA_DIR`. Ключ, хеш и размеры едут только внутри MLS-сообщения (`MediaRef`). Код: `sinhron_sync/src/media.rs`, `server/src/handlers/media.rs`. Сервер удаляет блоб через 90 дней без обращений; на устройстве — **локальная копия медиа**.

**Локальная копия медиа** (ADR-033) — тот же шифротекст блоба, сохранённый на телефоне в `<файл БД>.blobs/<aa>/<sha256>` при отправке или первом открытии. Без ключа из SQLCipher-базы бесполезен. Живёт, пока на блоб ссылается хотя бы одно сообщение. Код: `sinhron_storage/src/blobs.rs`.

**MLS** — Messaging Layer Security. RFC 9420 — protocol for E2E-encrypted group chat. Implemented by `openmls 0.9.2`. Core primitives: KeyPackage, Welcome, Commit, Application Message, Proposal, Update.

**MlsGroup** — runtime state of one MLS group. Wrapped by `GroupHandle` in `sinhron_sync::group`. Persisted via `openmls_sqlite_storage` (since WU C6).

**Monotonic time** — clock that only goes forward, even after manual adjustment. `std::time::Instant`. **Используется для action-proof timestamps** в `sinhron_net::clock_drift` — после первого WS Hello observation captures `BootPoint { server_secs, instant }`, после чего `corrected_now = boot.server + (Instant::now() - boot.instant)`. Wall-clock больше не читается → user двигая device clock не ломает auth. См. CRIT-1.4 (closed 2026-05-23).

**MSRV** — Minimum Supported Rust Version. У нас 1.75 для server (axum 0.8 requirement); newer для client (openmls dependencies).

---

## N

**NetService** — `client_flutter/lib/core/services/net_service.dart`. Dart singleton wrapping FFI net_*. Drives event loop, routes Push/Welcome/Ack/Connected.

**Nonce (AEAD)** — number-used-once. 12 bytes for AES-GCM. Reused-with-same-key = catastrophic. У нас всегда fresh random via OsRng.

---

## O

**`own_devices_key`** — ADR-103 (0.12.0), `sinhron_sync/src/client.rs`. Ключ, на который запечатывается всё своим устройствам (письмо с новыми ключами аккаунта, перенос): ключ поколения 0 — он есть у всех устройств всегда; содержимое держит MLS. После смены поколения публикуются и ключи поколения 0 (`sealed_keys_to_publish`). Раньше после «Отключить» остальные свои устройства такие письма не открывали. Тест `sinhron_sync/tests/dev1_own_devices_key.rs`.

**Owner check (проверка владельца)** — 0.12.0. Face ID / код телефона (`confirmOwner`, `pickSavedWords` в `features/app_lock/app_lock.dart`) перед привязкой устройства по QR и показом 24 слов (так было и раньше), а с 0.12.0 — перед «Удалить аккаунт», «Выйти», «Отключить» / «Отключить все» в Устройствах, выключением блокировки приложения и сменой «Блокировать снова», вставкой 24 слов из связки ключей / Паролей и «Сохранить в Пароли». Телефон без кода проходит как раньше. Тесты `test/features/app_lock/owner_check_test.dart`, `test/features/settings/seed_words_owner_check_test.dart`.

**openmls** — Rust MLS implementation. Crate `openmls = 0.9.2`. Has `openmls_traits`, `openmls_rust_crypto`, `openmls_basic_credential`, `openmls_sqlite_storage`.

**OpenMlsProvider** — trait combining CryptoProvider + RandProvider + StorageProvider. У нас `SinhronProvider` implements this combining `RustCrypto` + `SqliteStorageProvider<JsonCodec, Connection>`.

**OS-level threading** — pthread / nt threads. tokio runs tasks on these. Rust `Send/Sync` markers gate what can cross thread boundaries.

---

## P

**Padding (anti-traffic-analysis)** — fixed-size or cover-traffic to hide message length. С 2026-10-13 MLS-сообщения паддятся до кратного 512 Б (`sinhron_sync::group::PADDING_SIZE`); cover traffic и паддинг звонков — нет (threat-model §5 п.5).

**parking_lot::Mutex** — fast synchronous mutex (faster than `std::sync::Mutex`). Используется в server для rate_limit + sessions.

**Partition (Postgres)** — table physically split by range/list. У нас `messages` partitioned by month (RANGE on `ts`). Sweep idea: DROP TABLE old_partition вместо DELETE (T3.3, deferred).

**Pending welcome** — Welcome frame queued для offline recipient. Server stores в `pending_welcomes` table; flushes на recipient's next Auth. Risk #10 fix.

**PgBouncer** — пул соединений Postgres. Необязательный сервис compose (профиль `pgbouncer`, режим transaction, tech-debt 2.13); миграции идут мимо него. Живой прогон 2026-10-14 — deploy-guide §10.1.

**PgPool** — sqlx::PgPool — async Postgres connection pool. Max conns env-tunable via `SINHRON_PG_MAX_CONNS`.

**Phase** — большой workflow chunk. Phase 1 = UI / design system. Phase 2 = Rust Core + Server + Sync. Phase 3 = Calls. Это фазы работы, а не спеки: «спек-Фазы» (спека §16) другие — спек-Фаза 4 = несколько устройств (ADR-025), спек-Фаза 6 = медиа; federation / web — вне v1.

**PRAGMA key** — SQLCipher SQL command setting encryption key. MUST be first statement after open. Format: `PRAGMA key = "x'<hex>'"` для raw key.

**Profile** — `cargo --profile <name>` build target. У нас `dev` (default) и `release` (lto, codegen-units=1, strip=debuginfo).

**Prometheus** — open-source monitoring system. We expose `/metrics` in standard text format. Operator scrapes.

**Prost** — Rust protobuf library. Code generation in `build.rs`. Version 0.13.5.

**PrivateMessage (MLS)** — encrypted application message (vs PublicMessage = control). Our app messages are always PrivateMessage.

**Push** — WS frame server → client. Carries `group_id`, `ciphertext`, `message_id`, `delivered_at`, `sequence` (per-recipient monotonic). Resume cursor uses sequence.

---

## Q

**Quad** — N/A. (No Sinhron-specific term.)

---

## R

**`release_preflight.sh` / `release_postcheck.sh` / `release_rollback.sh` / `release_test.sh`** — `server/scripts/`, скрипты выпуска сервера (0.12.0). `release_preflight.sh <версия>` — место на диске, заглушки в `.env`, свежая копия в `/root/backups/pre-<версия>/` с пробным восстановлением, запись коммита и образов; `release_postcheck.sh [<версия>]` — только читает: контейнеры, число миграций, `/_healthz`, `/_readyz`, WebSocket `/v1/sync`, TURN, LiveKit, push; `release_rollback.sh <версия>` — откат к состоянию preflight, спрашивает слово `ОТКАТ`; `release_test.sh` — тесты на подменённых командах, как `install_test.sh`. Порядок выпуска — `docs/release-0.12.0.md`.

**Ratchet (MLS)** — cryptographic mechanism that produces fresh key for each message + advances. Forward secrecy property.

**Rate limit** — token-bucket per (action, key). У нас `server/src/rate_limit.rs::RateLimiter`. 3 policies (register, kp_upload, ws_submit). С 0.12.0 ещё `StaticLimiter` (`server/src/rate_limit.rs`); для WebSocket им заданы пределы в `server/src/ws.rs` — см. `SINHRON_RATE_WS_*`.

**Recovery phrase** — синоним BIP-39 phrase. В приложении — «секретные слова» (см. таблицу «Слова в приложении»).

**Resume cursor** — `(stream_id, last_acked_seq)`. Client sends на reconnect; server replays anything newer. См. `server/src/ws.rs::handle_resume`.

**Reqwest** — Rust HTTP client. Version 0.12.24. We use rustls (no native-tls).

**Rustls** — pure-Rust TLS implementation. Версия 0.23.46. ALL TLS goes through this (WS + HTTP), no openssl in our crates directly (except SQLCipher's vendored OpenSSL).

---

## S

**`SINHRON_MEDIA_TOTAL_BYTES`** — ADR-099 (0.12.0). Общий предел всех зашифрованных вложений на сервере, в байтах; по умолчанию 53687091200 (50 ГиБ). Необязательная переменная сервера.

**`SINHRON_RATE_WS_CONNECT` / `_BULK` / `_COMMIT`** — пределы WebSocket (0.12.0, `server/src/ws.rs`), значения по умолчанию меняются переменными: `_CONNECT` — 600 новых соединений в минуту с адреса (IPv6 — по /64), сверх — 429 до апгрейда; `_BULK` — часовой бюджет больших кадров на аккаунт: кадр до 64 КиБ бесплатен, больший платит жетон за каждые 256 КиБ, 2000 жетонов в час (~500 МиБ); `_COMMIT` — 120 Commit'ов в минуту на аккаунт.

**Спойлер / spoiler** — ADR-070. Часть сообщения, скрытая под «пылью», пока её не коснутся; в поле ввода — `||текст||` или «Формат → Спойлер».

**Sticker pack / набор стикеров** — `PackFile` (protobuf «SNSP» v1, `sinhron_sync::sticker`): название, автор, лицензия, стикеры с превью. Встроенные — ассеты (`sinhron.…`), свои — зашифрованный файл в `<db>.stickers/`. **Код набора** — `sinhron-stickers:<base64url(PackRef)>`: id, название и ссылка на зашифрованный объект на сервере с ключом (ADR-049).

**Связанное устройство / сертификат устройства** — ADR-025. Второе (и далее) устройство человека: свой Ed25519-ключ листа MLS и сертификат `"SDC1" ‖ identity_pub ‖ device_pub ‖ подпись ключом личности` (132 байта) вместо 32-байтного ключа личности в учётных данных. `identity_of_leaf` сводит оба вида к человеку — только если ключ листа тот, что в учётных данных (32 байта = сам ключ листа; в сертификате — ключ листа); иначе лист «никто» (запись 225). Регистрируется `POST /v1/devices`, отзывается `DELETE /v1/devices/{pk}`. **Синхронизация устройств** — добавление своих недостающих устройств во все группы (Commit + Welcome себе, затем история чата — сообщения `History`, запечатанные на свой ключ) и удаление отозванных.

**Ключ доступа (access key, «unidentified access»)** — ADR-026. 16 байт из секрета аккаунта; человек передаёт его собеседникам внутри MLS (сообщение `Access`), сервер хранит только SHA-256. С ключом доступа получателя конверт sealed sender можно отправить без аутентификации (`POST /v1/sealed`) — сервер не узнаёт аккаунт-отправителя. С ADR-071 — **свой у каждого собеседника** (`SyncClient::access_key_for`, из секрета аккаунта и ключа собеседника), сервер хранит набор хэшей (`access_keys`, `PUT /v1/access-keys`); блокировка = отзыв хэша этого человека.

**Запрос (доставка без ключа, ADR-071)** — сообщение человеку, перешедшему на ключи по собеседнику, без его ключа (по WS или обычным `Submit`): доходит в открытое приложение, но телефон не будит и в значке не считается; не больше 60 в минуту от одного человека одному. Так приходят первые сообщения незнакомых и всё, что заблокированный шлёт в обход. Дополнено (status 177): о запросе приходит **push без содержимого**; телефон сам решает — от заблокированного ничего, в принятом чате обычное уведомление, иначе тихое «Новый запрос на переписку» без имени и текста.

**QR-привязка (pairing)** — ADR-027. Новое устройство показывает QR со своим ключом устройства, одноразовым HPKE-ключом и id; устройство с ключом аккаунта подписывает сертификат для этого ключа и запечатывает **пакет связанного устройства** (`sinhron-linked:v1:…` — без ключа личности) в почтовый ящик `/v1/pairing/{id}` (10 минут, один раз; после взятия — отметка, следующий ответ получает 409, ADR-091). Сервер ключа HPKE не видит.

**Ключ аккаунта (account key)** — ключ личности (из 24 слов). Хранится только на первом устройстве; остальные держат пакет со своим ключом и подписывают им — сервер признаёт его, пока устройство не отозвано (`resolve_signer`). Добавить или отозвать устройство на них — вводом 24 слов на этот шаг.

**DsTextArt / DsSpace-полушаги** — tech-debt 2.26. `DsTextArt` — стили текста, которые экраны раньше задавали вручную, с теми же значениями (`t<размер><вес>`); `DsSpace.xNh5` — полушаги сетки отступов (N½ × 4 пт), плюс крупные шаги `x7…x25` (N × 4 пт) и `nudge1…nudge15` — оптические подгонки вне сетки из макетов (те же числа, что были в экранах). Вместе с `DsPalette` / `DsShadow` — в экранах не осталось ни цветов, ни теней, ни размеров шрифта числами.

**Прошлые эпохи (MAX_PAST_EPOCHS)** — сколько прошлых эпох MLS группа помнит ключи (2): сообщение, отправленное рядом с Commit, расшифровывается и после него.

**Прокси SOCKS5 (Tor)** — ADR-028. Настройка «Прокси (Tor)»: весь обмен с сервером (WS, HTTP) через SOCKS5, например Orbot на 127.0.0.1:9050 — сервер не видит IP телефона. Звонки — без прокси.

**Saved messages («Избранное»)** — ADR-055. Чат с самим собой: MLS-группа, где только мои устройства (`sync_create_saved_group`, настройка `saved_chat_id`); синхронизация устройств добавляет новые, история для нового устройства несёт флаг `saved`. Всегда первая в списке, без квитанций, «печатает» и звонков. С ADR-064 — ещё и **канал между моими устройствами** (перенос и синхронизация).

**Копия переписки (chat backup)** — ADR-073. Перенос ADR-064, где вместо сервера — облако самого человека: iCloud Drive (контейнер приложения, iPhone, без настройки) или Google Диск (`appDataFolder`, Android, после «Войти через Google»). Файлы — шифротекст с именами `<метка устройства>-<sha256>` и `<метка>-root.sinhron` (корень с ключом манифеста, под ключом копии из 24 слов). Раз в сутки; медиа уходят один раз; восстановление — сразу после входа по 24 словам или из Настроек. **Метка устройства** — 16 hex из сертификата устройства / ключа личности: копии разных устройств и аккаунтов в одной папке не мешают друг другу. Не путать с **State backup** (MLS-состояние на нашем сервере).

**Добавили обратно (re-add, ADR-074)** — потерял телефон, вошёл по 24 словам на новом: любой участник общего чата, появившись в сети, добавляет новое устройство (только если его KeyPackage подписан тем же человеком, который уже в чате). Новое устройство видит, что Welcome пришёл от другого человека, а в чате уже есть лист моего старого телефона, — значит, чат мой, не «запрос». Запас KeyPackage — 20 после входа, +1 после каждого Welcome.

**Карточка чата (group card, ADR-075)** — публичная часть MLS-группы (GroupInfo: ключи устройств, внешний ключ эпохи; без сообщений и имён), которую участник кладёт на сервер после каждой смены состава. По ней новый телефон человека, который уже в чате, входит сам (external commit), даже если все участники офлайн. С ADR-093 своя карточка у каждого устройства в чате; новый телефон берёт ту, что оставил его человек, иначе ту, за которую больше людей (раньше, ADR-090, — одна карточка, которую менял только автор эпохи). С ADR-100 (0.12.0) вход — только по карточке, подписанной другим устройством своего же человека (см. `join_by_card`); чужие карточки не берутся.

**Подпись приглашения в звонок (caller proof, ADR-090)** — подпись звонящего ключом его устройства над id звонка, чатом и видом (`CallInvite.caller_proof`); телефон называет звонящего только по ней, сервер её лишь передаёт (в VoIP-push — запечатанной ключом телефона, поле `s`).

**Отметка свежей копии (backup mark, ADR-090)** — время самой новой облачной копии устройств аккаунта, которое хранит сервер (`POST /v1/backup-mark`); если в облаке нет копии такой свежести, восстановление предупреждает: её откатили или потеряли.

**Отключить устройство с подписью (signed cut-off, ADR-075)** — отзыв устройства, подписанный ключом аккаунта; подпись хранится с устройством, телефоны собеседников проверяют её сами и убирают отключённый телефон из общих чатов (кроме последнего устройства человека).

**Перенос на новое устройство (device transfer)** — ADR-064. Старое устройство пакует всю свою БД (чаты, вся история, контакты, люди, звонки, настройки, стикерпаки) в зашифрованные части, выкладывает их как медиа и шлёт новому в группе моих устройств конверт `Transfer` с ключом манифеста; новое скачивает и сливает по частям, продолжает после перерыва. Медиа — по ссылкам; чего нет на сервере, старое устройство выкладывает из своих копий (`POST /v1/media/touch`). Задачи — настройки `transfer_out` / `transfer_in`, части до выгрузки — `<БД>.transfer/`.

**Синхронизация моих устройств (DeviceSync)** — ADR-064. Контакты, заблокированные, «без звука / закреплён / архив», стикерпаки и общие настройки — элементы с часами (`sync_clock`, схема v16, `sinhron_storage::devsync`); изменённые уходят конвертом `DeviceSync` в группу моих устройств, применяются «последний пишущий побеждает». Какие настройки общие, какие копируются один раз, какие только свои — в ADR-064.

**Sealed sender** — спека §6.5, ADR-023. Отправитель заворачивает `{group_id, MLS-сообщение}` в HPKE-конверт на еженедельный ключ доставки каждого получателя (`SealedSubmit`); сервер видит только «конверт для ключа K» — не чат и не содержимое. Вскрытие + MLS + проверка отправителя — одна функция `SyncClient::open_sealed`.

**Sealed key (ключ доставки)** — ADR-023. Еженедельный X25519-ключ устройства для sealed sender, выводится из секрета аккаунта (ничего не хранится; одинаков на всех устройствах человека — ADR-025), публикуется в `PUT /v1/sealed-keys`, таблица `sealed_keys`. С ADR-082 подписан хозяином (`sig`; на устройстве по QR — ключом устройства + сертификат `cert`); превью уведомления кладётся только на подписанный ключ. Не путать с `devices.delivery_key` — это токен push-уведомлений.
**Поколение корней (account roots generation)** — ADR-084. После отключения устройства у аккаунта новый корень ключей доставки и ключ копии — из 32 свежих случайных байт (настройка `account_roots` = `<номер>:<hex>`, идёт моим устройствам в группе «только мои»); поколение 0 — прежние, из 24 слов. У отключённого — только поколение 0.

**Sealed key (ключ доставки)** — ADR-023. Еженедельный X25519-ключ устройства для sealed sender, выводится из секрета аккаунта (ничего не хранится; одинаков на всех устройствах человека — ADR-025; после отключения устройства — из текущего поколения корней, ADR-084), публикуется в `PUT /v1/sealed-keys`, таблица `sealed_keys`. Не путать с `devices.delivery_key` — это токен push-уведомлений.

**Session (WS)** — authenticated open WS connection. Tracked in `SessionRegistry` by user_pk. Multi-conn-per-user (phone + desktop потенциально).

**SFrame** — Secure Frame (RFC 9605). E2EE for SRTP video/audio. Keys derived from MLS exporter per §5.2 (HKDF-Extract+Expand). **Реализован в Phase 3** через крейт `sinhron_call::sframe` (~290 LOC, 11 unit tests). Cipher suites: AES-GCM-128-SHA256 (0x0001), AES-GCM-256-SHA256 (0x0002). Critical invariant: `alice_outgoing == bob_incoming` для одного sender_index — test `alice_outgoing_matches_bob_incoming_for_same_sender`. В LiveKit ключ ставится **под идентичностью каждого участника** (ключ личности в hex) — `call_sframe_key_for(group, identity)`, слот = эпоха mod 16 (ADR-024).

**SFU** — Selective Forwarding Unit. Server что forwards media packets без mixing. LiveKit is SFU. **NOT E2EE** by itself — sees ciphertext but не plaintext только если есть SFrame layer выше.

**Sinhron-app** — наш Rust server binary. Container in docker-compose.

**sinhron_core** — Rust crate name for FFI facade (cdylib for Flutter).

**sinhron_crypto, sinhron_net, sinhron_storage, sinhron_sync, sinhron_call, sinhron_cli** — client-side crate names. **`sinhron_call`** added 2026-05-23 для SFrame key derivation + call FSM — pure Rust, no FFI, no libwebrtc; media stays в Flutter `livekit_client`.

**SinhronProvider** — composite OpenMlsProvider в `sinhron_sync::provider`. RustCrypto + SqliteStorageProvider.

**Smoke test** — minimal end-to-end test that proves the basic path works. У нас `bootstrap_smoke.rs`, `full_e2e.rs`, `scripts/integration_smoke.sh`.

**Spec** — `design_handoff_sinhron/spec/architecture.md` 920-line эталон. Single source of truth для intent.

**SQLCipher** — encryption-aware fork of SQLite. AES-256 CBC per page. Transparent — same API as SQLite. У нас через `rusqlite::bundled-sqlcipher-vendored-openssl`.

**SQLite** — embedded relational DB. Single file. Used client-side (encrypted via SQLCipher).

**SQLx** — async Rust SQL driver (different crate from rusqlite). У нас server-side для PostgreSQL.

**SqliteStorageProvider** — openmls_sqlite_storage 0.3.0's implementation of `StorageProvider` trait. Codec-generic over Borrow<Connection>. У нас inside SinhronProvider.

**Stage** — workflow grouping. Backend ladder в `goal-backend.md`: Stage A = Server, Stage B = sinhron_net, Stage C = sinhron_sync, Stage D = sinhron_cli, Stage E = Flutter integration. Phase 3 Calls в `plan-calls.md` использует свой A-F набор: **CA** Infrastructure (LiveKit/coturn), **CB** Signaling (proto + CallSession), **CC** Rust+crypto (sinhron_call + SFrame), **CD** Flutter wire-up, **CE** iOS polish, **CF** Testing+docs.

**Stale-epoch** — MLS frame whose epoch doesn't match group's current epoch. Catched via `IncomingMessage::StaleEpoch` (WU C5).

**State backup** — owner-encrypted snapshot of MLS state uploaded to server. Restores on phrase re-entry. См. `sinhron_sync::state_backup` + spec §6.8.1.

**Storage key** — `DerivedIdentity::storage_key`. 32-byte HKDF-derived from phrase. Used as SQLCipher PRAGMA key. См. T1.1.

**StorageProvider** — `openmls_traits::storage::StorageProvider<VERSION>` trait. ~52 methods for storing MLS entities. Implemented by SqliteStorageProvider.

**Submit** — WS frame client → server. Carries `group_id`, `ciphertext`, `message_id`, `sealed_sender` (since T1.4). Server fanouts to members.

**SyncClient** — top-level handle для MLS-encrypted chat в `sinhron_sync::client`. Wraps SinhronProvider + MlsIdentity + groups HashMap. Single instance per process (sync_slot).

---

## T

**TGS** — `.tgs`, формат анимированных стикеров Telegram: Lottie JSON, сжатый gzip (ADR-049).

**Telegram Bot API / токен бота** — HTTP API Telegram для ботов (`api.telegram.org/bot<токен>/…`); токен выдаёт @BotFather. Наш сервер берёт им набор стикеров по ссылке `t.me/addstickers/<имя>` (`getStickerSet` + `getFile`, ADR-062); токен — файл `/etc/sinhron/telegram/bot-token` на сервере.

**Threat model** — `docs/threat-model.md`. 8 assets, 10 actors, mitigations, invariants.

**ThiserrorError** — `thiserror` crate macro for ergonomic `Error` enums. Used in all our typed errors.

**TLS pinning** — only-trust-our-CA. Vs. default webpki-roots (any public CA). Spec §6.1. У нас opt-in via env (T1.5 Risk #8).

**Token bucket** — rate-limit algorithm. Bucket has capacity; each request consumes 1 token; bucket refills at rate. У нас `RateLimiter`.

**Tracing** — Rust structured logging crate. Used for all server/client logging. Env: `RUST_LOG=info` etc.

**Tungstenite / tokio-tungstenite** — Rust WebSocket libraries. Version 0.29.0.

**TURN** — relay server для NAT traversal. coturn implementation. **Реализован в Phase 3.** Credentials minted server-side по REST-API HMAC-SHA1 паттерну (RFC 5766): `username = "<expiry>:<random nonce>"` (без identity — логи coturn не раскрывают звонящих), `credential = base64(HMAC-SHA1(TURN_SHARED_SECRET, username))`. Эндпоинт: `GET /v1/call/turn` в `server/src/handlers/call.rs`. Client fetch via `sinhron_sync::HttpApi::request_turn_creds`.

---

## U

**UUID** — Universally Unique Identifier. v4 (random) для user_pk, v7 (time-ordered) для message_id (sorts by time, partition-key friendly per spec §7.4).

---

## V

**Version_seq** — monotonic counter for state_backups. Server rejects PUT with `<= existing` value. Client must increment after success.

**Video note / кружок** — круглое видеосообщение (ADR-048): до 60 с с фронтальной камеры, квадрат 480 px; на проводе — обычное видео (`MediaKind::Video`) с флагом `MediaBody.round` (тег 13), в базе `"round":true` в `media_json`. Старые приложения показывают его как обычное видео. Приватность (status 172): уходит только квадрат с чёрными углами вне круга (не обрезалось — не уходит ничего), и показывается кружок только кругом (`VideoNoteCircle`) — в чате, «Медиа и файлах» и галерее; «Поделиться» / «В Фото» для него нет. Код — `lib/features/video_note/`.

---

## W

**WAL** — Write-Ahead Log. SQLite journal mode. Atomic commit via sidecar `-wal` file rename. Better concurrency + crash resilience. У нас обязательно (Risk #1 fix).

**Welcome** — MLS frame. Carries new member's encrypted ratchet tree share + group secrets. Inviter generates → ships to invitee. У нас через `POST /v1/welcomes` would be... нет, через WS `Welcome` frame body (added в C4) + queued via `pending_welcomes` if recipient offline (Risk #10).

**Webpki-roots** — Mozilla's collection of trusted root CAs. Default trust store. Used when TLS pinning is off.

**Workspace (Cargo)** — directory containing multiple crates with shared dependency resolution. У нас 2 (client_flutter/rust + server).

**WU** — Work Unit. Atomic work item, 3-8 hours estimated. См. `docs/status.md` and `docs/goal-backend.md` for WU lists.

---

## X

**X-Forwarded-For** — HTTP header. Caddy sets it to client's real IP when proxy'ing. Used by rate-limit-by-IP (not yet implemented; we limit by pubkey).

**X25519** — Diffie-Hellman key agreement on Curve25519. Sub-key in DerivedIdentity. Used for HPKE encryption.

**X-Request-Id** — HTTP header added by `tower-http::SetRequestIdLayer`. UUID. Propagated to response. Used for log correlation across many lines per request.

---

## Y, Z

(No Sinhron-specific terms.)

---

## Слова в приложении ↔ технические термины (2026-10-18)

Владелец: приложение говорит словами нетехнического человека. В интерфейсе — левая колонка, в коде и доках — правая.

| В приложении (ru / en) | Что это технически |
|---|---|
| **Секретные слова** / Secret words — «вернут аккаунт на новом телефоне» | Recovery phrase = BIP-39, 24 слова (было «Ключ от аккаунта» / Account key) |
| **Сохраните доступ к аккаунту** / Keep access to your account | ADR-059 — шаг 3 регистрации и карточка-напоминание: сохранить 24 слова в «Пароли» / менеджер паролей, записать или «Позже» |
| **Лист восстановления** / Recovery sheet | ADR-059 — картинка для печати: 24 слова, QR с ними, предупреждение |
| **Адрес** / Address — «Ваш адрес в Sinhron», «Скопировать адрес», «Вставить адрес» | Identity public key (64 hex) и его fingerprint `9a3e 4d12 …` (было «ключ») |
| **Поделиться, чтобы мне написали** / Share so people can message me | Подписанная ссылка-приглашение (ADR-043), запасной вариант — адрес текстом |
| **Мой профиль** / My profile — открывается фото слева вверху | `MyProfileScreen`: фото, имя, «О себе», QR-контакт в карточке цвета акцента (`DsQrCard`), адрес; нажатие на фото — на весь экран |
| **Резервная копия** / Chat backup — «Копия каждый день», «Восстановить из копии», «Включить копию на этом устройстве» | ADR-073 — копия переписки в iCloud Drive / Google Диске (`ChatBackup`, `backup_screen.dart`); «включить на этом устройстве» — 24 слова добавляют ключ копии в пакет старого связанного устройства |
| **Сообщить о проблеме** / Report a problem | Файл с журналом приложения и системной части за последний час + факты о телефоне (`diag_log.dart`, `report_problem/`); без текста сообщений, имён и ключей |
| **Недавние** (в поиске) / Recent | Чаты, открытые из поиска (`search_recent`, только id чатов; × — убрать один, «Очистить» — все) |
| **Проверка собеседника**, **код проверки** / Check it’s really them, check number | Safety number (60 цифр) / verify (было «Код безопасности») |
| **Устройства** / Devices | Linked devices (было «Связанные устройства») |
| **Зашифровано** / Encrypted | E2EE (было «Сквозное шифрование» — осталось в правилах с пояснением) |
| **Отметки «Прочитано»** / Read ticks | Read receipts |
| **Анонимные сообщения**, «сбросить доступ» / Anonymous messages, reset access | Sealed sender, rotate access key (ADR-026) |
| **Запасной путь для звонков** / Backup route for calls | Reserve path, TURN/TLS 443 (ADR-042) |
| **Временные файлы** / Temporary files | Cache (превью, миниатюры) |
| **Для опытных** / Advanced | Сервер, соединение, прокси (Tor) — внизу Настроек |
| **Подключено как дополнительное** / added to your account later | Не primary device: нет account key на устройстве |

---

## Команды-shorthand для quick context

| Phrase | Что значит |
|---|---|
| "WU 73.1" | Work Unit 73.1 — ChatView message persistence (Phase 2 step) |
| "T1.1" | Tier 1, Item 1 — SQLCipher (overnight session naming) |
| "Risk #N" | Hardening item N — см. docs/status.md секцию hardening |
| "ADR-NNN" | Architecture Decision Record number N — docs/decisions.md |
| "§N" | Section N of spec — design_handoff_sinhron/spec/architecture.md |
| "frb codegen" | flutter_rust_bridge_codegen generate |
| "full_e2e" | client_flutter/rust/sinhron_sync/examples/full_e2e.rs (Alice↔Bob проф) |
| "the spec" | design_handoff_sinhron/spec/architecture.md (920 строк) |
| "Тихий" | Вид приложения с 0.13.0 (ADR-107): почти без цвета, Golos Text, без теней и цветных плиток; свои сообщения — сплошной акцент с белым текстом. Движение — ADR-108 (120 / 200 / 300 мс) |
