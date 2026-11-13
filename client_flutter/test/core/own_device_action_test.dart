// Audit 2026-11b B03 — an edit / delete made on my other device must
// apply to my own rows here (stored is_mine = 1), i.e. as author "me".
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/core/providers/message_actions.dart';
import 'package:sinhron/core/services/net_service.dart';

import 'message_actions_test.dart' show FakeMessageStore, FakeSender;

class _Net extends NetService {
  _Net(super.ref);
  @override
  String? get myIdentityHex => 'me1';
}

void main() {
  test('delete and edit from my other device apply as mine', () async {
    // accept = false: only the attribution is under test (no chat refresh).
    final store = FakeMessageStore()..accept = false;
    final c = ProviderContainer(
      overrides: [
        messageStoreProvider.overrideWithValue(store),
        messageSenderProvider.overrideWithValue(FakeSender()),
        chatsProvider.overrideWith((ref) async => const <ChatPreview>[]),
        netServiceProvider.overrideWith(_Net.new),
      ],
    );
    addTearDown(c.dispose);
    final a = c.read(messageActionsProvider);
    await a.onIncomingAction('chat', 'delete', jsonEncode({'target': 'w1'}), 'me1');
    await a.onIncomingAction('chat', 'edit', jsonEncode({'target': 'w2', 'text': 'new'}), 'me1');
    await a.onIncomingAction('chat', 'delete', jsonEncode({'target': 'w3'}), 'peer1');
    expect(store.calls, containsAll(['delete w1 me', 'edit w2 me new', 'delete w3 peer1']));
  });
}
