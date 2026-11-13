// "Report a problem" (owner, 2026-10-22): one text file with what the
// developer needs — version, phone, how the connection / pushes / calls
// are set up now, and the app's journal for the last hour
// (lib/core/diag_log.dart). No message text, names or keys: the journal
// never has them, and push routes go in by kind only (not the token).

import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/call_reach.dart';
import '../../core/diag_log.dart';
import '../../core/push.dart';
import '../../core/providers/settings_providers.dart';
import '../../core/services/net_service.dart';
import '../calls/call_path.dart';
import '../settings/settings_screen.dart' show appVersionLabel;

/// Facts about this phone and app, one "key: value" per line.
typedef ReportFacts = List<(String, String)>;

/// The report file: [note] from the person, [facts], then the app's and
/// the native journal, oldest first.
String buildProblemReport({
  required String note,
  required ReportFacts facts,
  required List<DiagLine> app,
  List<DiagLine> native = const [],
  required DateTime now,
}) {
  String line(DiagLine l) => '${_hms(l.at)}  ${l.text}';
  final b = StringBuffer()
    ..writeln('Sinhron — отчёт о проблеме')
    ..writeln('Время: ${now.toLocal().toIso8601String()} (UTC${_offset(now.toLocal().timeZoneOffset)})')
    ..writeln()
    ..writeln('Что случилось:')
    ..writeln(note.trim().isEmpty ? '(не написано)' : note.trim())
    ..writeln()
    ..writeln('— Телефон и приложение —');
  for (final (k, v) in facts) {
    b.writeln('$k: $v');
  }
  b
    ..writeln()
    ..writeln('— Журнал приложения, последний час (${app.length}) —');
  for (final l in app) {
    b.writeln(line(l));
  }
  if (native.isNotEmpty) {
    b
      ..writeln()
      ..writeln('— Журнал системной части (пуши, звонки), последний час (${native.length}) —');
    for (final l in native) {
      b.writeln(line(l));
    }
  }
  return b.toString();
}

String _two(int n) => n.toString().padLeft(2, '0');
String _hms(DateTime t) {
  final l = t.toLocal();
  return '${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}';
}

String _offset(Duration d) {
  final sign = d.isNegative ? '-' : '+';
  final m = d.inMinutes.abs();
  return '$sign${_two(m ~/ 60)}:${_two(m % 60)}';
}

/// A push route by kind only: "fcm" / "ntfy" / "apns" — never the token.
String pushRouteKind(String? route) => switch (route) {
  null || '' => 'нет',
  final r when r.startsWith('fcm:') => 'Google (FCM)',
  final r when r.startsWith('https://') => 'ntfy',
  _ => 'APNs / PushKit',
};

/// What this phone says now (each fact best-effort: one that can't be read
/// says so and the rest still go).
Future<ReportFacts> gatherReportFacts(Ref ref) async {
  final facts = <(String, String)>[];
  Future<void> add(String k, Future<String> Function() v) async {
    try {
      facts.add((k, await v()));
    } catch (e) {
      facts.add((k, 'не удалось узнать ($e)'));
    }
  }

  facts.add(('Версия', appVersionLabel()));
  await add('Телефон', () async {
    if (Platform.isIOS) {
      final i = await DeviceInfoPlugin().iosInfo;
      return '${i.utsname.machine} · iOS ${i.systemVersion}';
    }
    if (Platform.isAndroid) {
      final a = await DeviceInfoPlugin().androidInfo;
      return '${a.manufacturer} ${a.model} · Android ${a.version.release} (SDK ${a.version.sdkInt})';
    }
    return Platform.operatingSystem;
  });
  final net = ref.read(netServiceProvider);
  facts
    ..add(('Сервер', net.httpBaseUrl ?? '—'))
    ..add(('Связь сейчас', net.status.name))
    ..add(('Последняя ошибка связи', net.lastError ?? '—'));
  await add('VPN', () async {
    final on = await const MethodChannel('dev.sinhron/network').invokeMethod<bool>('vpnActive');
    return on == null ? '?' : (on ? 'включён' : 'нет');
  });
  final push = ref.read(pushPlatformProvider);
  await add('Уведомления', push.status);
  await add('Push для звонков', () async => pushRouteKind((await push.lastVoipToken())?.$1));
  await add('Входящие звонки', () async => (await ref.read(incomingCallsProvider.future)) ? 'вкл' : 'выкл');
  await add('Звонки через резервный путь', () async => (await ref.read(callsReserveAlwaysProvider.future)) ? 'всегда' : 'по необходимости');
  if (Platform.isAndroid) {
    await add('Постоянное соединение', () async => (await ref.read(keepConnectedProvider.future)) ? 'вкл' : 'выкл');
    await add('Дойдут ли звонки', () async => '${await ref.watch(callReachProvider.future)}');
    // Status 223 (Samsung: «нет уведомлений») — did Google push ever
    // reach this phone, and is the battery limit off.
    await add('Батарея без ограничений', () async => (await ref.read(batteryPlatformProvider).status()).exempt ? 'да' : 'нет');
    await add('Последний push от Google', () async {
      final at = await DiagLog.instance.nativeLast('fcm: push');
      return at == null ? 'ни разу (за время журнала)' : at.toLocal().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    });
  }
  return facts;
}

/// The facts, read anew each time (`ref.refresh`). Not autoDispose: nobody
/// listens to it — the screen only awaits `.future` — and an autoDispose
/// provider was disposed at its first `await`, so the next `ref.read` threw
/// ("Cannot use the Ref … after it has been disposed"): the report never
/// came, and "Send" / "Preview" did nothing (owner, 2026-10-24, 0.9.0).
final problemReportFactsProvider = FutureProvider<ReportFacts>(gatherReportFacts);
