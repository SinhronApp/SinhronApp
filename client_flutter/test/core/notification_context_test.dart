// ADR-056 — what the iPhone's notification extension is told: names,
// blocks and the "Notifications show" setting, never message text.

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/notification_context.dart';
import 'package:sinhron/features/banners/in_app_banner.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/l10n/gen/app_l10n.dart';

ChatPreview chat(String id, String name, {bool group = false, bool muted = false, String? peer}) => ChatPreview(
  id: id,
  name: name,
  peerId: peer,
  preview: 'secret last message',
  time: '',
  kind: ChatPreviewKind.text,
  group: group,
  muted: muted,
);

void main() {
  final ru = lookupAppL10n(const Locale('ru'));

  test('chats, people, blocks and the words — in the shape the extension reads', () {
    final json = buildNotificationContext(
      mode: NotificationPreview.nameOnly,
      l: ru,
      chats: [chat('aa', 'Мама'), chat('bb', 'Семья', group: true, muted: true), chat('cc', 'Спам')],
      names: {'11' * 32: 'Папа'},
      blockedPeers: {'22' * 32},
      blockedChats: {'cc'},
    );
    final m = jsonDecode(json) as Map<String, dynamic>;
    expect(m['mode'], 'nameOnly');
    expect(m['chats'], {
      'aa': {'n': 'Мама'},
      'bb': {'n': 'Семья', 'g': true, 'm': true},
      'cc': {'n': 'Спам', 'b': true},
    });
    expect(m['people'], {'11' * 32: 'Папа'});
    expect(m['blocked'], ['22' * 32]);
    expect((m['words'] as Map)['photo'], ru.kindPhoto);
    expect(json, isNot(contains('secret last message')), reason: 'no message text');
  });

  // ADR-090 (calls:5) — a call push names a personal chat only for its own
  // person's signed invite: the extension needs to know who that is.
  test('a personal chat says whose it is; a group does not', () {
    final json = buildNotificationContext(
      mode: NotificationPreview.nameAndText,
      l: ru,
      chats: [chat('aa', 'Мама', peer: 'AB' * 32), chat('bb', 'Семья', group: true, peer: 'cd' * 32)],
      names: const {},
      blockedPeers: const {},
      blockedChats: const {},
    );
    final chats = (jsonDecode(json) as Map<String, dynamic>)['chats'] as Map<String, dynamic>;
    expect(chats['aa'], {'n': 'Мама', 'p': 'ab' * 32});
    expect(chats['bb'], {'n': 'Семья', 'g': true});
  });

  test('long names are cut; at most maxNotificationChats chats', () {
    final json = buildNotificationContext(
      mode: NotificationPreview.nameAndText,
      l: ru,
      chats: [for (var i = 0; i < maxNotificationChats + 5; i++) chat('c$i', 'я' * 100)],
      names: const {},
      blockedPeers: const {},
      blockedChats: const {},
    );
    final chats = (jsonDecode(json) as Map<String, dynamic>)['chats'] as Map<String, dynamic>;
    expect(chats.length, maxNotificationChats);
    expect((chats['c0'] as Map)['n'], 'я' * 64);
  });
}
