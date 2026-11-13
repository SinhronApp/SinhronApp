# Phase 1 · UI-first build plan

> **Цель Phase 1:** построить максимум Flutter-экранов на статических данных. Без Rust Core, без сервера, без сети. Когда визуально готово — переключаемся на Phase 2 (Rust Core + frb-bindings), вырываем фейковые data-providers и втыкаем настоящие View-Model'и из Core.

---

## Стратегия

1. **Сначала атомы, потом экраны.** Каждый Ds-виджет, который используется в N экранах, строим один раз. Не дублируем.
2. **Виджеты с golden-тестами.** §15.3 спеки требует golden-снэпшот на каждый `Ds*`. Снимок при создании, regression check на каждом изменении.
3. **Каждый экран — отдельный feature dir в `lib/features/`.** Имя — из спеки §8.1: `onboarding`, `chat_view`, `settings`, `composer`, `call`, `device_pairing`. Новые features (не упомянутые в §8.1, но нужные по дизайну): добавляем по мере необходимости — например, `groups`, `media`, `contact_info`.
4. **Fake data в `*_data.dart`** рядом с экраном. Точно как `chat_list/chat_data.dart`. После Phase 2 эти файлы удаляются и заменяются Riverpod-провайдерами.
5. **Riverpod 3.0 + go_router — позже.** Сейчас одна экранка, навигация не нужна. Введём, когда появится 2+ экрана. См. ADR-005.
6. **iOS Simulator — основная цель верификации.** Web (CDP screenshot) — fast feedback loop в процессе.

---

## Очерёдность

Логика приоритизации:
- **A.** Снять блок: атомы (DsButton, DsTextField, DsCheck) нужны почти везде. Без них нельзя строить ни один экран сложнее chat list.
- **B.** Первый user touch: onboarding-splash + entry. Это то, что юзер видит **до того, как** дойдёт до chat list.
- **C.** Самый-частый экран: chat-view. Большой, но открывает Bubble + Composer — атомы для chat-events, message-request, message-actions.
- **D.** Управление: settings root + settings detail. Каркас для всех config-сабэкранов.
- **E.** Связи: contact-info, compose, groups. Здесь начинаем рисовать связи между пользователями.
- **F.** Звонки: 1:1 calls → group calls → call participants. Самостоятельный кластер.
- **G.** Состояния: offline, reconnect, archived, blocked, disappearing.
- **H.** Polish: media viewer, documents, composer-pack (reply/mention/stickers), trust surfaces, message actions.

### Конкретный порядок задач (work units)

| WU | Subject | Что строим | Источники | Зависимости |
|----|---|---|---|---|
| **0** | Build order kickoff | Этот документ + ADR-005 + ADR-006 | — | — |
| **1** | Atoms: DsButton + DsTextField + DsCheck + DsAppBar | 4 базовых виджета, golden-тесты на каждый | `entry.jsx`, `spec-buttons.jsx` | — |
| **2** | onboarding-splash | Первый launch экран · логотип + кнопка | `onboarding-splash.jsx` (~10 КБ) | WU 1 |
| **3** | entry (welcome) | «Get started» / «Link device» / «Restore phrase» + flow создания identity | `entry.jsx` (~35 КБ — самый большой файл) | WU 1, 2 |
| **4** | DsMnemonicGrid | 24-слова BIP-39 grid с blur-until-tap | `entry.jsx` | WU 1 |
| **5** | Подключить **go_router** | Навигация: splash → entry → chat list | — | WU 2-4 |
| **6** | chat_view core | Bubble + Composer + day separators + reply preview | `chat-view.jsx` (~16 КБ) | WU 1 |
| **7** | chat_view extensions | Voice waveform · Photo with BlurHash · Document bubble | `chat-view.jsx`, `document-bubble.jsx` | WU 6 |
| **8** | settings root | Settings экран · список разделов | `settings.jsx` (~20 КБ) | WU 1 |
| **9** | settings-detail | Server / Linked devices / Recovery / App lock / Privacy / Storage / Notifications | `settings-detail.jsx` (~21 КБ) | WU 8 |
| **10** | contact-info | Профиль контакта · Safety number entry | `contact-info.jsx` (~22 КБ), `verify.jsx` | WU 1 |
| **11** | compose (new chat) | Контакт-picker · search | `compose.jsx` (~14 КБ) | WU 1, 5 |
| **12** | groups (manage) | Создание/управление группами | `groups.jsx` (~27 КБ) | WU 1, 6, 10 |
| **13** | Calls 1:1 | Incoming · audio · video · ended · active-bar | `calls.jsx` (~21 КБ), `active-call-bar.jsx` | WU 1 |
| **14** | Group calls | 2×2 / 3×3 / spotlight grids · participants modal | `group-calls.jsx` (~18 КБ), `call-participants.jsx` | WU 13 |
| **15** | Trust surfaces | Safety number screen · Identity changed warning · Message request | `verify.jsx`, `trust-polish.jsx`, `message-request.jsx` | WU 10 |
| **16** | States / connectivity | Offline · reconnect · archived · blocked · disappearing | `states.jsx`, `no-internet.jsx`, `chat-completion.jsx`, `disappearing-active.jsx` | WU 6 |
| **17** | Media | Photo/video full-screen viewer | `media.jsx` (~19 КБ) | WU 6 |
| **18** | Devices manage | Linked devices list · revoke · safety check | `devices-manage.jsx` | WU 9 |
| **19** | Composer pack | Reply preview · @mention picker · stickers tray | `composer-pack.jsx` (~20 КБ) | WU 6 |
| **20** | Message actions | Long-press menu | `message-actions.jsx` (~17 КБ) | WU 6 |
| **21** | Lockscreen mockup | Push notification preview · Hide previews | `lockscreen.jsx` | WU 1 |
| **22** | Server detail | Self-host server info screen | `server-detail.jsx` (~18 КБ) | WU 9 |
| **23** | Storage data | Cache management · LRU budget | `storage-data.jsx` (~14 КБ) | WU 9 |
| **24** | Account delete | Destructive account/device deletion flow | `account-delete.jsx` (~15 КБ) | WU 9 |
| **25** | Permission denied | Push perm prompt rejection state | `perm-denied.jsx` | WU 1 |
| **26** | Search | Local search overlay | `search.jsx` (~15 КБ) | WU 6 |
| **27** | Invite link | Accept invite link flow | `invite-link.jsx` | WU 3 |
| **28** | Loading skeletons | Shimmer states for chat list / chat view / settings | `loading-skeletons.jsx` | везде |
| **29** | Schedule send (опц.) | Post-MVP per spec §15.1 — собираем если время остаётся | `schedule-send.jsx` (~24 КБ) | WU 6 |
| **30** | Spec cards (internal) | `spec-icons.jsx`, `spec-buttons.jsx` — для design system docs | — | — |

