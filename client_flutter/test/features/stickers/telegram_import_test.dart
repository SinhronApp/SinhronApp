// ADR-062 — a whole Telegram sticker pack by its link (owner, 2026-10-18:
// "download a sticker pack in full by a link from Telegram — now it gives
// an error"). Links, plain-words errors, the batched download, and the
// panel's "paste a link" path end to end (the core is faked).

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/app_notice.dart';
import 'package:sinhron/features/stickers/sticker_store.dart';
import 'package:sinhron/features/stickers/telegram_import.dart';
import 'package:sinhron/l10n/gen/app_l10n_en.dart';
import 'package:sinhron/l10n/gen/app_l10n_ru.dart';
import 'package:sinhron/src/rust/api/stickers.dart' as st;

import 'sticker_chat_test.dart' show Chat, FakeStickerStore, png, settleReal;

st.TelegramPackInfo pack(int n, {String format = 'tgs'}) => st.TelegramPackInfo(
  name: 'Ziongo777',
  title: 'Зионго',
  stickers: [for (var i = 0; i < n; i++) st.TelegramStickerInfo(emoji: i.isEven ? '😀' : '🔥', format: i == 1 ? 'webm' : format, thumb: i == 1)],
);

void main() {
  test('Telegram links: t.me / telegram.me / tg://, stickers and emoji packs, inside any text', () {
    expect(telegramPackName('https://t.me/addstickers/Ziongo777'), 'Ziongo777');
    expect(telegramPackName('глянь t.me/addstickers/Ziongo777 классные'), 'Ziongo777');
    expect(telegramPackName('http://www.telegram.me/addstickers/Cats_by_bot?x=1'), 'Cats_by_bot');
    expect(telegramPackName('https://t.me/addemoji/Hearts'), 'Hearts');
    expect(telegramPackName('tg://addstickers?set=Ziongo777'), 'Ziongo777');
    expect(telegramPackName('HTTPS://T.ME/ADDSTICKERS/Abc'), 'Abc');
    expect(telegramPackName('https://t.me/durov'), isNull);
    expect(telegramPackName('https://t.me/addstickers/'), isNull);
    expect(telegramPackName('https://t.me/addstickers/${'a' * 65}'), isNull, reason: 'longer than a Telegram name');
    expect(telegramPackName('sinhron-stickers:AAAA'), isNull);
    expect(telegramPackId('Ziongo777'), 'tg.ziongo777');
    expect(telegramPackId('A' * 64).length, 64);
  });

  test('every failure reads as plain words', () {
    final ru = AppL10nRu();
    expect(telegramPackError(ru, 'tg:not_found'), 'Набор не найден — проверьте ссылку');
    expect(telegramPackError(ru, StateError('tg:not_configured')), contains('Сервер не настроен'));
    expect(telegramPackError(ru, 'tg:server_old'), contains('нужно обновить'));
    expect(telegramPackError(ru, 'tg:unreachable'), contains('не достаёт до Telegram'));
    expect(telegramPackError(ru, 'tg:rate_limited'), contains('Слишком много'));
    expect(telegramPackError(ru, 'tg:network'), contains('проверьте связь'));
    expect(telegramPackError(AppL10nEn(), 'boom'), "Couldn't load the pack — check the connection");
  });

  test('the download goes in batches with progress; a file that does not come is skipped; a video gets its still', () async {
    final store = FakeStickerStore();
    final progress = <String>[];
    final made = <String>[];
    store.telegram = pack(20);
    final r = await stickersFromTelegram(
      store,
      pack(20),
      onProgress: (d, n) => progress.add('$d/$n'),
      preview: (data, format, emoji) async {
        made.add(format);
        return png;
      },
    );
    expect(store.telegramAsked, [
      [0, 1, 2, 3, 4, 5, 6, 7],
      [8, 9, 10, 11, 12, 13, 14, 15],
      [16, 17, 18, 19],
    ]);
    expect(progress, ['0/20', '8/20', '16/20', '20/20']);
    expect(r.skipped, 1, reason: 'the fake server has nothing for #2');
    expect(r.stickers, hasLength(19));
    expect(r.stickers.first.id, 's1');
    expect(r.stickers[1].emoji, '🔥');
    expect(r.stickers.map((s) => s.id), isNot(contains('s3')));
    // #1 is a video: its still comes from Telegram's thumbnail (a picture).
    expect(made[1], 'webp');

    final p = telegramPack(pack(20), r.stickers);
    expect(p.info.id, 'tg.ziongo777');
    expect(p.info.title, 'Зионго');
    expect(p.info.author, 't.me/addstickers/Ziongo777');
    expect(p.info.count, 19);
  });

  test('stickers already fetched for the preview are not fetched again; cancel stops between batches', () async {
    final store = FakeStickerStore();
    final have = {0: st.StickerData(id: 's1', emoji: '😀', format: 'png', data: png, preview: png)};
    final r = await stickersFromTelegram(store, pack(3), have: have, preview: (_, _, _) async => png);
    expect(store.telegramAsked, [
      [1, 2],
    ]);
    expect(identical(r.stickers.first, have[0]), isTrue);

    var calls = 0;
    await expectLater(
      stickersFromTelegram(store, pack(30), cancelled: () => ++calls > 1, preview: (_, _, _) async => png),
      throwsA(isA<TelegramImportCancelled>()),
    );
    expect(store.telegramAsked.length, 2, reason: 'one batch, then cancelled');
  });

  testWidgets('the panel takes a pasted t.me link: preview, then the whole pack is added as an own pack', (t) async {
    final c = Chat();
    c.stickers.telegram = pack(12, format: 'png');
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': 'https://t.me/addstickers/Ziongo777'};
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await c.pump(t);
    await c.openStickers(t);
    await t.tap(find.byKey(const ValueKey('sticker-add')));
    await t.pumpAndSettle();
    await t.tap(find.text('Paste a link or pack code'));
    for (var i = 0; i < 40 && find.byKey(const ValueKey('telegram-pack-sheet')).evaluate().isEmpty; i++) {
      await settleReal(t);
    }
    await t.pumpAndSettle();

    expect(find.byKey(const ValueKey('telegram-pack-sheet')), findsOneWidget);
    expect(find.text('Зионго'), findsOneWidget);
    expect(find.text('12 stickers · From Telegram'), findsOneWidget);
    expect(c.stickers.telegramAsked, [
      [0, 1, 2, 3, 4, 5, 6, 7],
      [8, 9],
    ], reason: 'only the preview so far');
    expect(c.stickers.saved, isEmpty);

    await t.tap(find.text('Add 12 stickers'));
    await settleReal(t);
    await t.pumpAndSettle();
    expect(c.stickers.telegramAsked.last, [2, 10, 11], reason: 'the rest, and #2 tried again');
    expect(c.stickers.saved.keys, ['tg.ziongo777']);
    final saved = c.stickers.saved['tg.ziongo777']!;
    expect(saved.info.title, 'Зионго');
    expect(saved.stickers, hasLength(11));
    expect(find.byKey(const ValueKey('telegram-pack-progress')), findsNothing);
    expect(c.container.read(userStickerPacksProvider).value!.single.id, 'tg.ziongo777');
  });

  testWidgets('a server without a bot token: one plain line, nothing added', (t) async {
    final c = Chat();
    c.stickers.telegramError = 'tg:not_configured';
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': 't.me/addstickers/Ziongo777'};
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await c.pump(t);
    await c.openStickers(t);
    await t.tap(find.byKey(const ValueKey('sticker-add')));
    await t.pumpAndSettle();
    await t.tap(find.text('Paste a link or pack code'));
    await settleReal(t);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('telegram-pack-sheet')), findsNothing);
    expect(find.byKey(const ValueKey('telegram-pack-progress')), findsNothing);
    expect(c.stickers.saved, isEmpty);
    expect(appNotice.value, "The server isn't set up for Telegram packs yet — ask whoever runs it");
  });
}
