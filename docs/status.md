# Sinhron · журнал работы

> Новая запись — сверху: что и зачем, файлы, чем проверено, что осталось. Репозиторий открытый — без личных данных
> (`CLAUDE.md`). Журнал до 2026-11-13 (записи 1–261) остался в прежнем закрытом репозитории; ссылки «запись N» в
> документах ведут туда.

---

## 2026-11-13 (262) · Открытый репозиторий с чистого листа; сборки и выкладка без Мака

**Что.** Владелец: открытый репозиторий от организации, без личной информации; собирать и выкладывать через GitHub
(минуты Actions в закрытом репозитории кончились, у открытого они бесплатные). Код — тот же, что в PR #98 прежнего
репозитория (0.12.0 + дополнение; все проверки CI там зелёные), одним коммитом без истории.

**Убрано из открытой копии:** журнал работы и список дел (новые — эти файлы), ночные журналы (`overnight-*`),
`docs/evidence`, `docs/fixes-2026-11b` (заметки к заплаткам), граф `graphify-out/` (пересказы всех документов), архив
`sinhron (2).zip`. В оставшихся файлах — имя и почта владельца, упоминания родственников, страна провайдера, пути с Мака
заменены нейтральными словами. Оставлены: имя сервера и его IP в коде и тестах (они вшиты в приложение), Team ID Apple,
адрес в политике конфиденциальности (`server/download/privacy.html`, контакт для пользователей).

**Новое:**
- `.github/workflows/release.yml` — Actions → Release → Run workflow: Android (`android_release.sh`, ключ подписи из
  секретов → выпуск на GitHub с APK и `android.json`), iPhone (macos-26: проверка Swift `PushShared`, затем
  `testflight.sh` → TestFlight).
- `client_flutter/scripts/testflight.sh` — с `ASC_KEY_PATH` / `ASC_KEY_ID` / `ASC_ISSUER_ID` (ключ App Store Connect API)
  архив и выгрузка идут через `xcodebuild … -allowProvisioningUpdates -authenticationKey…`; на Маке — как раньше.
- `client_flutter/scripts/android_release.sh` — только `android-arm,android-arm64` (выкладываются только они; x86_64 не
  собирался зря).
- `server/scripts/fetch_android.sh <tag>` — на сервере: APK и `android.json` из выпуска GitHub, сверка SHA-256, раскладка
  как у `publish_android.sh`.
- `docs/release-0.12.0.md` — шаги 1–6 и 12 через GitHub вместо Мака; шаг 7 — `git tag pre-0.12.0` и новый `origin`
  вместо файла bundle. `server/install.sh` `DEFAULT_REPO_URL`, `deploy-guide.md`, `onboarding.md`, `code-map.md`, `CLAUDE.md`.

**Проверено:** `fetch_android.sh` — на подменённом `curl` (раскладка, три последние сборки, отказ при неверном SHA-256);
`release.yml` — разбор YAML. Остальные тесты — CI нового репозитория на первом push.

**Не проверено:** сборка iPhone на GitHub не запускалась ни разу — первый запуск может потребовать правки (подпись
ключом App Store Connect, версия Xcode на `macos-26`). Поэтому запустить её заранее, до вечера выпуска.
