# Sinhron · Design Handoff for Claude Code

> Self-hosted, end-to-end encrypted messenger. Flutter UI on five platforms,
> Rust Core handling crypto / storage / transport via flutter_rust_bridge.
> This bundle is the **UI surface** that sits on top of that architecture.

---

## TL;DR for Claude Code

You have three things in this package:

1. **`spec/architecture.md`** — the canonical 837-line technical specification.
   Library versions, crate names, MLS shape, server topology, threat model.
   **When the design and the spec disagree, the spec wins.**
2. **`design/`** — a single-file HTML design canvas (`index.html`) showing
   **74 screens across 31 sections**, plus every component file as plain
   React JSX. These are **design references**, not production code. Read
   them for layout / spacing / copy / tokens / states. **Do not lift the
   JSX directly into Flutter.** Re-implement each screen as Flutter widgets
   that consume View-Models from the Rust Core.
3. **This README** — orientation: how to read the canvas, what every
   section maps to in the spec, what the tokens are, and the open
   decisions that need your call.

Start by opening `design/index.html` in any browser. Pan and zoom the
canvas; every section has a subtitle explaining the design intent. Then
work through `spec/architecture.md` end-to-end. **Do not start coding
until both are read.**

---

## Fidelity

**High-fidelity.** Every screen has final colours, typography, spacing,
copy, and state treatment. Counts, percentages, contact names, and
timestamps in the mocks are placeholder data — the visual treatment of
each surface is final.

The fidelity is "what the user sees", not "how it's wired". The Flutter
layer is responsible for translating View-Models from the Rust Core into
these widgets. No mock data flows from the design files into production.

---

## What this bundle is **not**

- Not a Flutter project. The JSX files are React, written purely to make
  the canvas legible to a designer. They are a *visual specification*,
  not a starter codebase.
- Not a substitute for the spec. The spec has decisions the design
  cannot encode: exact crate versions, threat model, retention policy,
  MLS ciphersuite, deployment topology. Read it.
- Not interactive prototypes. Tap / scroll behaviour is implied by the
  static composition; specific transition curves are noted per-section
  below where they matter.

---

## Architecture mapping

The design implements the surfaces required by the architecture in
`spec/architecture.md`. Per the spec:

- **UI layer:** Flutter 3.41.5 / Dart 3.11. Custom design system on top
  of `material.dart` primitives only. Riverpod 3.0 for state. go_router
  17.1.0 for nav. Spec §8.
- **Core layer:** Rust crate workspace (`sinhron_core`, `sinhron_crypto`,
  `sinhron_storage`, `sinhron_net`, `sinhron_sync`, `sinhron_call`),
  linked into Flutter via `flutter_rust_bridge 2.11.1`. Spec §5.
- **Crypto:** OpenMLS 0.8.1 + SFrame (RFC 9605) for call media. Spec §6.
- **Backend:** Rust + Axum 0.8.9 + Tokio 1.47.3 LTS + sqlx 0.8.6 +
  PostgreSQL 16+. Spec §7.

Critically: **plaintext does not enter the Dart heap for long-lived
storage**. Per spec §5.6, Dart receives View-Models that contain only
what's needed to render *this frame*. Every screen below must be
implemented as a thin renderer over those View-Models. Composer drafts,
search indices, cached media bytes — all of that lives in the Rust
Core, never persisted on the Dart side.

---

## Design tokens

All tokens are defined in `design/app/tokens.css` as CSS custom
properties. Mirror them into `lib/app/theme/tokens.dart` exactly.

### Color · Light

