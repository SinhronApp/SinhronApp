// ADR-049 — stickers end to end in the chat screen: the panel next to the
// emoji, a tap sends (encrypted media message of the new kind, through the
// StickerStore seam), a received sticker is big without a bubble with the
// time pill, and its pack can be added from it. Plus the emoji panel's
// search and skin tones.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/haptics.dart';
import 'package:sinhron/core/providers/chat_actions.dart';
import 'package:sinhron/core/providers/chat_messages.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/message_actions.dart';
import 'package:sinhron/core/providers/pending_media.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/services/net_service.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/chat_view/chat_view_screen.dart';
import 'package:sinhron/features/chat_view/emoji_panel.dart';
import 'package:sinhron/features/stickers/sticker_codec.dart';
import 'package:sinhron/features/stickers/sticker_message.dart';
import 'package:sinhron/features/stickers/sticker_store.dart';
import 'package:sinhron/features/stickers/sticker_view.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;
import 'package:sinhron/src/rust/api/stickers.dart' as st;

import '../../core/chat_actions_test.dart' show FakeChatStore;
import '../../core/message_actions_test.dart' show FakeGroupOps, FakeMessageStore, FakeSender;
import '../../core/settings_providers_test.dart' show MemoryStore;

const chatId = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678';
final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1]);
final webmFile = Uint8List.fromList([0x1a, 0x45, 0xdf, 0xa3, 1]);

class OnlineNet extends NetService {
  OnlineNet(super.ref);
  @override
  String? get httpBaseUrl => 'http://srv';
}

/// Stands in for the Rust core (`api/stickers.rs`).
class FakeStickerStore implements StickerStore {
  final saved = <String, st.StickerPack>{};
  final sent = <Map<String, Object?>>[];
  st.StickerPack? remote;
  st.StickerMeta meta_ = const st.StickerMeta(
    emoji: '😺',
    format: 'png',
    width: 512,
    height: 512,
    packId: 'u0011223344556677',
    packTitle: 'Котики',
    packCount: 2,
    packAttached: true,
  );

  @override
  Future<List<st.StickerPackInfo>> list() async => [for (final p in saved.values) p.info];
  @override
  Future<st.StickerPack> load(String id) async => saved[id]!;
  @override
  Future<st.StickerPackInfo> save({
    required String id,
    required String title,
    String author = '',
    String license = '',
    required List<st.StickerData> stickers,
  }) async {
    final info = st.StickerPackInfo(
      id: id,
      title: title,
      author: author,
      license: license,
      count: stickers.length,
      animated: false,
      cover: stickers.first.preview,
    );
    saved[id] = st.StickerPack(info: info, stickers: stickers);
    return info;
  }

  @override
  Future<void> delete(String id) async => saved.remove(id);
  @override
  Future<void> move(String id, int to) async {}
  @override
  Future<String> share(String id) async => 'sinhron-stickers:CODE';
  @override
  Future<st.StickerPack> fetchCode(String code) async => remote!;
  @override
  Future<st.StickerPack> fetchFromMessage(String mediaJson) async => remote!;
  @override
  Future<st.StickerMeta> meta(String mediaJson) async => meta_;
  @override
  Future<Uint8List> fetchSticker(String mediaJson) async => png;

  /// The still a sticker message carries (null: none).
  Uint8List? still;
  @override
  Future<Uint8List?> fetchStill(String mediaJson) async => still;

  /// ADR-062 — the Telegram pack the fake server has (null: "not found").
  st.TelegramPackInfo? telegram;
  Object? telegramError;
  final telegramAsked = <List<int>>[];
  @override
  Future<st.TelegramPackInfo> telegramInfo(String name) async {
    if (telegramError != null) throw telegramError!;
    if (telegram == null || telegram!.name.toLowerCase() != name.toLowerCase()) throw 'tg:not_found';
    return telegram!;
  }

  @override
  Future<List<st.TelegramFile>> telegramFiles(String name, List<int> indices, {List<int> thumbFor = const []}) async {
    telegramAsked.add(indices);
    return [
      for (final i in indices)
        st.TelegramFile(index: i, data: i == 2 ? Uint8List(0) : (telegram?.stickers[i].format == 'webm' ? webmFile : png), thumb: thumbFor.contains(i) ? png : Uint8List(0)),
    ];
  }
  @override
  Future<String> send({
    required String serverBaseUrl,
    required String groupIdHex,
    required String messageId,
    required String format,
    required Uint8List data,
    required Uint8List stillPng,
    required Uint8List thumbnailPng,
    required String emoji,
    required String packId,
    required String packTitle,
    required int packCount,
    String? replyJson,
    required int expireSecs,
  }) async {
    sent.add({
      'group': groupIdHex,
      'format': format,
      'emoji': emoji,
      'pack': packId,
      'title': packTitle,
      'count': packCount,
      'still': stillPng.length,
      'thumb': thumbnailPng.length,
    });
    return '{"v":1,"kind":"photo","sticker":{"format":"$format"}}';
  }
}

