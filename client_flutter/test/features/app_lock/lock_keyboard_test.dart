// Audit LOCK-1 — a hardware keyboard must not type into, or send from, the
// chat composer left focused under the App Lock cover.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/adaptive.dart' show SendShortcuts;
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/app_lock/app_lock.dart';

import '../../core/settings_providers_test.dart' show MemoryStore;

class _Auth implements AppAuthenticator {
  bool ok = true;
  @override
  Future<bool> available() async => true;
  @override
  Future<bool> authenticate(String reason) async => ok;
}

void main() {
  testWidgets('locked: keys do not reach the composer under the cover', (t) async {
    final store = MemoryStore()
      ..map['app_lock'] = '1'
      ..map['app_lock_after'] = '0';
    final ctl = TextEditingController();
    final focus = FocusNode();
    final sent = <String>[];
    final auth = _Auth();
    var now = DateTime(2026, 11, 11, 12);
    await t.pumpWidget(ProviderScope(
      overrides: [settingsStoreProvider.overrideWithValue(store), appAuthenticatorProvider.overrideWithValue(auth)],
      child: DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(390, 800)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: AppLockGate(
              now: () => now,
              child: SendShortcuts(
                controller: ctl,
                onSend: () => sent.add(ctl.text),
                child: EditableText(
                  controller: ctl,
                  focusNode: focus,
                  style: const TextStyle(),
                  cursorColor: const Color(0xFF000000),
                  backgroundCursorColor: const Color(0xFF000000),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    // Owner unlocked, opened the chat, tapped the composer.
    expect(find.byKey(const ValueKey('lock-cover')), findsNothing);
    focus.requestFocus();
    await t.pump();
    // Owner puts the iPad down: app goes to background.
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = now.add(const Duration(minutes: 10));
    // Attacker picks it up and opens Sinhron: Face ID fails / is cancelled.
    auth.ok = false;
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('lock-cover')), findsOneWidget);
    // Attacker with the iPad + keyboard: types and presses Enter.
    ctl.text = 'переведи 500 на этот номер';
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(find.byKey(const ValueKey('lock-cover')), findsOneWidget, reason: 'still locked');
    expect(focus.hasFocus, isFalse);
    expect(sent, isEmpty, reason: 'the lock should stop keys reaching the chat under it');
  });
}