```
--sn-bg:              #FAF9F6      // chrome background
--sn-bg-soft:         #F1EFEA      // subtle wash (filter pills, input pill bg)
--sn-surface:         #FEFCF8      // cards, bubbles (incoming)
--sn-elevated:        #FFFFFF      // modals, sheets

--sn-divider:         rgba(15, 23, 32, 0.06)
--sn-divider-strong:  rgba(15, 23, 32, 0.10)

--sn-text:            #0E141B      // primary
--sn-text-2:          #4A5562      // secondary
--sn-text-3:          #8A96A4      // tertiary / metadata
--sn-text-4:          #B4BDC9      // disabled

--sn-accent:          #2D6FF7      // single brand accent (cold blue)
--sn-accent-soft:     #E6EFFE      // accent tint surface
--sn-accent-text:     #FFFFFF

--sn-success:         #1FAF6E      // online dot, "Verified" affordances
```

### Color · Dark

```
--sn-bg:              #0B1016
--sn-bg-soft:         #0F151D
--sn-surface:         #141B25
--sn-elevated:        #1A222D

--sn-divider:         rgba(255, 255, 255, 0.06)
--sn-divider-strong:  rgba(255, 255, 255, 0.10)

--sn-text:            #ECEEF1
--sn-text-2:          #A6AFBD
--sn-text-3:          #6E7889
--sn-text-4:          #4A5365

--sn-accent:          #4F8AFF
--sn-accent-soft:     rgba(79, 138, 255, 0.16)

--sn-success:         #2BC58A
```

### Semantic non-token colours (used inline, fixed both themes)

```
Danger:              #FF4D4D / pressed #E03B3B
Warn (amber):        rgba(217,119,6,0.14) bg · #C2410C text
Hand raised (amber): #FFB800 / rgba(255,184,0,0.14) bg
```

### Radii

```
--sn-radius-card:     18px         // cards, sheets
--sn-radius-pill:     999px        // pills, badges
--sn-radius-bubble:   14px         // bubbles (with tail-corner 6px on 1 side)

Settings rows:        14px outer card · 0 inner (rows are inset siblings)
Buttons:              14px (50h pill default)
Modal sheets:         22px top corners only
```

### Shadows

```
--sn-shadow-row:    0 1px 0 rgba(15,23,32,0.04)
--sn-shadow-soft:   0 1px 2px rgba(15,23,32,0.04), 0 8px 24px rgba(15,23,32,0.06)
--sn-shadow-fab:    0 6px 16px rgba(45,111,247,0.30), 0 2px 4px rgba(45,111,247,0.18)
```

### Avatar gradient seeds

10 palettes, hashed by display-name (see `app/chat-list.jsx` →
`SN_AVATAR_PALETTES`). The same seed must produce the same colours
across all platforms — use a deterministic hash (FNV-1a or simple
`charCode * 31` accumulator, matching the JSX) so cross-device parity
holds.

---

## Typography

**Family:** Geist (sans) + Geist Mono (mono for technical strings:
fingerprints, IDs, tokens, paths).

| Role          | Size · weight | Tracking |
|---------------|---------------|----------|
| Display       | 32 / 600      | -0.8     |
| Title         | 22 / 600      | -0.4     |
| Header        | 17 / 600      | -0.3     |
| Row name      | 16 / 600      | -0.2     |
| Body          | 15 / 400      | -0.15    |
| Meta          | 12 / 500      | -0.1     |
| Mono caption  | 13 / 500 mono | 0        |
| Eyebrow       | 11 / 700 caps | 0.6      |

`font-feature-settings: 'ss01' on, 'cv11' on;` is on globally for
Geist. Preserve it in the Flutter `TextTheme`.

---

## Iconography

The icon set is at `design/app/spec-icons.jsx` and the canvas section
"Design system → Icon set · 75 glyphs". **75 glyphs** organised in 7
groups (Navigation · Chat actions · Composer & media · Calls · Status
& receipts · Identity & security · Profile & people). All 24×24
viewBox, 1.8px stroke, `currentColor`. Filled glyphs (send, pin, pinned,
play, missed-call, decline, accept) reinforce action; outlined glyphs
sit quietly inside chrome.

When implementing in Flutter, treat these as a custom icon font or as
inline `SvgPicture.string` constants — do **not** pull in
material_icons. The visual vocabulary must remain Sinhron-distinct.

---

## Component library

