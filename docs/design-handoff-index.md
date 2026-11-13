# Sinhron · Design Handoff Index

Карта всех 37 JSX-файлов из `design_handoff_sinhron/design/app/` → их назначение, спека-ссылка, приоритет, текущий Flutter-статус.

**Источник:** `design_handoff_sinhron/README.md` (раздел «Sections in the canvas, mapped to spec») + ручная разметка приоритета и статуса.

> **2026-10-26 (KISS):** экраны, которые жили только как макеты в демо-галерее (`disappearing`, `lockscreen`, `scan_qr`, `reverify_phrase`, `biometric_prompt`, `reset_app_lock`, `switch_server`, `operator_legal`, `notification_overrides`, `group_info` и др.), удалены из клиента вместе с галереей. «done» ниже — история переноса дизайна, не наличие экрана в приложении; что есть сейчас — `docs/code-map.md` §4.1.

## Условные обозначения

| Поле | Значения |
|---|---|
| **Priority** | `MUST` (must-have для v1.0) · `NICE` (включить если есть время в 1.0) · `POST` (post-MVP, 1.x) |
| **Status** | `done` (реализовано в Flutter, есть на iOS Sim) · `partial` (часть виджетов есть, экран не собран) · `pending` (ждёт своей очереди) · `n/a` (не для портирования: design-system spec cards) |
| **WU №** | Work Unit number из [`plan-phase1-frontend.md`](plan-phase1-frontend.md) |

---

## Полная таблица (37 файлов · 74 экрана)

| WU | JSX-файл | Что внутри | Spec §§ | Priority | Status |
|----|---|---|---|---|---|
| 1 | `entry.jsx` | Onboarding flow: welcome, get-started, server URL, profile setup, recovery phrase. | §6.1, §6.2, §6.8 | MUST | **done** ✅ WU 2-7 (Welcome/ServerInvite/Profile/Recovery/SettingUp/EmptyChats) |
| 1 | `spec-buttons.jsx` | 4×4 матрица состояний кнопок. Reference для DsButton golden-тестов. | — | MUST | **done** ✅ WU 1 (DsButton 4×4 + sizes + iconOnly) |
| 2 | `onboarding-splash.jsx` | Первый launch экран · логотип + tagline + CTA. | §3 | MUST | **done** ✅ WU 2 |
| 6 | `chat-view.jsx` | 1:1 conversation. Bubble + Composer + day separators + scroll-FAB. | §8, §11.2 | MUST | **done** ✅ WU 9 + 9.1 polish |
| — | `chat-list.jsx` | Главный экран: header + filter pills + chat rows + tab bar. | §8 | MUST | **done** ✅ + swipe-row + pull-refresh |
| 7 | `document-bubble.jsx` | Типизированный файл-bubble (4 состояния). | §6.9, §11 | NICE | **done** ✅ WU 35 (DocumentChat) |
| 8 | `settings.jsx` | Settings root + 8 разделов. | §6.7, §8 | MUST | **done** ✅ WU 10 |
| 9 | `settings-detail.jsx` | Sub-screens: Server / App lock / Privacy / Notifications / Recovery / etc. | §6.7, §8 | MUST | **done** ✅ WU 13-19 |
| 10 | `contact-info.jsx` | Профиль контакта · Verify safety number CTA · common groups. | §6.4 | MUST | **done** ✅ WU 11 + WU 43 (shared media wire) |
| 11 | `compose.jsx` | New chat picker + search + quick actions. | §6.1 | MUST | **done** ✅ WU 20 |
| 12 | `groups.jsx` | Group create + member management + group info. | §6.3 | MUST | **done** ✅ WU 22 + WU 48 (NewGroup) + WU 51 (LeaveGroup) |
| 13 | `calls.jsx` | 1:1 call screens (3 states × 2 media). | §10 | MUST | **done** ✅ WU 23 |
| 13 | `active-call-bar.jsx` | Mini-bar over any screen. | §10 | MUST | **done** ✅ WU 40 |
| 14 | `group-calls.jsx` | Group call (2×2 / 3×3 / spotlight). | §10.5 | MUST | **done** ✅ WU 42 |
| 14 | `call-participants.jsx` | Modal со списком участников + host actions. | §10 | NICE | **done** ✅ WU 41 |
| 15 | `verify.jsx` | Safety number screen — единственное место "E2EE" видимо. | §6.4 | MUST | **done** ✅ WU 24 |
| 15 | `trust-polish.jsx` | Identity-changed warning + 4 perm prompts. | §6.5, §9.3 | MUST | **done** ✅ WU 53 |
| 15 | `message-request.jsx` | UX для входящих запросов от незнакомых. | §6.5 | MUST | **done** ✅ WU 30 (через states) |
| 16 | `states.jsx` | Archived / Blocked / Message-request. | §9.1, §9.4 | MUST | **done** ✅ WU 30 |
| 16 | `no-internet.jsx` | Offline / Reconnecting / Restored. | §9.1, §9.4 | MUST | **done** ✅ WU 30 |
| 16 | `chat-completion.jsx` | Selection mode + Pinned banner + Pinned list + Error states. | §9.1 | NICE | **done** ✅ WU 55 |
| 16 | `disappearing-active.jsx` | Countdown ring chips + accent subtitle. | §6.6 | NICE | **done** ✅ WU 38 |
| 17 | `media.jsx` | Full-screen media viewer. | §6.9, §11 | MUST | **done** ✅ WU 28 |
| 18 | `devices-manage.jsx` | Linked devices manage · revoke · stale flag. | §6.2 | MUST | **done** ✅ WU 37 + WU 50 (LinkDevice) |
| 19 | `composer-pack.jsx` | Reply / @mention / sticker tray. | — | NICE | **done** ✅ WU 26 + WU 27 (live wire) |
| 20 | `message-actions.jsx` | Long-press menu на bubble. | §8.5 | NICE | **done** ✅ WU 25 |
| 21 | `lockscreen.jsx` | OS lockscreen push preview · 3 modes. | §9.3 | MUST | **done** ✅ WU 34 |
| 22 | `server-detail.jsx` | Self-host server screen. | §7.1, §7.6, §12 | MUST | **done** ✅ WU 16 + WU 59 (SwitchServer / PP / ToS) |
| 23 | `storage-data.jsx` | Storage management · stacked bar · top chats. | §6.7, §11.3 | MUST | **done** ✅ WU 13 |
| 24 | `account-delete.jsx` | Destructive delete (3-step). | §6.2, §6.3 | MUST | **done** ✅ WU 31 |
| 25 | `perm-denied.jsx` | Push permission rejected state. | §9.3 | MUST | **done** ✅ WU 39 |
| 26 | `search.jsx` | Local search overlay. | §8.5 | NICE | **done** ✅ WU 21 |
| 27 | `invite-link.jsx` | Accept invite + paste token flow. | §6.1 | MUST | **done** ✅ WU 54 |
| 28 | `loading-skeletons.jsx` | Shimmer placeholders. | §8.5, §9.4 | NICE | **done** ✅ WU 29 |
| 29 | `schedule-send.jsx` | Schedule message (picker + chat + drawer). | (post-MVP §15.1) | POST | **done** ✅ WU 36 |
| — | `chat-events.jsx` | In-chat system messages composite (8 pill variants). | §6.3, §6.5 | MUST | **done** ✅ WU 60 |
| — | `spec-icons.jsx` | 75 glyphs reference. **Не портируется как экран** — DsIcon содержит 14 shapes; ~60 inline custom-painters рассыпаны по фичам по мере необходимости. | — | n/a (reference) | partial — DS-hygiene gap, см. status.md |

