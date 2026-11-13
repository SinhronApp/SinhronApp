// Persisted app settings — UI backlog §1 item 8 ("nothing fake").
//
// Key/value rows in the SQLCipher DB (`settings` table, storage v5).
// Local-only profile metadata (display name, about) lives here too —
// spec §6.6: it never goes to the server.

import 'dart:convert';

import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api/simple.dart' as core;

abstract class SettingsStore {
  Future<String?> get(String key);
  Future<void> set(String key, String value);
}

class CoreSettingsStore implements SettingsStore {
  @override
  Future<String?> get(String key) => core.storageSettingGet(key: key);

  @override
  Future<void> set(String key, String value) => core.storageSettingSet(key: key, value: value);
}

/// Overridden with an in-memory store in tests.
final settingsStoreProvider = Provider<SettingsStore>((ref) => CoreSettingsStore());

/// A persisted string setting with a default.
class StringSetting extends AsyncNotifier<String> {
  StringSetting(this.key, this.fallback);
  final String key;
  final String fallback;

  @override
  Future<String> build() async {
    try {
      return await ref.read(settingsStoreProvider).get(key) ?? fallback;
    } catch (_) {
      // DB not open yet (pre-onboarding) — show the default.
      return fallback;
    }
  }

  Future<void> save(String value) async {
    await ref.read(settingsStoreProvider).set(key, value);
    state = AsyncData(value);
  }
}

/// A persisted on/off setting.
class BoolSetting extends AsyncNotifier<bool> {
  BoolSetting(this.key, this.fallback);
  final String key;
  final bool fallback;

  @override
  Future<bool> build() async {
    try {
      final v = await ref.read(settingsStoreProvider).get(key);
      return v == null ? fallback : v == '1';
    } catch (_) {
      return fallback;
    }
  }

  Future<void> save(bool value) async {
    await ref.read(settingsStoreProvider).set(key, value ? '1' : '0');
    state = AsyncData(value);
  }
}

/// Your display name, shown in the chat-list header and profile. Local
/// only — never sent to the server.
final profileNameProvider = AsyncNotifierProvider<StringSetting, String>(() => StringSetting('profile_name', ''));

/// My photo (tech-debt 2.21): base64 of the ≤32 KB JPEG Rust made from the
/// picked image; '' = none. Goes out with my name in `profile`.
final profileAvatarProvider = AsyncNotifierProvider<StringSetting, String>(() => StringSetting('profile_avatar', ''));

/// Privacy → Incoming calls (tech-debt 2.27). Off: invites are declined
/// without ringing.
final incomingCallsProvider = AsyncNotifierProvider<BoolSetting, bool>(() => BoolSetting('incoming_calls', true));

/// Personal chats whose other person is blocked here (comma-separated
/// chat ids) — a call invite only names the chat, not the caller.
final blockedChatsProvider = AsyncNotifierProvider<StringSetting, String>(() => StringSetting('blocked_chats', ''));

final profileAboutProvider = AsyncNotifierProvider<StringSetting, String>(() => StringSetting('profile_about', ''));

/// ADR-018 — sender-side link previews. Off by default.
final linkPreviewsEnabledProvider = AsyncNotifierProvider<BoolSetting, bool>(() => BoolSetting('link_previews', false));

/// SOCKS5 proxy (`host:port`, e.g. Tor via Orbot `127.0.0.1:9050`) for all
/// server traffic — hides the phone's IP from the server. Empty = direct.
final socksProxyProvider = AsyncNotifierProvider<StringSetting, String>(() => StringSetting('socks_proxy', ''));

/// Tech-debt 2.32 — days an unused local media copy is kept ("0" =
/// forever). Rust applies it each time the storage opens.
final mediaKeepDaysProvider = AsyncNotifierProvider<StringSetting, String>(() => StringSetting('media_keep_days', '0'));

/// Longest name I can give someone (as their own — `MAX_PROFILE_NAME_CHARS`).
const int kMaxContactNameChars = 64;

/// Owner, 2026-11-03 — "rename a contact only for myself, and get the
/// original back": identity key (hex, lower case) → the name I gave that
/// person. One JSON map under `contact_aliases`, on this device only —
/// nobody else ever sees it. `peerNamesProvider` puts it over their own name.
class ContactAliases extends AsyncNotifier<Map<String, String>> {
  static const _key = 'contact_aliases';

  @override
  Future<Map<String, String>> build() async {
    try {
      final m = jsonDecode(await ref.read(settingsStoreProvider).get(_key) ?? '{}');
      return {
        if (m is Map)
          for (final e in m.entries)
            if (e.value is String && (e.value as String).isNotEmpty) '${e.key}'.toLowerCase(): e.value as String,
      };
    } catch (_) {
      return const {}; // DB not open yet, or nothing stored
    }
  }

  /// My name for [peerId] — one line, trimmed, at most
  /// [kMaxContactNameChars]; empty clears it (their own name is back).
  Future<void> set(String peerId, String name) async {
    final line = name.replaceAll(RegExp(r'[\r\n\t\u2028\u2029]+'), ' ').trim();
    final clean = line.characters.take(kMaxContactNameChars).toString().trimRight();
    final next = {...state.value ?? await future};
    final key = peerId.toLowerCase();
    if (clean.isEmpty) {
      if (next.remove(key) == null) return;
    } else {
      if (next[key] == clean) return;
      next[key] = clean;
    }
    await ref.read(settingsStoreProvider).set(_key, jsonEncode(next));
    state = AsyncData(next);
  }
}

final contactAliasesProvider = AsyncNotifierProvider<ContactAliases, Map<String, String>>(ContactAliases.new);