Re-implement these as Dart classes (`DsButton`, `DsTextField`,
`DsAvatar`, etc.) under `lib/widgets/`. Reference sources noted.

| Widget          | Source file                          | Notes |
|-----------------|--------------------------------------|-------|
| DsButton        | `app/entry.jsx` (line 38)            | 4 variants × 4 states; full matrix at `app/spec-buttons.jsx` |
| DsTextField     | `app/entry.jsx`                      | Soft-fill surface, no Material outline; mono-variant for tokens |
| DsCheck         | `app/entry.jsx`                      | Soft 22h squircle |
| DsMnemonicGrid  | `app/entry.jsx`                      | 24-word BIP-39 grid · blur-until-tap |
| SnAvatar        | `app/chat-list.jsx`                  | Gradient-seeded by name · group / online / ring variants |
| SnChatRow       | `app/chat-list.jsx`                  | One row of the chat list — see "Row anatomy" in canvas |
| SnTabBar        | `app/chat-list.jsx`                  | Bottom tab bar (Chats / Calls / Settings) |
| Bubble          | `app/chat-view.jsx`                  | All side / tail / reply / reactions logic |
| VoiceContent    | `app/chat-view.jsx`                  | Waveform from amplitude array (50–100 pts per spec §11.2) |
| PhotoContent    | `app/chat-view.jsx`                  | BlurHash placeholder + decrypted bytes |
| Composer        | `app/chat-view.jsx`                  | Plain composer; richer variants in `composer-pack.jsx` |
| CallBtn         | `app/calls.jsx`                      | Round in-call button · 4 kinds (default/active/danger/accept) |
| ParticipantTile | `app/group-calls.jsx`                | Used in 2×2, 3×3, spotlight grids |
| CountdownChip   | `app/disappearing-active.jsx`        | SVG ring · pct = remaining/TTL |
| DocBubble       | `app/document-bubble.jsx`            | Typed file bubble · 4 states |

---

## Sections in the canvas, mapped to spec

Each section is one `<DCSection>` in `design/index.html` and one or
more `.jsx` files under `design/app/`. Sections in **bold** are
must-have for the v1.0 cut.

| Canvas section                         | Spec §§           | Files |
|----------------------------------------|-------------------|-------|
| **Onboarding & return**                | §6.1, §6.2, §6.8  | `app/entry.jsx` |
| **Compose & add contact**              | §6.1              | `app/compose.jsx` |
| **Groups**                             | §6.3              | `app/groups.jsx` |
| **Calls** (1:1)                        | §10               | `app/calls.jsx` |
| **Group calls** (2×2 / 3×3 / spotlight)| §10.5             | `app/group-calls.jsx` |
| Loading skeletons                      | §8.5, §9.4        | `app/loading-skeletons.jsx` |
| Schedule send                          | (post-MVP)        | `app/schedule-send.jsx` |
| **Notification preview · lock screen** | §9.3              | `app/lockscreen.jsx` |
| **Self-hosted server**                 | §7.1, §7.6, §12   | `app/server-detail.jsx` |
| **Active call · in-app**               | §10               | `app/active-call-bar.jsx` |
| **In-chat system messages**            | §6.3, §6.5        | `app/chat-events.jsx` |
| **Message request**                    | §6.5 (sealed sender) | `app/message-request.jsx` |
| **Disappearing messages · active**     | §6.6              | `app/disappearing-active.jsx` |
| **Storage & data**                     | §6.7, §11.3       | `app/storage-data.jsx` |
| **Account & device deletion**          | §6.2, §6.3        | `app/account-delete.jsx` |
| **No internet / server unreachable**   | §9.1, §9.4        | `app/no-internet.jsx` |
| Documents in chat                      | §6.9, §11         | `app/document-bubble.jsx` |
| **First-launch splash**                | §3                | `app/onboarding-splash.jsx` |
| **Accept invite link**                 | §6.1              | `app/invite-link.jsx` |
| **Linked devices · manage**            | §6.2              | `app/devices-manage.jsx` |
| Call participants · host actions       | §10               | `app/call-participants.jsx` |
| **Push permission denied**             | §9.3              | `app/perm-denied.jsx` |
| **Safety number**                      | §6.4              | `app/verify.jsx` |
| **Settings · sub-screens**             | §6.7, §8          | `app/settings-detail.jsx` |
| Message actions                        | §8.5              | `app/message-actions.jsx` |
| **Media**                              | §6.9, §11         | `app/media.jsx` |
| Search                                 | §8.5              | `app/search.jsx` |
| States (archived/blocked/reconnect)    | §9.1, §9.4        | `app/states.jsx` |
| Composer pack (reply/mention/stickers) | —                 | `app/composer-pack.jsx` |
| Chat completion (selection/pin/errors) | §9.1              | `app/chat-completion.jsx` |
| Trust polish (perm prompts, identity)  | §6.5, §9.3        | `app/trust-polish.jsx` |
| **Main · Chat list**                   | §8                | `app/chat-list.jsx` |
| **Conversation · 1:1 chat**            | §8                | `app/chat-view.jsx` |
| **Settings (root)**                    | §6.7, §8          | `app/settings.jsx` |
| **Contact info**                       | §6.4              | `app/contact-info.jsx` |
| Design system spec cards               | —                 | `app/spec-icons.jsx`, `app/spec-buttons.jsx` |

