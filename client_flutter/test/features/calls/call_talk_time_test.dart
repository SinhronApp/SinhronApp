// Owner, 2026-10-19: "the call lasted minutes, but it says 0 seconds" —
// the "Call ended" screen was built anew when the call's room went away and
// its own timer started from 00:00; the history counted from the answer,
// the timer from the other side's sound. Now all three use the call's
// talk time: from the sound (or the answer, if no sound came) to the end.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/services/net_service.dart';
import 'package:sinhron/features/calls/active_call_provider.dart';
import 'package:sinhron/features/calls/call_screen.dart';
import 'package:sinhron/features/calls/live_call_bar.dart';
import 'package:sinhron/features/calls/livekit_engine.dart';
import 'package:sinhron/l10n/l10n.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

import 'active_call_provider_test.dart' show FakeNetService;

/// No server: the join token never comes.
class _Engine extends CallEngine {
  @override
  Future<CallPrep> prepare({required String httpBaseUrl, required String groupIdHex, required String kind}) =>
      Completer<CallPrep>().future;
}

/// Keeps each history row's length.
class _Log implements CallLog {
  final durations = <int?>[];
  final statuses = <String>[];

  @override
  Future<void> append({
    required String id,
    required String chatId,
    required bool video,
    required String status,
    required bool outgoing,
    required int startedAtUnix,
    required int endedAtUnix,
    int? durationSecs,
  }) async {
    durations.add(durationSecs);
    statuses.add(status);
  }

  @override
  Future<void> missedLine(String chatId, {required bool video}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final t0 = DateTime(2026, 10, 19, 0, 30);
  final ru = lookupAppL10n(const Locale('ru'));

  group('talk time', () {
    test('from the sound to the end; from the answer when no sound came; none without an answer', () {
      final talked = ActiveCallState(
        phase: CallPhase.ended,
        connectedAt: t0,
        audioAt: t0.add(const Duration(seconds: 2)),
        endedAt: t0.add(const Duration(minutes: 2, seconds: 39)),
      );
      expect(talked.talkTime(), const Duration(minutes: 2, seconds: 37));
      final silent = ActiveCallState(phase: CallPhase.ended, connectedAt: t0, endedAt: t0.add(const Duration(seconds: 9)));
      expect(silent.talkTime(), const Duration(seconds: 9));
      expect(const ActiveCallState(phase: CallPhase.ended).talkTime(), isNull);
      // Going on: counted to now.
      final live = ActiveCallState(phase: CallPhase.connected, connectedAt: t0, audioAt: t0);
      expect(live.talkTime(now: t0.add(const Duration(seconds: 75))), const Duration(seconds: 75));
    });

    test('a new call starts without the last one\'s end', () {
      final s = ActiveCallState(phase: CallPhase.ended, endedAt: t0).copyWith(peerMicOff: true);
      expect(s.endedAt, t0, reason: 'copyWith keeps it');
      expect(const ActiveCallState.idle().endedAt, isNull);
    });
  });

  test('the call bar after the end says how long it was, not just "ended"', () {
    final ended = ActiveCallState(
      phase: CallPhase.ended,
      connectedAt: t0,
      audioAt: t0,
      endedAt: t0.add(const Duration(minutes: 2, seconds: 37)),
    );
    expect(callBarLabel(ru, ended), 'Звонок завершён · 02:37');
    expect(callBarLabel(ru, const ActiveCallState(phase: CallPhase.ended)), 'Звонок завершён');
  });

  group('the history row', () {
    late ProviderContainer c;
    late FakeNetService net;
    late _Log log;

    setUp(() {
      log = _Log();
      c = ProviderContainer(
        overrides: [
          netServiceProvider.overrideWith((ref) => net = FakeNetService(ref)),
          callLogProvider.overrideWithValue(log),
          callEngineProvider.overrideWithValue(_Engine()),
        ],
      );
      c.read(activeCallProvider);
    });
    tearDown(() => c.dispose());

    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    Future<ActiveCallNotifier> answered(String id, {String kind = 'audio'}) async {
      net.pushEvent(
        core.NetEvent(
          kind: 'call_invite',
          callInvite: core.NetCallInvite(
            callId: id,
            groupIdHex: 'g1',
            kind: kind,
            livekitRoom: 'sinhron-call-$id',
            ttlSecs: 30,
            callerIdentityHex: 'ca' * 32, // ADR-090: a signed invite
          ),
        ),
      );
      await settle();
      c.read(activeCallProvider.notifier).debugAnswered();
      await settle();
      return c.read(activeCallProvider.notifier);
    }

    test('counts from the sound, like the timer (not from the answer)', () async {
      final n = await answered('01900000-0000-7000-8000-0000000000d1');
      // 1.1 s of "Connecting…" before their sound; then the call ends.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      n.debugHeard();
      await n.end();
      await settle();
      final s = c.read(activeCallProvider);
      expect(s.phase, CallPhase.ended);
      expect(s.endedAt, isNotNull, reason: 'the ended state keeps when it ended');
      expect(log.statuses, ['completed']);
      expect(log.durations, [0], reason: 'from the answer it would be 1 s');
    });

    test('the other side hangs up a video call: the same length on the screen and in the history', () async {
      const id = '01900000-0000-7000-8000-0000000000d2';
      final n = await answered(id, kind: 'video');
      n.debugHeard();
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      net.pushEvent(core.NetEvent(kind: 'call_end', callEnd: core.NetCallEnd(callId: id, reason: 'hangup')));
      await settle();
      final s = c.read(activeCallProvider);
      expect(log.durations, [s.talkTime()!.inSeconds]);
      expect(log.durations.single, 1);
    });
  });

  group('the "Call ended" screen', () {
    Widget host(Widget child) => DsTheme(
      tokens: DsTokens.light,
      isDark: false,
      child: Localizations(
        locale: const Locale('ru'),
        delegates: AppL10n.localizationsDelegates,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: Directionality(textDirection: TextDirection.ltr, child: child),
        ),
      ),
    );

    testWidgets('built anew at the end (the room went away), it still shows the real length', (t) async {
      await t.pumpWidget(
        host(
          CallScreen(
            contactName: 'Мама',
            initialState: CallState.ended,
            connectedAt: t0,
            endedAt: t0.add(const Duration(minutes: 2, seconds: 37)),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Звонок завершён · 02:37'), findsOneWidget);
    });

    testWidgets('a long call: minutes past an hour', (t) async {
      await t.pumpWidget(
        host(
          CallScreen(
            contactName: 'Мама',
            initialState: CallState.ended,
            connectedAt: t0,
            endedAt: t0.add(const Duration(minutes: 75, seconds: 5)),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Звонок завершён · 75:05'), findsOneWidget);
    });

    testWidgets('a live call that ends: the screen keeps counting to the end, not to 00:00', (t) async {
      final at = DateTime.now().subtract(const Duration(seconds: 42));
      Widget screen(CallState s, {DateTime? end}) =>
          host(CallScreen(contactName: 'Мама', initialState: s, connectedAt: at, endedAt: end, onClose: () {}));
      await t.pumpWidget(screen(CallState.active));
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpWidget(screen(CallState.ended, end: at.add(const Duration(seconds: 42))));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Звонок завершён · 00:42'), findsOneWidget);
    });
  });
}