Финиш Phase 1 — после WU 28. WU 29-30 опциональны.

---

## Что НЕ строим в Phase 1

- **Активные взаимодействия с сервером** (нужен Rust Core)
- **Локальное хранилище** (нужен `sinhron_storage`)
- **Реальная криптография** (нужен `sinhron_crypto`)
- **Push notifications** (нужен `sinhron_net` + native iOS/Android handlers)
- **Реальные звонки** (нужен LiveKit + SFrame integration через `sinhron_call`)
- **Локализация** (только en пока; ARB добавим в Phase 1.5)

---

## Сколько это займёт примерно

Грубая оценка по типам задач:
- **Атом (Ds-виджет с golden-тестом)** — ~2 часа на штуку
- **Простой экран (lockscreen, perm-denied, states)** — ~3-4 часа
- **Средний экран (settings, contact-info, compose)** — ~6-8 часов
- **Сложный экран (entry, chat-view, groups, calls, group-calls)** — ~12-16 часов

Итого 30 WU × среднее ~6 часов = **~180 часов = 4-6 недель** active full-time. С учётом разговоров, ревью, refactoring — **6-10 недель**.

Если что-то можно срезать — кандидаты на отмену из 1.0: schedule-send (WU 29), spec cards (WU 30), search (WU 26), invite-link (WU 27 — нужен только если invite-by-URL включён в MVP).

---

## Когда переключаемся на Phase 2 (Rust Core)

Триггеры:
- ✅ Все must-have screens из design-handoff-index.md в статусе `done`
- ✅ Каждый Ds-виджет имеет golden-тест (§15.3)
- ✅ Навигация work end-to-end на iOS Simulator (тапнул на чат → открылся chat view → вернулся → открыл settings → залогаутился → entry)
- ✅ `flutter analyze` зелёный, `flutter test` зелёный

Тогда — Phase 2 начинается с scaffolding'а `core/` (см. ADR-005).

---

## После compact'а — где смотреть

- **Что построено сейчас:** [`status.md`](status.md)
- **Что было решено:** [`decisions.md`](decisions.md)
- **Какой следующий экран:** [`design-handoff-index.md`](design-handoff-index.md) (статус `pending` с наименьшим WU №)
- **Сам дизайн:** `../design_handoff_sinhron/design/index.html` (открыть в Chrome) или `../design_handoff_sinhron/design/app/<имя>.jsx`
- **Спека:** `../design_handoff_sinhron/spec/architecture.md` — особенно §8 (Flutter-клиент) и §6 (крипто, нужно для onboarding и trust surfaces)
