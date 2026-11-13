# docs/ — путеводитель

Документация Sinhron'а. **Источник правды** который переживает context resets.

---

## 🎯 Главный entry point

**Если ты только что открыл репо** — читай **[`PROJECT.md`](PROJECT.md)** первым.

Это canonical entry point с навигацией по всему остальному, текущее состояние, что есть/чего нет.

---

## 📚 Полный список документов

### Главные (read first)

| Файл | Когда читать |
|---|---|
| **[`PROJECT.md`](PROJECT.md)** | **Всегда первым.** Карта проекта + текущее состояние + навигация. ~10 мин. |
| **[`status.md`](status.md)** | Хронология что/когда сделано. Последняя секция = недавние изменения. Полное чтение долго, можно пропускать середину. |
| **[`onboarding.md`](onboarding.md)** | Как от чистого `git clone` до "вижу как Alice пишет Bob'у". ~30 мин. |

### Глубокие справочники

| Файл | Когда читать |
|---|---|
| **[`architecture.md`](architecture.md)** | Полная архитектура: компоненты, data flow, sequence diagrams. ~20 мин. |
| **[`code-map.md`](code-map.md)** | Карта файлов: для каждого .rs/.dart что он делает. Lookup-style, не последовательное чтение. |
| **[`tech-debt.md`](tech-debt.md)** | Все костыли, TODO, deferred, known issues с серьёзностью + локацией + how-to-fix. |
| **[`glossary.md`](glossary.md)** | Терминология (MLS, SFrame, KP, frb, HKDF, …). Если непонятен термин — здесь. |
| **[`threat-model.md`](threat-model.md)** | Security: attacker capabilities, mitigations, invariants. ~15 мин. |
| **[`decisions.md`](decisions.md)** | ADR-001 … ADR-015 (включая ADR-015 LiveKit + SFrame). Почему именно так. Lookup-style. |

### Operations

| Файл | Когда читать |
|---|---|
| **[`deploy-guide.md`](deploy-guide.md)** | Step-by-step production deploy (VM → Docker → TLS → backup). ~500 LOC. |

### Планирование (исторические + active)

| Файл | Когда читать |
|---|---|
| [`plan-calls.md`](plan-calls.md) | **ЗАКРЫТ функционально (2026-05-23)** — план реализации 1:1 audio+video calls (спек-Фаза 7). Все Stages A-F ✅. Единственный блок = PushKit (требует Apple Dev cert). Group calls (≥3 leafs) — deferred. |
| [`evidence/calls-manual-test-plan.md`](evidence/calls-manual-test-plan.md) | 12 baseline + 5 edge сценариев 2-device manual testing для Phase 3 calls. |
| [`goal-backend.md`](goal-backend.md) | Persistent goal file для backend ladder. История + WU ladder Stage A→F. |
| [`plan-phase1-frontend.md`](plan-phase1-frontend.md) | План Phase 1 (закрытой). |
| [`design-handoff-index.md`](design-handoff-index.md) | Связь дизайна (JSX) ↔ Flutter screens. |
| [`overnight-plan.md`](overnight-plan.md) | План последней автономной ночной сессии. |
| [`overnight-log.md`](overnight-log.md) | Детальный лог последней ночной сессии. **Свежий контекст после ночи!** |

### Артефакты

| Файл | Когда читать |
|---|---|
| `evidence/` | Скриншоты / артефакты для verification (история). |

---

## 🧭 Quick navigation по сценарию

### "Я Claude, контекст сбросило, что читать?"

1. `PROJECT.md` (~10 мин)
2. `status.md` § "Текущая фаза" + последняя секционная запись (~5 мин)
3. `overnight-log.md` если ночная автономка была недавно (~5 мин)
4. По задаче (см. `/goal` input):
   - Architecture work → `architecture.md` + `code-map.md`
   - Bug fixing → `tech-debt.md` + grep TODO в коде
   - Security review → `threat-model.md` + `decisions.md` ADRs 003, 011, 012, 013
   - Performance → `code-map.md` § 5 (tests + examples) + benchmarks (TODO нет)
5. **НЕ** делать: git commit без явного запроса оператора, force/amend/no-verify, правки .env*

### "Я новый human contributor"

1. `PROJECT.md` (~10 мин)
2. `architecture.md` (~20 мин)
3. `onboarding.md` — `cargo run --example full_e2e` чтобы увидеть живой пример (~15 мин)
4. `code-map.md` когда захочешь конкретный файл найти (lookup)
5. `glossary.md` для незнакомых терминов (lookup)
6. `design_handoff_sinhron/spec/architecture.md` — спека, если интересует ПОЧЕМУ

### "Я оператор хочу deploy"

1. `PROJECT.md` § 4 "Tech stack pin" — что нужно
2. `deploy-guide.md` — step-by-step
3. `threat-model.md` § "Что НЕ покрывает" — что operator должен делать сам
4. `tech-debt.md` § 4 "DEFERRED items" — что отложено / требует твоего конфига

### "Я security reviewer"

1. `threat-model.md`
2. `decisions.md` ADRs (особенно 003 sealed sender, 011 SQLCipher, 012 state backup, 013 WAL, **015 LiveKit + SFrame для calls**)
3. `tech-debt.md` § 1 "CRITICAL items" + § 2 security-related items
4. `design_handoff_sinhron/spec/architecture.md` § 6 (crypto), § 13 (privacy)

---

## 📝 Что **НЕ** в `docs/`

| Где искать | Что |
|---|---|
| `../design_handoff_sinhron/spec/architecture.md` | **Спека** — 920 строк, эталон |
| `../design_handoff_sinhron/design/` | Дизайн mocks — 37 JSX, 74 экрана |
| `../client_flutter/lib/` | Flutter (Dart) код приложения |
| `../client_flutter/rust/` | Rust client workspace |
| `../server/` | Server workspace |
| `../scripts/` | (TBD) operator scripts |

---

## 🔄 Дисциплина обновления

→ **Единственный источник правды:** [`PROJECT.md` §9](PROJECT.md#9-дисциплина-обновления).

Эта секция намеренно не дублирует таблицу — чтобы при изменении правил не получился рассинхрон. Все правила (что → куда обновлять, FRB codegen, proto mirror, commit message format) живут там.

---

## 🆘 Если непонятно

- Поиск ключевого слова в коде: `rg 'keyword' --type rust --type dart`
- Поиск в docs: `rg 'keyword' docs/`
- Спросить владельца если совсем застрял

---

**Дата последнего обновления README:** 2026-05-23 после Phase 3 (Calls) ship + doc audit pass.
