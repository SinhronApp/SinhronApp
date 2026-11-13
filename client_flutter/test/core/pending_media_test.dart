import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:async';

import 'package:sinhron/core/providers/message_actions.dart';
import 'package:sinhron/core/providers/pending_media.dart';

class _CancelSender implements MessageSender {
  final cancelled = <String>[];
  @override
  Future<void> resendMedia(String chatId, String wireId, String mediaJson, {String? replyJson, int expireSecs = 0}) async {}

  @override
  void cancelSend(String wireId) => cancelled.add(wireId);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  test('successful job leaves no pending item', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(pendingMediaProvider.notifier);
    final run = n.run(chatId: 'c1', kind: 'photo', label: 'Photo', job: (_) async {});
    expect(c.read(pendingMediaProvider).single.state, PendingMediaState.sending);
    await run;
    expect(c.read(pendingMediaProvider), isEmpty);
  });

  test('failure becomes retryable; retry re-runs the same job', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(pendingMediaProvider.notifier);
    var attempts = 0;
    await n.run(
      chatId: 'c1',
      kind: 'document',
      label: 'report.pdf',
      job: (report) async {
        report('wire-$attempts');
        attempts++;
        if (attempts == 1) throw StateError('offline');
      },
    );
    final failed = c.read(pendingMediaProvider).single;
    expect(failed.state, PendingMediaState.failed);
    expect(failed.wireId, 'wire-0', reason: 'the attempt reported its wire id');
    expect(failed.error, contains('offline'));
    expect(failed.label, 'report.pdf');

    await n.retry(failed.id);
    expect(attempts, 2);
    expect(c.read(pendingMediaProvider), isEmpty);
  });

  test('dismiss drops a failed item; forChat filters by chat', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(pendingMediaProvider.notifier);
    await n.run(chatId: 'a', kind: 'voice', label: 'Voice', job: (_) async => throw StateError('x'));
    await n.run(chatId: 'b', kind: 'voice', label: 'Voice', job: (_) async => throw StateError('x'));
    expect(n.forChat('a').length, 1);
    n.dismiss(n.forChat('a').single.id);
    expect(n.forChat('a'), isEmpty);
    expect(n.forChat('b').length, 1);
  });

  // Owner, 2026-10-18 — an upload can be called back.
  test('cancel while uploading: gone at once, Rust told to stop, no failed item after', () async {
    final sender = _CancelSender();
    final c = ProviderContainer(overrides: [messageSenderProvider.overrideWithValue(sender)]);
    addTearDown(c.dispose);
    final n = c.read(pendingMediaProvider.notifier);
    final upload = Completer<void>();
    final run = n.run(
      chatId: 'c1',
      kind: 'photo',
      label: 'Photo',
      job: (report) async {
        report('wire-1');
        await upload.future;
        throw StateError('send cancelled'); // what Rust answers after a cancel
      },
    );
    await Future<void>.delayed(Duration.zero);
    n.cancel(c.read(pendingMediaProvider).single.id);
    expect(c.read(pendingMediaProvider), isEmpty, reason: 'the bubble goes at once');
    expect(sender.cancelled, ['wire-1']);
    upload.complete();
    await run;
    expect(c.read(pendingMediaProvider), isEmpty, reason: 'no "Not sent" comes back');
  });

  test('cancel before the job has a wire id: the id is stopped as soon as it comes', () async {
    final sender = _CancelSender();
    final c = ProviderContainer(overrides: [messageSenderProvider.overrideWithValue(sender)]);
    addTearDown(c.dispose);
    final n = c.read(pendingMediaProvider.notifier);
    final prepared = Completer<void>();
    final run = n.run(
      chatId: 'c1',
      kind: 'video',
      label: 'Video',
      job: (report) async {
        await prepared.future; // still re-encoding
        report('wire-2');
        throw StateError('send cancelled');
      },
    );
    n.cancel(c.read(pendingMediaProvider).single.id);
    prepared.complete();
    await run;
    expect(sender.cancelled, ['wire-2']);
    expect(c.read(pendingMediaProvider), isEmpty);
  });
}
