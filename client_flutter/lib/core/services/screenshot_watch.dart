// Screenshot alerts — ADR-030.
//
// iOS reports a screenshot after it is taken (it can't be blocked). The
// `screen_protector` plugin forwards `userDidTakeScreenshotNotification`;
// when one lands while a chat with disappearing messages is open, that chat
// gets a line for everyone (MessageActions.screenshotTaken). Android 14+
// (ADR-040): the system's screen-capture callback, through channel
// `dev.sinhron/screenshot` (`MainActivity.kt`); older Android can't tell.
// Nothing on other platforms, nothing for chats without a timer.
//
// Screen recording (and mirroring — iOS can't tell them apart): while the
// screen is captured, each disappearing chat that is open says so once per
// recording — also a chat opened after the recording began.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_protector/screen_protector.dart';

import '../providers/chat_actions.dart';
import '../providers/message_actions.dart';

/// iPhone: the screen is being recorded or mirrored right now (audit
/// storage-devices:8 — the words screen hides the 24 words meanwhile).
final screenCaptured = ValueNotifier<bool>(false);

/// Starts listening: calls back on every screenshot and whenever screen
/// capture starts or stops (faked in tests).
typedef ScreenshotSource = void Function(void Function() onScreenshot, void Function(bool recording) onRecording);

final screenshotSourceProvider = Provider<ScreenshotSource>(
  (ref) => (onScreenshot, onRecording) {
    if (Platform.isAndroid) {
      const MethodChannel('dev.sinhron/screenshot').setMethodCallHandler((call) async {
        if (call.method == 'shot') onScreenshot();
        return null;
      });
      return;
    }
    if (!Platform.isIOS) return;
    ScreenProtector.addListener(onScreenshot, onRecording);
    // Already recording when the app starts: no change event comes.
    unawaited(
      ScreenProtector.isRecording().then((on) {
        if (on) onRecording(true);
      }, onError: (Object _) {}),
    );
  },
);

/// Read once at the app root: wires screenshots and recordings to the
/// open chat.
final screenshotWatchProvider = Provider<void>((ref) {
  var recording = false;
  final told = <String>{}; // chats told about this recording (or being told)

  void tellRecording(String? chatId) {
    if (!recording || chatId == null || !told.add(chatId)) return;
    ref.read(messageActionsProvider).screenshotTaken(chatId, recording: true).then(
      (sent) {
        if (!sent) told.remove(chatId); // e.g. no timer yet — may count later
      },
      onError: (Object _) => told.remove(chatId),
    );
  }

  ref.listen<String?>(openChatProvider, (_, chatId) => tellRecording(chatId));
  ref.read(screenshotSourceProvider)(
    () {
      final chatId = ref.read(openChatProvider);
      if (chatId == null) return;
      unawaited(ref.read(messageActionsProvider).screenshotTaken(chatId).then((_) {}, onError: (Object _) {}));
    },
    (on) {
      screenCaptured.value = on;
      if (on == recording) return;
      recording = on;
      told.clear(); // a new recording is news again
      tellRecording(ref.read(openChatProvider));
    },
  );
});
