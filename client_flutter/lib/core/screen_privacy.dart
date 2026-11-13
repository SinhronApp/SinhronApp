// Audit storage-devices:8 / :19 (docs/security-review-2026-11.md) — channel
// `dev.sinhron/privacy` (`MainActivity.kt`, `AppDelegate.swift`):
//   - `wordsShown {on}` — Android: FLAG_SECURE while the 24 words are on the
//     screen (no screenshot, recording, screen share or Recents picture of
//     them). iPhone can't block that: the words screen hides the words while
//     the screen is recorded or mirrored (`screenCaptured`, screenshot_watch.dart).
//   - `hideRecents {on}` — Android, App Lock with "Hide in app switcher": no
//     Recents picture of the app (Android 13+; older — FLAG_SECURE only while
//     the app is in the background). iPhone: the blur cover is enough.
//   - `copySecret {text, seconds}` — the words to the clipboard as a secret:
//     iPhone — this phone only (no Universal Clipboard to the Mac) and gone
//     after [seconds]; Android 13+ — hidden in the clipboard preview and
//     kept out of the keyboard's clipboard history.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('dev.sinhron/privacy');

/// The secret words to the clipboard (a plain copy where there's no channel).
Future<void> copySecret(String text, {int seconds = 60}) async {
  try {
    await _channel.invokeMethod<void>('copySecret', {'text': text, 'seconds': seconds});
    return;
  } on MissingPluginException {
    // Tests, desktop: no channel there.
  }
  await Clipboard.setData(ClipboardData(text: text));
}

/// Android: the 24 words are on the screen (true) / gone (false).
Future<void> secureWordsScreen(bool on) => _android('wordsShown', on);

/// Android: keep the app out of the Recents pictures.
Future<void> hideFromRecents(bool on) => _android('hideRecents', on);

Future<void> _android(String method, bool on) async {
  if (defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await _channel.invokeMethod<void>(method, {'on': on});
  } on MissingPluginException {
    // Tests: no channel there.
  }
}