---

## Cross-cutting rules

These are decisions that hold across the whole product. Re-read each
before touching any screen.

### 1. E2EE is invisible by default

Per spec §3 and reinforced through every screen: there are **no lock
icons** in chrome, **no "encrypted" badges** on bubbles, **no padlock**
in the composer. A civilian who never opens Settings or Contact info
must feel they're using a premium chat app, not a security tool. The
single places where E2EE is allowed to be visible:

- **Safety number screen** (Verify) — a deliberate ritual.
- **Identity-changed warning** (`trust-polish.jsx`) — the rare but
  critical post-compromise event.
- **In-chat "safety number changed" pill** (`chat-events.jsx`) — a
  warn-toned event line.
- **System messages about epoch rotation** — `"Group keys refreshed ·
  epoch 248"` — extremely dim, marked as routine maintenance.
- **Lock-screen notification "hide previews"** mode — see §9.3.

Anywhere else: encryption is implied, never named.

### 2. No identity except identity-key

No email field, no phone field, no password field, no social-login
button. Anywhere. **Anywhere.** Sign-in / sign-up flows are:
(a) generate keys + show recovery phrase, or (b) link-from-existing-
device via QR, or (c) restore-from-recovery-phrase. See spec §6.1.

### 3. Server is one, not many; not federated

The product has no federation, no "find my friend on another server",
no per-chat server choice. Every user is bound to exactly one server
URL at a time. The "Change server" flow is destructive (see
`server-detail.jsx`).

### 4. Sender colours in group chats

Sender names in group bubbles are coloured with a hash of the display
name into a 10-palette (`EV_SENDER_COLORS` in `chat-events.jsx`). The
same display name must always produce the same colour across all
devices. Use the same hash function as the avatar palette.

### 5. Plaintext stays in RAM

Per spec §5.6 and §8.6: **never persist plaintext on disk in the Dart
layer**. The image cache, search index, draft store, transcript cache
— all of those live in the Rust Core's encrypted SQLite. Dart receives
decrypted bytes lazily and drops them when the widget unmounts. Build
the View-Model boundary accordingly.

### 6. Push payload is opaque

Push notifications carry only `{chat_id_opaque, message_uuid}`. The
plaintext preview you see in the "Show previews" lock-screen design
is built **on the device** after the push wakes the app, the WS
pulls the ciphertext, and the Core decrypts it. See spec §9.3.

### 7. Animation defaults

- Sheet present:  220ms · ease-out (cubic 0.2, 0.8, 0.2, 1)
- Sheet dismiss:  180ms · ease-in
- Bubble enter:   180ms · ease-out · 4px translate
- Long-press:     120ms haptic-tap · scale 0.97 · blur(14px) backdrop
- Skeleton sweep: 1.6s · ease-in-out · infinite
- Reconnect spin: 0.9s · linear · infinite
- Disappear-ring tick: 1s · linear (countdown)

