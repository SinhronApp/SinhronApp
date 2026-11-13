// ADR-060 — sharing into Sinhron from another app: what the native side
// hands over, how it reaches the app (once each), and the "Send to…"
// picker (Saved first, search, several chats, caption, errors, cleanup).

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/incoming_share.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/people.dart' show peerAvatarsProvider;
import 'package:sinhron/core/providers/saved_messages.dart' show kSavedChatPendingId;
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/share_into/share_send.dart';
import 'package:sinhron/features/share_into/share_target_screen.dart';
import 'package:sinhron/l10n/l10n.dart';

class _FakePlatform implements SharePlatform {
  _FakePlatform([this.initial]);
  IncomingShare? initial;
  final ctl = StreamController<IncomingShare>.broadcast();
  final finishedIds = <String>[];

  @override
  Stream<IncomingShare> get shares => ctl.stream;

  @override
  Future<IncomingShare?> takeInitial() async {
    final v = initial;
    initial = null;
    return v;
  }

  @override
  Future<void> finished(String id) async => finishedIds.add(id);
}

typedef _Call = ({String chatId, String caption, int files});

const _chats = [
  ChatPreview(id: 'aa01', name: 'Мама', preview: '', time: ''),
  ChatPreview(id: 'bb02', name: 'Семья', preview: '', time: '', group: true),
  ChatPreview(id: 'cc03', name: 'Старый чат', preview: '', time: '', archived: true),
  ChatPreview(id: 'dd04', name: 'Боб', preview: '', time: ''),
];

const _photo = SharedFile(path: '/nowhere/1.jpg', name: '1.jpg', mimeType: 'image/jpeg');

