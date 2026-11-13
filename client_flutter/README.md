# Sinhron · Flutter client

Flutter client of the Sinhron messenger.

> **⚠️ Этот README описывает состояние Phase 1 (UI-only прототип) и частично устарел.**
> Актуальное состояние проекта — [`docs/PROJECT.md`](../docs/PROJECT.md).
> Что изменилось с момента написания: Rust Core (FFI/MLS/SFrame/storage) **подключён**,
> Riverpod 3.x **используется**, экранов **45** (не один), 1:1 audio+video звонки
> реализованы. Разделы «Stack» и «What's NOT in this prototype yet» ниже
> отражают это; «Directory layout» — нет.

Implements the chat list screen from `Downloads/sinhron/` (React prototype) using the custom `Ds*` widget set required by spec §8.5: no Material/Cupertino defaults anywhere in user-visible widgets.

## Stack

| What | Choice | Reason |
|---|---|---|
| Flutter SDK | **3.41.5** | Pinned in `.fvmrc` per spec §1 (`fvm use` to activate) |
| State mgmt | Riverpod 3.x | `Notifier`/`NotifierProvider` (§8.2). НЕ устаревший `StateNotifier`. |
| Routing | custom `lib/app/navigation.dart` | Caller-binding `WidgetBuilder` pattern + `CupertinoPageRoute`. go_router (§8.3) не заведён — см. ADR в `docs/decisions.md`. |
| Fonts | bundled Geist + GeistMono | OFL-1.1, in `assets/fonts/`. **No** `google_fonts` — runtime download violates §3.3 "no phone home" |
| Icons | custom `CustomPainter` | Zero external dep; avoids `flutter_svg`/`flutter_lints_icons` until §17.3 escalation |
| App root | `WidgetsApp` (not MaterialApp) | Pure §8.5 / §18.17 — no Material defaults bleeding through |

## Directory layout

```
client_flutter/
  lib/
    main.dart                          ⇐ entry: runApp(SinhronApp())
    app/
      app.dart                         ⇐ WidgetsApp + DsTheme + URL ?theme= override
      theme/
        tokens.dart                    ⇐ DsTokens.light/dark + DsType text styles
    features/
      chat_list/
        chat_list_screen.dart          ⇐ composes header + filters + list + tab bar
        chat_data.dart                 ⇐ ChatPreview model + 12 sample chats
    widgets/
      ds_icon.dart                     ⇐ 14 icon shapes via single CustomPainter
      ds_icon_button.dart              ⇐ tap-target wrapper + optional badge
      ds_avatar.dart                   ⇐ gradient circle + initials/group + online dot
      ds_header.dart                   ⇐ avatar + title + search/compose actions
      ds_filter_pill.dart              ⇐ DsFilterPill + DsFilters (horizontal scroll)
      ds_chat_row.dart                 ⇐ avatar + name/time + preview + trailing indicators
      ds_tab_bar.dart                  ⇐ 4-tab bottom nav with badge support
  assets/fonts/                        ⇐ Geist {Regular, Medium, SemiBold, Bold} + GeistMono {Regular, Medium}
  test/
    test_harness.dart                  ⇐ loadAppFonts() + wrapForGolden()
    widget_test.dart                   ⇐ DsAvatar/DsChatRow golden tests + DsTokens semantics
    goldens/                           ⇐ generated PNG goldens, checked into git
  android/ ios/ macos/ linux/ windows/ ⇐ flutter create scaffolding (web added on demand)
  pubspec.yaml                         ⇐ uses-material-design: false + Geist registration
```

## Running

```bash
# Activate the project-pinned Flutter
fvm use 3.41.5

# iOS Simulator (preferred — Apple Color Emoji renders correctly)
fvm flutter run -d "iPhone 16"        # or whichever simulator is installed

# macOS desktop (requires full Xcode)
fvm flutter run -d macos

# Web preview (verification only — web is §19 open question, not a target)
fvm flutter run -d chrome
# OR static build + serve:
fvm flutter build web
python3 ../.claude/serve_web.py       # serves build/web on http://127.0.0.1:8765
```

For headless CI screenshots, see `../.claude/cdp_screenshot.mjs` (drives a `--remote-debugging-port` Chrome via Node's built-in `WebSocket` and `Emulation.setDeviceMetricsOverride` to set a real iPhone viewport — bypasses Chrome's `--window-size` viewport bug).

## Testing

```bash
fvm flutter analyze                   # static analysis, must be clean
fvm flutter test                      # widget tests + golden comparison
fvm flutter test --update-goldens     # regenerate goldens after intentional UI changes
```

Golden snapshots use bundled Geist fonts (via `FontLoader` in `test_harness.dart`) so they render close to production glyphs. Emoji glyphs appear as `□` in test goldens because Flutter's test environment ships no color-emoji font; on a real iOS device Apple Color Emoji renders them correctly.

## Theme verification trick

`SinhronApp` reads `?theme=light|dark` from `Uri.base.queryParameters` and overrides the platform brightness. Useful for headless screenshots without resorting to OS-level appearance toggles. Production code paths will fall back to `MediaQuery.platformBrightnessOf(context)`.

## What's NOT in the client yet

Всё, что было в этом списке в Phase 1 (Rust Core + FFI, SQLCipher-персистенция,
WS-networking, остальные экраны, Riverpod), **уже реализовано**. Актуальный
список пробелов — [`docs/tech-debt.md`](../docs/tech-debt.md). Кратко:

- **Медиа в чате** (encrypted blobs, голос, фото, документы) — спек-Фаза 6, не начато
- **Group calls (≥3 leafs)** — спек-Фаза 8; 1:1 работает
- **PushKit VoIP** (incoming на lock-screen) — нужен Apple Developer cert
- **Multi-device pairing** (QR, leaf-per-device) — §6.5, ~40%
- **go_router** — так и не заведён; навигация своя (см. таблицу Stack выше)

See spec §16 roadmap.
