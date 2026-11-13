# Android-клиент Sinhron — план (2026-10-16)

Решения владельца (2026-10-15): **без Google Play Services / FCM, без Huawei, без платных магазинов.**
**Пересмотрено 2026-10-18 (ADR-057):** владелец решил добавить **push Google (FCM)** — только «разбудить», содержимое
запечатано ключом телефона; ntfy и «Постоянное соединение» остаются для телефонов без Google.
**2026-10-19 (status 174):** с работающим push Google «Постоянное соединение» выключено — push будит Sinhron, в фоне сокета нет
(батарея). Экран всегда на общем движке Flutter (`SinhronApplication`): код приложения живёт, пока жив процесс, — смахнутый
Sinhron читает своё соединение и показывает звонок и «Имя: текст» (раньше движок экрана умирал, а сокет в ядре Rust — нет).
Push — **UnifiedPush** через свой **ntfy** на сервере оператора; уведомления рисует сам Sinhron (нативно).
Раздача — **APK** (GitHub Releases / сайт) + **Obtainium** для обновлений; позже F-Droid.

Flutter-код общий: всё, что в Dart, на Android уже работает. Не хватает того, что на iOS сделано нативно
(Swift) и через сервисы Apple. Ниже — что именно, как, и кто/что нужно.

## 1. Что уже общее и работает без изменений
- Весь интерфейс, хранилище (SQLCipher в Rust), MLS, звонки LiveKit/SFrame (Dart + WebRTC), медиа, голосовые.
- Плагины с поддержкой Android: `path_provider`, `livekit_client`, `flutter_webrtc`, `permission_handler`,
  `image_picker`, `file_picker`, `share_plus`, `gal`, `record`, `just_audio`, `audio_session`, `url_launcher`,
  `video_player`, `local_auth`, `video_compress`, `screen_protector`, `camera` (кружки, ADR-048 — `camera_android_camerax`).

## 2. Нативные каналы iOS → Android

| Канал | iOS | Android (сделать) |
|---|---|---|
| `dev.sinhron/keychain` (`read/write/delete`) | Keychain, `ThisDeviceOnly` | ключ AES-GCM в **Android Keystore** (не выгружается), значения зашифрованы им и лежат в `SharedPreferences`; бэкап выключен |
| `dev.sinhron/qrscan` (`scan`) | AVFoundation | своё окно сканера: **CameraX + ZXing core** (без ML Kit / Play Services) |
| `dev.sinhron/push` (`register/status/voipToken/takeOpened/ntfyInstalled/openNtfy/reconnect`; `token/voipToken/opened`) | APNs + PushKit | **UnifiedPush connector**: адрес (endpoint) от дистрибьютора (ntfy) → на сервер как токен `alert` и `voip`; разрешение `POST_NOTIFICATIONS`. Какой сервер вписать в ntfy, приложение узнаёт у сервера (`GET /v1/push/info`) и показывает в «Уведомлениях» (status 150) |
| `dev.sinhron/callkit` (`startCall/reportIncoming/endCall/dismiss`; `onAccept/onEnd/onMute/onShowIncoming`; `reportIncoming` → показала ли система — ADR-063) | CallKit | **уведомление звонка** (CallStyle, полноэкранное на экране блокировки) с «Ответить» / «Отклонить»; то же «забирание» звонка Dart'ом, что ADR-039; **foreground service** (микрофон / камера) на время звонка |
| `dev.sinhron/badge` | значок на иконке | на Android цифру рисует лаунчер по уведомлениям: `set` — ничего; разрешение — `POST_NOTIFICATIONS` |
| снимок экрана (ADR-030) | `screen_protector` | Android 14+: `registerScreenCaptureCallback`; ниже — нет события |
| `dev.sinhron/media` → `squareVideo` (ADR-048) | `VideoNoteExport` (`AVAssetExportSession`, чёрная маска вне круга — `AVVideoCompositionCoreAnimationTool`) | `VideoNotes.kt`: **Media3 Transformer** (AndroidX, без Play Services) — центр кадра 480×480, чёрное вне вписанного круга (`OverlayEffect` + `BitmapOverlay`, status 172), H.264 1 Мбит/с |

