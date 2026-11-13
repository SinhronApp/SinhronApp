# MANDATORY: this repository is PUBLIC (owner, 2026-11-13)
Everything here — code, comments, docs, the `docs/status.md` log, commit messages — is visible to anyone.
Never write personal data: names or relatives of real people, e-mail addresses, phone numbers, who uses which phone,
home paths, server passwords / keys / tokens, outputs of commands from the live server. Say "a user", "one phone",
"the server". Secrets live only in GitHub → Settings → Secrets and on the server, never in files.
Release builds: GitHub → Actions → **Release** (`.github/workflows/release.yml`) — no Mac needed.

# MANDATORY: KISS — keep it simple (permanent rule from the owner, 2026-10-26)
Sinhron is a messenger for the owner, his family and friends — not a platform. The simplest thing that does the job wins.
1. **Build only what the owner asked for.** No features, settings, screens or abstractions "for later". An idea of your own →
   one line to the owner, not code.
2. **Fix and simplify before adding.** Messages, calls, devices and backup working reliably come before anything new.
3. **Less code is better.** Reuse what exists; prefer deleting code to adding it; no new protocol, table, crypto or framework
   where an existing one does the job.
4. **Big change → ask first, with the simpler option.** A new screen, table, server route, wire format, or more than ~300
   lines: say in plain words what it costs and what the simpler variant is, then wait for the owner.
5. **Plain words to the owner**, short — what changed, what to check, what he must do.

# MANDATORY: icons, never emoji, in the interface (permanent rule from the owner, 2026-11-03)
Interface marks — status, play, mute, timers, checks, list previews, buttons — are icons (`CupertinoIcons` or the app's
own `DsIcon` / painters), never emoji or Unicode symbols (`▶`, `🔇`, `⏱`, `✓`, `👤`…). Emoji only where the person
writes or picks them: messages, reactions, the emoji / sticker pickers.

# MANDATORY: docs + log on every change (permanent rule from the owner)
Every change — code, config, infra, deps, scripts — must, **in the same commit**:
1. **Update all affected docs.** Grep `docs/`, `CLAUDE.md`, READMEs for the identifiers you touched and fix stale text:
   `docs/tech-debt.md` (move fixed items to §5 CLOSED with date), `docs/threat-model.md`, `docs/PROJECT.md`
   (§2.5 status table, §3 lists), `docs/architecture.md`, `docs/code-map.md`, `docs/glossary.md`.
2. **Log the work** as a new dated entry at the top of `docs/status.md`: what changed and why, files touched,
   tests run with results, what is left / known caveats.
No change is done until both are in the commit. Never "docs later".
3. **Keep `docs/open-items.md` current** (owner, 2026-10-16): what waits for the owner's decision, what to check on a phone,
   what is in progress — short. Ask the owner one question at a time; "что висит?" → reply with that list.

# MANDATORY: a new version for every update (permanent rule from the owner, 2026-10-16)
Every build the owner installs (TestFlight, APK) carries a **new version**, so it's clear which update is on the phone:
1. Before building, raise `version:` in `client_flutter/pubspec.yaml` **and** `kAppVersion` in
   `client_flutter/lib/features/settings/settings_screen.dart` (`test/core/app_version_test.dart` keeps them equal):
   fixes → patch (0.2.0 → 0.2.1), new features → minor (0.2.x → 0.3.0). Commit the bump with the build.
2. Build only with `scripts/testflight.sh` / `scripts/android_release.sh` — normally through GitHub → Actions → Release, which
   runs them: they set the build number (UTC time) and pass it to the app — Settings → About shows "0.2.0 (202610160530)".
3. Name "version (build)" in the `docs/status.md` entry and in the report to the owner.

# graphify
- **graphify** (`.claude/skills/graphify/SKILL.md`) - any input to knowledge graph. Trigger: `/graphify`
When the user types `/graphify`, use the installed graphify skill or instructions before doing anything else.
The public repository starts without `graphify-out/`: the first session builds it once (`/graphify .`); after that use
`/graphify query "<question>"` or `/graphify . --update` instead of a full rebuild.
Start every codebase question with a graph query, then verify against the source it points to.
**MANDATORY (permanent rule from the owner, 2026-10-13): update the graph after every piece of work** —
run `/graphify . --update` before reporting a task done, in the same session as the change (code is free via AST;
changed docs cost LLM tokens). A task is not done while the graph is stale — same as docs + status log above.
`.graphifyignore` keeps images, golden screenshots and Flutter platform scaffolding out of the graph — keep it that way.

# Testing
Cloud sessions run `.claude/cloud_setup.sh` on start (SessionStart hook): installs protoc + Flutter 3.41.5,
starts PostgreSQL 16 and exports `DATABASE_URL`/`SINHRON_DB_URL`. Setup log: `/tmp/cloud_setup.log`.
- Server: `cd server && cargo test` (DB tests: `cargo test -- --include-ignored`)
- Installer: `bash server/scripts/install_test.sh` (bash 4+; macOS ships 3.2) and `shellcheck -s bash -e SC1091 server/install.sh server/scripts/install_test.sh` — CI also does a real `--dry-run` on Ubuntu 22.04/24.04.
- Release scripts: `bash server/scripts/release_test.sh` — tests for `release_preflight.sh` / `release_postcheck.sh` / `release_rollback.sh`.
- Client Rust: `cd client_flutter/rust && cargo test --workspace --no-fail-fast` (plain `cargo test` there runs only the root FFI crate — 3 tests instead of 142; without `--no-fail-fast` the run stops at the first failing network tests and the remaining suites don't run)
- Flutter: `cd client_flutter && flutter test` — golden pixel comparison is skipped off macOS automatically (`test/flutter_test_config.dart`; snapshots are recorded on the Mac). `flutter analyze lib test integration_test` (not the whole tree: `rust_builder/cargokit` is vendored tooling).
- CI (`.github/workflows/ci.yml`) runs all of the above plus the FFI drift check and a server-image job (`docker-image`: builds the image, `compose up --wait` postgres + sinhron-server — fails unless healthy) on every push. Enable the local pre-commit hook once per clone: `git config core.hooksPath .githooks`.
- iOS: release builds on GitHub (Actions → Release, macos-26); simulator only on the Mac.

On the Mac (shared with another person): never open windows — no iOS Simulator, `flutter run`, browser preview,
or Docker Desktop launch. Bind servers to 127.0.0.1 (avoids firewall prompt). Run heavy builds with `nice -n 19`.
