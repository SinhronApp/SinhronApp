// Localisation access — UI backlog §7 item 53.
//
// Strings live in lib/l10n/app_en.arb (template) and app_ru.arb; Flutter
// generates `AppL10n` (lib/l10n/gen). Use `context.l10n.someKey`.
// Without a Localizations ancestor (widget tests, previews) the app's own
// language is used ([currentLanguage], English until the app sets it), so
// screens never crash for lack of setup — and never fall back to English
// in a Russian app (owner, 2026-10-19: call screen labels in English).

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers/settings_providers.dart';
import 'gen/app_l10n.dart';

export 'gen/app_l10n.dart';

extension L10nContext on BuildContext {
  AppL10n get l10n => Localizations.of<AppL10n>(this, AppL10n) ?? lookupAppL10n(Locale(currentLanguage));
}

/// Settings → Language: 'system' | 'en' | 'ru'.
final languageProvider = AsyncNotifierProvider<StringSetting, String>(() => StringSetting('language', 'system'));

/// The locale to force, or null to follow the phone.
Locale? chosenLocale(String? setting) => switch (setting) {
      'en' => const Locale('en'),
      'ru' => const Locale('ru'),
      _ => null,
    };

/// Phone language → ours: Russian for ru (and the closest neighbours
/// people often run their phones in), English otherwise.
Locale resolveLocale(List<Locale>? device) {
  for (final l in device ?? const <Locale>[]) {
    if (const {'ru', 'uk', 'be', 'kk'}.contains(l.languageCode)) return const Locale('ru');
    if (l.languageCode == 'en') return const Locale('en');
  }
  return const Locale('en');
}

/// Language of non-widget code (date labels in providers). Kept in step
/// with the app's locale by the root widget.
String currentLanguage = 'en';