Where the design has no specific animation, default to `flutter_animate`
defaults at half-strength.

---

## Open decisions / caveats

These need a product call. Where the design picked one path, that
path is annotated; switch freely.

1. **Schedule send (canvas section "Schedule send")** is post-MVP per
   spec §15.1; included in the canvas because the user asked for it
   as table-stakes. If cutting for v1.0, drop `schedule-send.jsx` from
   the build; the rest of the system has no other reference to it.
2. **Active call mini-bar** assumes the Flutter `livekit_client` is
   the on-call path (spec §10.6). The keys flow Core → KeyProvider →
   livekit_client, and the bar reads its presence + state from a
   Riverpod provider over a Core stream.
3. **Devices · stale state** (`devices-manage.jsx` shows "2 weeks
   ago" Pixel as stale). The threshold for "stale" is a product call:
   the design picked 14 days. Spec §6.6 has 7-day Update cadence; if
   strict, you might want 14d or 30d here.
4. **Mono fingerprints** are shown abbreviated (`9a3e…ec22`). Full
   60-digit safety number lives only in the Verify screen. Don't
   render the full number anywhere else.
5. **Storage budget** in `storage-data.jsx` is hardcoded 2 GB. Per
   spec §8.6 the LRU cap is configurable; the design exposes one
   slot, expand if needed.

---

## File layout in this bundle

```
design_handoff_sinhron/
├── README.md                 ← this file
├── spec/
│   └── architecture.md       ← canonical 837-line spec; ALWAYS WINS over design
└── design/
    ├── index.html            ← open in browser; pan/zoom the canvas
    └── app/
        ├── tokens.css        ← design tokens; mirror exactly into Flutter
        ├── chat-list.jsx     ← main screen; defines SnAvatar, SnChatRow, SnTabBar
        ├── chat-view.jsx     ← 1:1 chat; defines Bubble, Composer
        ├── entry.jsx         ← onboarding; defines DsButton, DsTextField
        ├── … 22 more .jsx files, one per canvas section …
        ├── spec-icons.jsx    ← 75-glyph icon set with labels
        ├── spec-buttons.jsx  ← 4×4 button-state matrix
        └── starters/         ← iOS/Android frame components (ignore in Flutter)
```

---

## Build order suggestion

The spec defines phases (§17). For the UI specifically, this ordering
keeps the foundations correct so later screens compose without rework:

1. **Tokens + theme** → mirror `tokens.css` into `lib/app/theme/`.
2. **DsButton, DsTextField, DsCheck, SnAvatar** → atoms used everywhere.
3. **Chat list shell** (`chat-list.jsx`) → header, filter pills, row,
   tab bar, FAB. Wire to a fake Riverpod provider; switch to real
   Core stream later.
4. **Onboarding & first-launch splash** → first paint of the app.
5. **1:1 chat** → bubbles, composer, day separators.
6. **Settings root + sub-screens** → Server, Linked devices, Recovery,
   App lock, Privacy.
7. **Groups, then group chat** → reuse bubble system with sender colours.
8. **Calls** (incoming → audio → video → ended → active-bar).
9. **Group calls** (2×2, 3×3, spotlight, participants modal).
10. **Trust surfaces** — Safety number, Identity changed, Message request.
11. **States** — offline, reconnecting, archived, blocked, disappearing.
12. **Polish** — schedule send (if in v1.0 scope), search, media viewer,
    documents.

---

## Questions

If a screen seems wrong or under-specified for the spec's architecture,
flag it back rather than guessing. The design and the spec were written
in close lockstep but a few edge cases were resolved in one and not the
other. **Trust the spec; surface design gaps to the architect.**

— *Generated from the design canvas at `cabin.sinhron.app` — Sinhron v1.0 design exploration*
