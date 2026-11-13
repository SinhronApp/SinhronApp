// ADR-064 — device transfer loop and ongoing device sync (app side).

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/device_transfer.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/settings/transfer_cards.dart';
import 'package:sinhron/l10n/l10n.dart';
import 'package:sinhron/src/rust/api/transfer.dart' as core;

import 'settings_providers_test.dart' show MemoryStore;

core.TransferStatus st({
  bool outgoing = false,
  String stage = 'parts',
  int done = 1,
  int total = 4,
  int messages = 120,
  bool mediaReady = false,
  int mediaMissing = 0,
}) => core.TransferStatus(
  outgoing: outgoing,
  deviceHex: outgoing ? 'ab' * 32 : '',
  stage: stage,
  done: done,
  total: total,
  messages: messages,
  chats: 3,
  mediaTotal: 10,
  mediaDone: 0,
  mediaMissing: mediaMissing,
  mediaReady: mediaReady,
  error: null,
);

/// Steps through a scripted list; can fail once to test the retry.
class FakeBackend extends DeviceTransferBackend {
  FakeBackend(this.script);
  final List<core.TransferStatus?> script;
  List<core.TransferStatus> current = [];
  int steps = 0;
  int flushes = 0;
  int packFetches = 0;
  bool failNext = false;
  final dismissed = <String>[];
  final started = <String>[];

  @override
  List<core.TransferStatus> status() => current;

  @override
  Future<core.TransferStatus?> step(String base) async {
    if (failNext) {
      failNext = false;
      throw StateError('network');
    }
    final s = steps < script.length ? script[steps] : null;
    steps++;
    current = s == null ? current : [s];
    return s;
  }

  @override
  Future<void> start(String deviceHex) async => started.add(deviceHex);

  @override
  Future<void> dismiss(String base, bool outgoing, String deviceHex) async {
    dismissed.add('$outgoing:$deviceHex');
    current = [];
  }

  @override
  Future<int> flush(String base) async => ++flushes;

  @override
  Future<int> fetchPacks(String base) async => ++packFetches;
}

ProviderContainer container(FakeBackend b, {String? base = 'https://srv', MemoryStore? store}) {
  final c = ProviderContainer(
    overrides: [
      deviceTransferBackendProvider.overrideWithValue(b),
      transferBaseUrlProvider.overrideWithValue(() => base),
      settingsStoreProvider.overrideWithValue(store ?? MemoryStore()),
      chatsRefresherProvider.overrideWithValue(ChatsRefresher(invalidate: () {}, read: () async {})),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('the loop runs steps until there is nothing left, keeping the progress', () async {
    final b = FakeBackend([st(done: 1), st(done: 2), st(stage: 'done', done: 0, total: 0), null]);
    final c = container(b);
    expect(c.read(deviceTransfersProvider), isEmpty);
    await c.read(deviceTransfersProvider.notifier).run();
    expect(b.steps, 4);
    expect(c.read(deviceTransfersProvider).single.stage, 'done');
  });

  testWidgets('offline: nothing runs; a network error waits and tries again', (t) async {
    final b = FakeBackend([st(), null])..failNext = true;
    final c = container(b);
    await c.read(deviceTransfersProvider.notifier).run();
    expect(c.read(deviceTransfersProvider.notifier).waiting, isTrue);
    expect(b.steps, 0);
    await t.pump(DeviceTransfers.retryAfter + const Duration(seconds: 1));
    await t.pump();
    expect(b.steps, 2, reason: 'retried after the pause and finished');
    expect(c.read(deviceTransfersProvider.notifier).waiting, isFalse);

    final idle = FakeBackend([st()]);
    await container(idle, base: null).read(deviceTransfersProvider.notifier).run();
    expect(idle.steps, 0, reason: 'no server, no step');
  });

  test('a transfer message for this device starts the loop; one for another device does not', () async {
    final b = FakeBackend([st(), null]);
    final c = container(b);
    c.read(deviceTransfersProvider.notifier).onTransferMessage('{"for_me": false}');
    await Future<void>.delayed(Duration.zero);
    expect(b.steps, 0);
    c.read(deviceTransfersProvider.notifier).onTransferMessage('{"for_me": true, "stage": 1, "started": true}');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(b.steps, greaterThan(0));
  });

  test('changes from my other device refresh what they touched; packs are fetched', () async {
    final store = MemoryStore();
    final b = FakeBackend([]);
    final c = container(b, store: store);
    expect(await c.read(profileNameProvider.future), '');
    // Rust already wrote the value; the provider must re-read it.
    store.map['profile_name'] = 'Гриша';
    await c.read(deviceSyncProvider).onIncoming('{"settings": ["profile_name"], "packs": true}');
    expect(await c.read(profileNameProvider.future), 'Гриша');
    expect(b.packFetches, 1);
    await c.read(deviceSyncProvider).onIncoming('not json');
  });

  test('flush sends only while connected', () async {
    final b = FakeBackend([]);
    await container(b).read(deviceSyncProvider).flush();
    expect(b.flushes, 1);
    await container(b, base: null).read(deviceSyncProvider).flush();
    expect(b.flushes, 1);
  });

  test('progress lines say where things stand in plain words', () {
    final l = lookupAppL10n(const Locale('ru'));
    expect(transferLine(l, st(outgoing: true, stage: 'upload', done: 2, total: 5)), 'Отправляю: 2 из 5');
    expect(transferLine(l, st(stage: 'parts', done: 3, total: 9)), 'Получаю переписку: 3 из 9');
    expect(transferLine(l, st(stage: 'done', mediaReady: false)), contains('Фото и файлы открываются'));
    expect(transferLine(l, st(outgoing: true, stage: 'done', mediaReady: true, mediaMissing: 2)), contains('2'));
    expect(transferLine(l, st(stage: 'parts'), waiting: true), 'Нет связи — продолжу, когда она появится');
    expect(transferFraction(st(done: 1, total: 4)), 0.25);
    expect(transferFraction(st(stage: 'build', done: 0, total: 0)), isNull);
    expect(isIncomingInProgress(st()), isTrue);
    expect(isIncomingInProgress(st(stage: 'done')), isFalse);
    expect(isIncomingInProgress(st(outgoing: true)), isFalse);
  });

  testWidgets('cards show each transfer; Hide forgets a finished one; the strip shows a new device\'s progress', (t) async {
    final b = FakeBackend([])
      ..current = [st(outgoing: true, stage: 'done', total: 0, done: 0, mediaReady: true)];
    final c = container(b);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const DsTheme(
          tokens: DsTokens.light,
          isDark: false,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Column(children: [TransferCards(), IncomingTransferStrip()]),
          ),
        ),
      ),
    );
    expect(find.textContaining('Moving everything to your new device'), findsOneWidget);
    expect(find.text('Done — 120 messages moved'), findsOneWidget);
    expect(find.byKey(const ValueKey('incoming-transfer-strip')), findsNothing);
    await t.tap(find.text('Hide'));
    await t.pump();
    expect(b.dismissed, ['true:${'ab' * 32}']);
    expect(find.textContaining('Moving everything'), findsNothing);

    b.current = [st(stage: 'parts', done: 1, total: 4)];
    c.invalidate(deviceTransfersProvider);
    expect(c.read(deviceTransfersProvider).single.stage, 'parts');
    await t.pump();
    expect(find.text('Bringing your chats over… 25%'), findsOneWidget);
    expect(find.text('Receiving chats: 1 of 4'), findsOneWidget);
  });
}
