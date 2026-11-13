// Audit 2026-11b S02: the "verified" mark must be re-checked each time a
// screen is opened, not cached for the whole app run.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/verify/verify_contact.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

import '../../core/settings_providers_test.dart' show MemoryStore;

void main() {
  test('verified mark drops when the peer key changes between two screen opens', () async {
    var peer = 'bb' * 32;
    final store = MemoryStore();
    await store.set('verified:chat', peer);
    final c = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(store),
        safetyInfoLoaderProvider.overrideWithValue(
          (_) async => core.SafetyInfo(myKeyHex: 'aa' * 32, peerKeyHex: peer, number: ''),
        ),
      ],
    );
    addTearDown(c.dispose);

    // Screen opened: watches the state.
    var sub = c.listen(verifyStateProvider('chat'), (_, _) {});
    expect(await c.read(verifyStateProvider('chat').future), VerifyState.verified);
    // Screen closed; the other member's key in the chat changes.
    sub.close();
    await c.pump();
    peer = 'cc' * 32;
    // Screen opened again.
    sub = c.listen(verifyStateProvider('chat'), (_, _) {});
    expect(await c.read(verifyStateProvider('chat').future), VerifyState.changed);
    sub.close();
  });
}
