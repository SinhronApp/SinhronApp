import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/chat_actions.dart';
import 'package:sinhron/core/providers/chat_messages.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/services/media_loader.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/chat_list/chat_list_screen.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

import '../../core/chat_actions_test.dart' show FakeChatStore;
import '../../core/settings_providers_test.dart' show MemoryStore;

// 1×1 transparent PNG.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01,
  0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _Loader implements MediaLoader {
  @override
  Future<core.MediaInfo> info(String mediaJson) async => core.MediaInfo(
        kind: mediaJson.contains('voice') ? 'voice' : 'document',
        mimeType: '',
        fileName: mediaJson.contains('doc') ? 'plan.pdf' : '',
        blurhash: '',
        width: 0,
        height: 0,
        durationMs: mediaJson.contains('voice') ? 14000 : 0,
        waveform: Uint8List(0),
        caption: '',
        sizeBytes: BigInt.zero,
        hasThumbnail: true,
        round: false,
      );

  @override
  Future<Uint8List> blurhash(String hash, int width, int height) async => _png;

  @override
  Future<Uint8List> fetch(String mediaJson, {required bool thumbnail}) async => _png;
}

final _base = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3600;

core.StoredMessageSummary _row(int i, String body, {String kind = 'text', String? media, bool mine = false}) =>
    core.StoredMessageSummary(
      id: 'm$i',
      chatId: 'alice',
      tsUnix: _base + i,
      body: body,
      kind: kind,
      isMine: mine,
      mediaJson: media,
      status: 1,
      deleted: false,
    );

/// Oldest first, as the store pages them: 26 words, then a photo, a
/// voice message and a document — the newest.
final _history = [
  for (var i = 0; i < 26; i++) _row(i, 'line $i', mine: i.isEven),
  _row(26, '', kind: 'photo', media: '{"photo":1}'),
  _row(27, '', kind: 'voice', media: '{"voice":1}', mine: true),
  _row(28, '', kind: 'document', media: '{"doc":1}'),
];

Widget _host(FakeChatStore store, Size size) => ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(MemoryStore()),
        chatsProvider.overrideWith(
          (ref) async => [const ChatPreview(id: 'alice', name: 'alice', preview: '', time: '', unread: 2)],
        ),
        messagePageFetcherProvider.overrideWithValue(
          (String id, {int? beforeTs, String? beforeId, required int limit}) async =>
              _history.sublist(_history.length > limit ? _history.length - limit : 0),
        ),
        mediaLoaderProvider.overrideWithValue(_Loader()),
        chatStoreProvider.overrideWithValue(store),
      ],
      child: DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: MediaQuery(
          data: MediaQueryData(size: size),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Navigator(onGenerateRoute: (_) => PageRouteBuilder(pageBuilder: (_, _, _) => const ChatListScreen())),
          ),
        ),
      ),
    );

void _screen(WidgetTester t, Size size) {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

void main() {
  testWidgets('peek: a tall card with real thumbnails, voice length, file name; it scrolls, marks nothing read', (t) async {
    const size = Size(390, 844);
    _screen(t, size);
    final store = FakeChatStore();
    await t.pumpWidget(_host(store, size));
    await t.pumpAndSettle();

    await t.longPress(find.text('alice'));
    await t.pumpAndSettle();

    final peek = find.byKey(const ValueKey('chat-peek'));
    expect(peek, findsOneWidget);
    expect(t.getSize(peek).height, greaterThan(size.height * 0.4), reason: 'a tall card, not a strip');
    expect(find.byKey(const ValueKey('peek-thumb')), findsOneWidget, reason: 'the photo, not the word "Photo"');
    expect(find.byKey(const ValueKey('photo-thumb')), findsOneWidget, reason: 'its decrypted thumbnail');
    expect(find.text('Photo'), findsNothing);
    expect(find.byKey(const ValueKey('peek-voice')), findsOneWidget);
    expect(find.text('0:14'), findsOneWidget);
    expect(find.byKey(const ValueKey('peek-document')), findsOneWidget);
    expect(find.text('plan.pdf'), findsOneWidget);
    // All the menu fits under it; no Cancel in a menu.
    expect(find.byKey(const ValueKey('sheet-action-Delete chat')).hitTestable(), findsOneWidget);
    expect(find.byKey(const ValueKey('sheet-cancel')), findsNothing);

    // A drag in the list scrolls it to older messages; the sheet stays.
    final list = find.byKey(const ValueKey('chat-peek-list'));
    final position = t.state<ScrollableState>(find.descendant(of: list, matching: find.byType(Scrollable))).position;
    expect(position.pixels, 0);
    await t.drag(list, const Offset(0, 300));
    await t.pumpAndSettle();
    expect(position.pixels, greaterThan(100));
    expect(peek, findsOneWidget, reason: 'scrolling does not close the peek');

    expect(store.calls, isEmpty, reason: 'peeking marks nothing read');
    await t.tapAt(const Offset(195, 20));
    await t.pumpAndSettle();
    expect(peek, findsNothing);
    expect(store.calls, isEmpty);
  });

  testWidgets('peek on an iPad: a centred card of a sensible size', (t) async {
    const size = Size(1024, 1366);
    _screen(t, size);
    await t.pumpWidget(_host(FakeChatStore(), size));
    await t.pumpAndSettle();

    await t.longPress(find.text('alice'));
    await t.pumpAndSettle();
    final popup = t.getRect(find.byKey(const ValueKey('sheet-popup')));
    expect(popup.width, lessThanOrEqualTo(480));
    expect(popup.center.dx, closeTo(size.width / 2, 1));
    final peek = t.getSize(find.byKey(const ValueKey('chat-peek')));
    expect(peek.height, inInclusiveRange(400, 640));
    expect(find.byKey(const ValueKey('sheet-grabber')), findsNothing, reason: 'a popup, not a bottom sheet');
    expect(find.byKey(const ValueKey('sheet-action-Delete chat')).hitTestable(), findsOneWidget);
  });
}