### Сверх дизайна (Sinhron-специфичные новые экраны)

| WU | Feature | Что добавили |
|----|---------|--------------|
| 43 | `shared_media` | 4-tab media gallery (Media / Files / Voice / Links, as in Telegram — owner 2026-11-03; was 5 tabs with All) — из spec §6.9 |
| 44 | `show_qr` | QR code identity card с двумя modes (myQr / invite) |
| 45 | `blocked_contacts` | Dedicated list с info-section "what blocking does" — separated из states.jsx |
| 46 | `sign_out` | Per-device sign-out flow с MLS-narrative |
| 47 | `notification_overrides` | Per-chat picker для overrides |
| 49 | `scan_qr` | Universal camera viewfinder с 3 purposes (invite / verify / link-device) |
| 52 | `reverify_phrase` | 3-word quiz |
| 57 | `calls_list` | Calls tab content — из ничего по iOS Phone.app pattern + spec §10 |
| 58 | `contacts_list` | Contacts tab content — directory с MY CARD + Favourites + Verified + A-Z |
| 59 | `biometric_prompt` | Face ID mock prompt |
| 59 | `reset_app_lock` | Recovery-phrase entry screen |
| 59 | `switch_server` | Community server picker |
| 59 | `operator_legal` | Privacy policy + ToS webview stubs |

---

## Итог coverage

**100% (37/37 designed JSX-файлов реализовано).** Plus 13 экранов сверх дизайна (см. таблицу выше).

**По состоянию на 2026-05-21:**
- 45 feature directories
- 18 Ds-виджетов (включая 3 motion primitives: DsSwipeActions / DsPullToRefresh / DsDraggableSheet)
- 92 PREVIEW cases
- 41 golden snapshot test (43/43 widget+golden tests pass)
- 0 ComingSoon endpoints
- 0 tab placeholders (все 4 tab'а имеют живой контент)

Подробности см. [`status.md`](status.md).

---

## Что построено сверх Flutter — поддержка тестирования

- `test/widget_test.dart` — 9 тестов (DsAvatar light/dark, group+online, DsChatRow unread/group/typing/sent-read, DsTokens semantics).
- `test/test_harness.dart` — `loadAppFonts()` + `wrapForGolden()`.
- `test/goldens/` — 7 PNG snapshots.
- `.claude/cdp_screenshot.mjs` + `.claude/serve_web.py` + `.claude/launch.json` — web-preview pipeline для headless проверки через Chrome CDP.

---

## Ссылки на дизайн

- **Открыть всё сразу:** `../design_handoff_sinhron/design/index.html` в Chrome (pan/zoom)
- **Отдельный экран:** `../design_handoff_sinhron/design/app/<имя>.jsx` (это **React**, не Flutter — читать как визуальную спеку)
- **CSS-токены источник:** `../design_handoff_sinhron/design/app/tokens.css` (зеркалируются в `client_flutter/lib/app/theme/tokens.dart` — уже сделано)
- **Иконография:** `../design_handoff_sinhron/design/app/spec-icons.jsx` — 75 glyphs, 24×24 viewBox, 1.8px stroke
- **Components handoff таблица:** `../design_handoff_sinhron/README.md` (раздел «Component library»)