void main() {
  group('what the native side hands over', () {
    test('a share map: files with absolute paths, text, junk ignored', () {
      final s = IncomingShare.fromMap({
        'id': 'a1',
        'text': 'https://example.org',
        'files': [
          {'path': '/c/share/a1/0_IMG.jpg', 'name': 'IMG.jpg', 'mime': 'image/jpeg', 'size': 10},
          {'path': '', 'name': 'x'},
          'junk',
          {'path': '/c/share/a1/1_doc', 'name': '', 'mime': ''},
        ],
      })!;
      expect(s.id, 'a1');
      expect(s.text, 'https://example.org');
      expect(s.files.map((f) => f.name), ['IMG.jpg', '1_doc']);
      expect(s.files.last.mimeType, 'application/octet-stream');
      expect(IncomingShare.fromMap({'text': 'no id'}), isNull);
      expect(IncomingShare.fromMap('nope'), isNull);
      expect(const IncomingShare(id: 'x', text: '  ').isEmpty, isTrue);
    });

    test('how each file goes out: JPEG / PNG photos, videos, everything else a file', () {
      SharedKind k(String mime) => sharedKindOf(SharedFile(path: '/p', name: 'n', mimeType: mime));
      expect(k('image/jpeg'), SharedKind.photo);
      expect(k('image/png'), SharedKind.photo);
      expect(k('image/gif'), SharedKind.document); // keeps moving
      expect(k('image/heic'), SharedKind.document); // native turns it into JPEG first
      expect(k('video/quicktime'), SharedKind.video);
      expect(k('application/pdf'), SharedKind.document);
    });

    test('what the picker says is being sent', () {
      final l = lookupAppL10n(const Locale('en'));
      final ru = lookupAppL10n(const Locale('ru'));
      IncomingShare s(List<String> mimes) => IncomingShare(
        id: 'x',
        files: [for (final m in mimes) SharedFile(path: '/p', name: 'report.pdf', mimeType: m)],
      );
      expect(shareSummary(l, s(['image/jpeg', 'image/png', 'image/jpeg'])), '3 photos');
      expect(shareSummary(ru, s(['image/jpeg'])), 'Фото');
      expect(shareSummary(ru, s(['video/mp4', 'video/mp4'])), '2 видео');
      expect(shareSummary(l, s(['application/pdf'])), 'report.pdf');
      expect(shareSummary(ru, s(['application/pdf', 'video/mp4', 'image/jpeg', 'image/jpeg', 'image/jpeg'])), '5 файлов');
      expect(shareSummary(l, const IncomingShare(id: 'x', text: 'hi')), isNull);
    });

    test('targets: Saved first, archived left out; search by name', () {
      final t = shareTargets(_chats);
      expect(t.first.id, kSavedChatPendingId);
      expect(t.map((c) => c.id), [kSavedChatPendingId, 'aa01', 'bb02', 'dd04']);
      expect(filterShareTargets(t, 'сем').map((c) => c.id), ['bb02']);
      expect(filterShareTargets(t, '  ').length, 4);
    });
  });

  testWidgets('the share that started the app and later ones reach the handler, each once', (t) async {
    const first = IncomingShare(id: 's1', text: 'hello');
    final fake = _FakePlatform(first);
    final got = <String>[];
    await t.pumpWidget(
      ProviderScope(
        overrides: [sharePlatformProvider.overrideWithValue(fake)],
        child: IncomingShareListener(onShare: (s) => got.add(s.id), child: const SizedBox()),
      ),
    );
    await t.pump();
    await t.pump();
    expect(got, ['s1']);
    fake.ctl.add(first); // the same share again as a live event
    fake.ctl.add(const IncomingShare(id: 's2', text: 'link'));
    await t.pump();
    expect(got, ['s1', 's2']);
  });

  group('Send to…', () {
    late _FakePlatform platform;
    late List<_Call> calls;
    String? failFor; // this chat fails once (no connection)

    Future<String> fakeSend(WidgetRef ref, ShareParcel parcel, String chatId, String caption) async {
      if (chatId == failFor) {
        failFor = null;
        throw StateError('not connected to a server');
      }
      calls.add((chatId: chatId, caption: caption, files: parcel.share.files.length));
      return chatId == kSavedChatPendingId ? 'saved-real' : chatId;
    }

    setUp(() {
      platform = _FakePlatform();
      calls = [];
      failFor = null;
    });

    Future<void> pump(WidgetTester t, IncomingShare share, {void Function(List<({String id, ChatPreview chat})>)? onSent, VoidCallback? onCancel}) async {
      t.view.physicalSize = const Size(390, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            chatsProvider.overrideWith((ref) async => _chats),
            peerAvatarsProvider.overrideWith((ref) async => const {}),
            sharePlatformProvider.overrideWithValue(platform),
            shareSendProvider.overrideWithValue(fakeSend),
          ],
          child: DsTheme(
            tokens: DsTokens.light,
            isDark: false,
            child: MediaQuery(
              data: const MediaQueryData(size: Size(390, 1000)),
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: ShareTargetScreen(share: share, onSent: onSent ?? (_) {}, onCancel: onCancel ?? () {}),
              ),
            ),
          ),
        ),
      );
      await t.pump();
    }

    Finder chat(String id) => find.byKey(ValueKey('share-chat-$id'));
    Finder field(String key) => find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(EditableText));
    String sendLabel(WidgetTester t) => (t.widget(find.byKey(const ValueKey('share-send'))) as dynamic).label as String;

    testWidgets('photos to two chats with a caption: Saved first, archived hidden, one send per chat', (t) async {
      List<({String id, ChatPreview chat})>? sent;
      await pump(
        t,
        const IncomingShare(id: 'p1', files: [_photo, _photo, _photo]),
        onSent: (s) => sent = s,
      );
      expect(find.text('3 photos'), findsOneWidget);
      expect(find.text('Saved Messages'), findsOneWidget);
      expect(chat('cc03'), findsNothing);
      expect(sendLabel(t), 'Choose a chat');

      await t.tap(chat(kSavedChatPendingId));
      await t.pump();
      expect(sendLabel(t), 'Send');
      await t.tap(chat('bb02'));
      await t.pump();
      expect(sendLabel(t), 'Send to 2 chats');

      await t.enterText(field('share-caption'), 'С моря');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('share-send')));
      await t.pumpAndSettle();

      expect(calls, [
        (chatId: kSavedChatPendingId, caption: 'С моря', files: 3),
        (chatId: 'bb02', caption: 'С моря', files: 3),
      ]);
      // Saved messages resolved to the real chat for opening it.
      expect(sent!.map((s) => s.id), ['saved-real', 'bb02']);
      expect(sent!.last.chat.group, isTrue);
    });

    testWidgets('a link: the text is the message, editable; search narrows the list; tapping again unpicks', (t) async {
      await pump(t, const IncomingShare(id: 'l1', text: 'https://example.org/a'));
      expect(find.byKey(const ValueKey('share-summary')), findsNothing);
      expect(find.text('https://example.org/a'), findsOneWidget);

      await t.enterText(field('share-search'), 'бо');
      await t.pump();
      expect(chat('aa01'), findsNothing);
      expect(chat('dd04'), findsOneWidget);

      await t.tap(chat('dd04'));
      await t.pump();
      await t.tap(chat('dd04'));
      await t.pump();
      expect(sendLabel(t), 'Choose a chat');
      await t.tap(chat('dd04'));
      await t.pump();

      await t.enterText(field('share-caption'), 'смотри https://example.org/a');
      await t.tap(find.byKey(const ValueKey('share-send')));
      await t.pumpAndSettle();
      expect(calls, [(chatId: 'dd04', caption: 'смотри https://example.org/a', files: 0)]);
    });

    testWidgets('no connection: the error shows, the screen stays; trying again skips the chat already done', (t) async {
      var sentCount = 0;
      failFor = 'dd04';
      await pump(t, const IncomingShare(id: 'e1', files: [_photo]), onSent: (_) => sentCount++);
      await t.tap(chat('aa01'));
      await t.tap(chat('dd04'));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('share-send')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('share-error')), findsOneWidget);
      expect(find.text('Not connected to the server'), findsOneWidget);
      expect(sentCount, 0);
      expect(calls.map((c) => c.chatId), ['aa01']);

      await t.tap(find.byKey(const ValueKey('share-send')));
      await t.pumpAndSettle();
      expect(calls.map((c) => c.chatId), ['aa01', 'dd04']); // not aa01 twice
      expect(sentCount, 1);
    });

    testWidgets('Cancel, or leaving the screen, deletes the shared copies', (t) async {
      final dir = Directory.systemTemp.createTempSync('share-test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/0_a.pdf')..writeAsStringSync('x');
      var cancelled = false;
      await pump(
        t,
        IncomingShare(
          id: 'c1',
          files: [SharedFile(path: f.path, name: 'a.pdf', mimeType: 'application/pdf')],
        ),
        onCancel: () => cancelled = true,
      );
      expect(find.text('a.pdf'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('share-cancel')));
      expect(cancelled, isTrue);
      await t.pumpWidget(const SizedBox()); // the route goes
      for (var i = 0; i < 5 && platform.finishedIds.isEmpty; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
      expect(platform.finishedIds, ['c1']);
      expect(f.existsSync(), isFalse);
    });

    test('a photo over the limit is refused before anything is sent', () async {
      final dir = await Directory.systemTemp.createTemp('share-big');
      addTearDown(() => dir.delete(recursive: true));
      final big = File('${dir.path}/big.jpg');
      final raf = big.openSync(mode: FileMode.write)
        ..setPositionSync(kMaxMediaBytes)
        ..writeByteSync(0);
      raf.closeSync();
      final parcel = ShareParcel(
        IncomingShare(id: 'b', files: [SharedFile(path: big.path, name: 'big.jpg', mimeType: 'image/jpeg')]),
      );
      await expectLater(parcel.checkSizes(), throwsArgumentError);
    });
  });
}