## 3. Сервер
- **UnifiedPush-доставка:** токен устройства может быть адресом `https://…` (endpoint UnifiedPush) — тот же
  `PUT /v1/push-token`, та же подпись. Сервер шлёт `POST` на адрес с маленьким JSON: `{"t":"msg","n":<бейдж>}`
  или `{"t":"call","id":"…","v":true|false}` (ни текста, ни чата, ни имени — как в APNs).
- **Защита от SSRF:** только `https`, только хосты из `SINHRON_UNIFIEDPUSH_HOSTS` (свой ntfy оператора);
  пусто — UnifiedPush выключен, регистрация такого токена → 400.
- **ntfy в docker compose** (профиль `ntfy`, свой поддомен через Caddy) — включается в установщике
  (`ENABLE_NTFY=yes`, `NTFY_DOMAIN=push.<домен>`). Нужна DNS-запись от владельца.
- Шифрование тела (WebPush RFC 8291) — сделано (ADR-040 доп. 2): ntfy видит только шифртекст; нешифрованные push телефон отбрасывает.

## 4. Сборка и раздача
- **Иконка** (запись 162): адаптивная, как на iPhone — `res/drawable/ic_launcher_*.xml` + `mipmap-anydpi-v26`; стандартной иконки Flutter больше нет.
- Gradle: `minSdk 26` (Android 8), `compileSdk 36`, NDK 28 (Flutter 3.41); Rust через cargokit для
  `aarch64` / `armv7` / `x86_64`. Разрешения в манифесте, `allowBackup=false` + `dataExtractionRules`
  (как ADR-036), `MainActivity` → `FlutterFragmentActivity` (нужно `local_auth`).
- Ключ подписи release — создаётся локально, **хранится вне git** (`~/Documents/Keys/sinhron/`), пароль — в
  файле рядом; потерять ключ = обновления не встанут. `scripts/android_release.sh` собирает подписанный APK.
- Раздача: GitHub Release с APK (публикует владелец) → Obtainium подхватывает обновления.

## 5. Что можно сделать без владельца и телефона (ночь 15→16) — очередь в `overnight-backlog.md` (сделано — см. status 89)
1. Поставить JDK 17 / Android SDK / NDK / Rust-таргеты (разрешено владельцем 2026-10-15).
2. Gradle и манифест, `FlutterFragmentActivity`, бэкап выключен; **собрать debug APK** (проверка, что Rust,
   SQLCipher/OpenSSL и все плагины собираются под Android).
3. Keystore-канал (Kotlin) + тест Dart-стороны.
4. QR-сканер (CameraX + ZXing).
5. Сервер: UnifiedPush-доставка + allowlist + ntfy в compose/установщике; тесты.
6. Клиент: UnifiedPush (Kotlin receiver, нативное уведомление «Новое сообщение»), канал push на Android.
7. Звонки: уведомление входящего звонка + foreground service на время звонка; `CallKitBridge` на Android.
8. Значок/разрешение уведомлений, снимок экрана (Android 14+).
9. Release-подпись и скрипт; документы (ADR-040), отчёт.

## 6. Что нужно от владельца / телефона
- Android-телефон (или эмулятор — на общем Mac окна не открываем): установка APK, проверка push, звонков,
  камеры, биометрии.
- ~~DNS `push.777400777.xyz` → 176.124.223.138, затем включить ntfy на сервере~~ — сделано 2026-10-18: ntfy работает на `https://push.777400777.xyz` (установщик находит имя сам).
- На телефоне — приложение **ntfy** (Google Play или F-Droid), сервер в нём — свой `push.…`: адрес, кнопки «Скопировать» / «Открыть ntfy» / «Подключить ntfy» Sinhron показывает сам в «Настройки» → «Уведомления» (status 150; проверить на телефоне).
- Публикация APK (GitHub Release) — решение владельца.

## 7. Позже
- ~~«Постоянное соединение» без дистрибьютора~~ — сделано: «Всегда на связи» (ADR-040, доп. 1; status 92).
- Расшифровка текста в уведомлении (как Notification Service Extension на iOS).
- F-Droid (воспроизводимая сборка, без проприетарных зависимостей).