st.StickerPack catsPack() => st.StickerPack(
  info: st.StickerPackInfo(
    id: 'u0011223344556677',
    title: 'Котики',
    author: 'Аня',
    license: 'CC0',
    count: 2,
    animated: false,
    cover: png,
  ),
  stickers: [
    st.StickerData(id: 's1', emoji: '😺', format: 'png', data: png, preview: png),
    st.StickerData(id: 's2', emoji: '😿', format: 'png', data: png, preview: png),
  ],
);

class Chat {
  Chat({List<core.StoredMessageSummary> history = const []}) {
    container = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(settings),
        messageStoreProvider.overrideWithValue(messages),
        messageSenderProvider.overrideWithValue(FakeSender()),
        chatStoreProvider.overrideWithValue(FakeChatStore()),
        groupOpsProvider.overrideWithValue(FakeGroupOps()),
        hapticsProvider.overrideWithValue(Haptics(() => false)),
        linkPreviewBaseUrlProvider.overrideWithValue(() => null),
        netServiceProvider.overrideWith(OnlineNet.new),
        stickerStoreProvider.overrideWithValue(stickers),
        uploadProgressProvider.overrideWithValue((_) => 0.0),
        messagePageFetcherProvider.overrideWithValue(
          (String id, {int? beforeTs, String? beforeId, required int limit}) async => beforeId == null ? history : const [],
        ),
        chatsProvider.overrideWith((ref) async => const [ChatPreview(id: chatId, name: 'Maria', preview: '', time: '')]),
      ],
    );
  }

  final settings = MemoryStore();
  final messages = FakeMessageStore();
  final stickers = FakeStickerStore();
  late final ProviderContainer container;

  Future<void> pump(WidgetTester t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    addTearDown(container.dispose);
    await container.read(chatsProvider.future);
    await t.runAsync(() => container.read(builtinStickerPacksProvider.future));
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: DsTheme(
          tokens: DsTokens.light,
          isDark: false,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(390, 844)),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Navigator(
                onGenerateRoute: (_) => PageRouteBuilder(
                  pageBuilder: (_, _, _) => const ChatViewScreen(chatId: chatId, contactName: 'Maria'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<void> openStickers(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('composer-emoji')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('panel-mode-stickers')));
    await t.pumpAndSettle();
  }
}

/// Lets real async work (asset loads, image decoding) finish.
Future<void> settleReal(WidgetTester t) async {
  for (var i = 0; i < 5; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('the sticker panel sits next to the emoji; a tap sends the sticker as a sticker message', (t) async {
    final c = Chat();
    await c.pump(t);
    await c.openStickers(t);
    expect(find.byKey(const ValueKey('sticker-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('emoji-tabs')), findsNothing);
    // Built-in packs as tabs, the emoji filter, the + for adding packs.
    expect(find.byKey(const ValueKey('sticker-tab-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('sticker-add')), findsOneWidget);
    // Jump to the Fluent pack and send the dog.
    await t.tap(find.byKey(const ValueKey('sticker-tab-2')));
    await t.pumpAndSettle();
    final dog = find.byKey(const ValueKey('sticker-sinhron.fluent_3d-sinhron.fluent_3d/dog_face'));
    await t.ensureVisible(dog);
    await t.pumpAndSettle();
    await t.tap(dog);
    await settleReal(t);
    await t.pumpAndSettle();
    expect(c.stickers.sent, hasLength(1));
    final s = c.stickers.sent.single;
    expect(s['group'], chatId);
    expect(s['format'], 'webp');
    expect(s['emoji'], '🐶');
    expect(s['pack'], 'sinhron.fluent_3d');
    expect(s['count'], 36);
    expect(s['still'], 0, reason: 'a still sticker is its own picture');
    expect(s['thumb'] as int, greaterThan(0), reason: 'older apps show the thumbnail');
    final row = c.messages.rows.single;
    expect(row.kind, 'sticker');
    expect(row.mediaJson, contains('"sticker"'));
    // Recent stickers remember it; the panel stays open.
    expect(c.container.read(recentStickersProvider).value, 'sinhron.fluent_3d/dog_face');
    expect(find.byKey(const ValueKey('sticker-panel')), findsOneWidget);
    // Filter by emoji: only stickers that stand for it.
    await t.tap(find.byKey(const ValueKey('sticker-filter-😂')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('sticker-found-sinhron.noto_faces/1f602')), findsOneWidget);
    expect(find.byKey(const ValueKey('sticker-found-sinhron.fluent_3d/dog_face')), findsNothing);
    // Back to emoji.
    await t.tap(find.byKey(const ValueKey('panel-mode-emoji')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('emoji-tabs')), findsOneWidget);
  });

  testWidgets('a received sticker is big, without a bubble, with the time; a tap offers to add its pack', (t) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final c = Chat(
      history: [
        core.StoredMessageSummary(
          id: 'm1',
          chatId: chatId,
          tsUnix: now - 60,
          body: '',
          kind: 'sticker',
          isMine: false,
          mediaJson: '{"v":1,"kind":"photo","sticker":{"format":"png"}}',
          wireId: '00000000-0000-4000-8000-000000000001',
          status: 1,
          deleted: false,
        ),
      ],
    );
    c.stickers.remote = catsPack();
    await c.pump(t);
    await settleReal(t);
    expect(find.byKey(const ValueKey('sticker-bubble')), findsOneWidget);
    expect(find.byKey(const ValueKey('sticker-message')), findsOneWidget);
    expect(t.getSize(find.byKey(const ValueKey('sticker-message'))).width, greaterThan(150));
    await t.tap(find.byKey(const ValueKey('sticker-message')));
    await settleReal(t);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('sticker-pack-sheet')), findsOneWidget);
    expect(find.text('Котики'), findsOneWidget);
    await t.tap(find.text('Add 2 stickers'));
    await t.pumpAndSettle();
    expect(c.stickers.saved.keys, ['u0011223344556677'], reason: 'kept by the core (encrypted)');
    expect(c.container.read(userStickerPacksProvider).value!.single.title(''), 'Котики');
    // It's a tab in the panel now (after the three built-in ones).
    await c.openStickers(t);
    expect(find.byKey(const ValueKey('sticker-tab-3')), findsOneWidget);
    // Opening it again: already added — nothing to add.
    await t.tap(find.byKey(const ValueKey('composer-emoji')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('sticker-message')));
    await settleReal(t);
    await t.pumpAndSettle();
    expect(find.text('Add 2 stickers'), findsNothing);
  });

  testWidgets('emoji panel: search by name shrinks to one row of results; hold for skin tones', (t) async {
    final c = Chat();
    await c.pump(t);
    await t.tap(find.byKey(const ValueKey('composer-emoji')));
    await t.pumpAndSettle();
    // Skin tones: hold 👋 (people, first) → six variants; the pick is typed and remembered.
    await t.tap(find.byKey(const ValueKey('emoji-tab-1')));
    await t.pumpAndSettle();
    await t.longPress(find.byKey(const ValueKey('emoji-people-0')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('emoji-tones')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('emoji-tone-3')));
    await t.pumpAndSettle();
    final composer = t.widget<EditableText>(find.byType(EditableText).first).controller;
    expect(composer.text, '👋🏽');
    expect(c.container.read(emojiTonesProvider).value, '👋=👋🏽');
    expect(find.text('👋🏽'), findsWidgets, reason: 'the grid shows the chosen tone');
    // Search: Russian name.
    await t.enterText(find.byType(EditableText).last, 'кот');
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('emoji-results')), findsOneWidget);
    expect(find.byKey(const ValueKey('emoji-tabs')), findsNothing);
    expect(t.getSize(find.byKey(const ValueKey('emoji-panel'))).height, lessThan(120));
    await t.tap(find.byKey(const ValueKey('emoji-found-0')));
    await t.pump();
    expect(composer.text, startsWith('👋🏽'));
    expect(composer.text.length, greaterThan('👋🏽'.length));
  });

  testWidgets('a sticker stays still when the phone asks for less motion', (t) async {
    final packs = await t.runAsync(loadBuiltinPacks);
    final s = packs!.first.stickers.first;
    await t.runAsync(() => lottieCompositions.get(s.key, s.bytes));
    final key = GlobalKey<StickerViewState>();
    await t.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Directionality(textDirection: TextDirection.ltr, child: StickerView.of(s, key: key)),
      ),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(t.binding.hasScheduledFrame, isFalse, reason: 'nothing animates');
  });

  // Owner, 2026-10-20: a video sticker on iPhone / iPad showed as its
  // emoji (⭐) — the still it carries was never drawn.
  testWidgets('a video sticker that can\'t play here shows its still, not its emoji', (t) async {
    final store = FakeStickerStore()
      ..meta_ = const st.StickerMeta(
        emoji: '⭐',
        format: 'webm',
        width: 512,
        height: 512,
        packId: '',
        packTitle: '',
        packCount: 0,
        packAttached: false,
      );
    Widget host() => ProviderScope(
      overrides: [stickerStoreProvider.overrideWithValue(store)],
      child: const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: StickerMessage(mediaJson: '{"kind":"photo"}')),
      ),
    );
    store.still = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==');
    await t.pumpWidget(host());
    await t.pump();
    await t.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('⭐'), findsNothing);

    // No still at all: the emoji is the last resort.
    store.still = null;
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(host());
    await t.pump();
    await t.pump();
    expect(find.text('⭐'), findsOneWidget);
  });
}
