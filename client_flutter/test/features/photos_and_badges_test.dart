// Owner, 2026-10-18 (screenshots): the photo shows "not always", the
// verified check is "different and not everywhere" (a green ✓ character in
// the chat header), and Settings rows with a chevron do nothing.

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/people.dart' show chatPhotos, withPhotos;
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/new_group/new_group_screen.dart';
import 'package:sinhron/features/settings/_shared.dart';
import 'package:sinhron/widgets/ds_avatar.dart';
import 'package:sinhron/widgets/ds_chat_row.dart';
import 'package:sinhron/widgets/ds_verified_badge.dart';

final anya = 'a1' * 32;
final bob = 'b0' * 32;
final photo = Uint8List.fromList([1, 2, 3]);

ChatPreview dm(String id, String name, String? peer) =>
    ChatPreview(id: id, name: name, preview: '', time: '', peerId: peer);

Widget host(Widget child) => DsTheme(
  tokens: DsTokens.light,
  isDark: false,
  child: MediaQuery(
    data: const MediaQueryData(size: Size(390, 800)),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: child),
    ),
  ),
);

final chevron = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is RowChevronPainter);

void main() {
  test('photos by chat: personal chats with a photo only; lookup is case-blind', () {
    final chats = [
      dm('1', 'Аня', anya.toUpperCase()),
      dm('2', 'Боб', bob),
      const ChatPreview(id: 'g', name: 'Семья', preview: '', time: '', group: true, peerId: null),
    ];
    final photos = {anya: photo};
    expect(chatPhotos(chats, photos), {'1': photo});
    final filled = withPhotos(chats, photos);
    expect(filled[0].avatar, photo);
    expect(filled[1].avatar, isNull);
    expect(filled[2].avatar, isNull);
  });

  test('group candidates carry their photo and the verified mark', () {
    final c = groupCandidates([dm('1', 'Аня', anya), dm('2', 'Боб', bob)], {}, photos: {anya: photo}, verified: {bob});
    expect(c.first.photo, photo);
    expect(c.first.verified, isFalse);
    expect(c.last.photo, isNull);
    expect(c.last.verified, isTrue);
  });

  testWidgets('a settings row without a tap has no chevron; with one it does', (t) async {
    await t.pumpWidget(host(const SettingsRow(label: 'Timer', value: 'Per chat')));
    expect(chevron, findsNothing);
    await t.pumpWidget(host(SettingsRow(label: 'Privacy', value: 'Review', onTap: () {})));
    expect(chevron, findsOneWidget);
  });

  testWidgets('chat list row: the one verified seal, the photo', (t) async {
    await t.pumpWidget(host(DsChatRow(chat: dm('1', 'MacBook', anya).copyWith(verified: true, avatar: photo))));
    expect(find.byType(DsVerifiedBadge), findsOneWidget);
    expect(t.widget<DsAvatar>(find.byType(DsAvatar)).image, photo);
    await t.pumpWidget(host(DsChatRow(chat: dm('1', 'MacBook', anya))));
    expect(find.byType(DsVerifiedBadge), findsNothing);
    expect(find.text('✓'), findsNothing);
  });

  // Status 211 — my newest message didn't go: a red "!" instead of ticks.
  testWidgets('chat list row: a failed last message shows a red mark', (t) async {
    const failed = ChatPreview(id: 'c', name: 'Mama', preview: 'Important', time: '', failed: true);
    await t.pumpWidget(host(const DsChatRow(chat: failed)));
    expect(find.byKey(const ValueKey('chat-row-failed')), findsOneWidget);
    await t.pumpWidget(host(const DsChatRow(chat: ChatPreview(id: 'c', name: 'Mama', preview: 'ok', time: '', sent: true))));
    await t.pumpAndSettle(); // the old mark fades out
    expect(find.byKey(const ValueKey('chat-row-failed')), findsNothing);
  });
}
