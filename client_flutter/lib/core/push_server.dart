// ADR-040 — which push server the ntfy app on an Android phone must use.
//
// ntfy starts on ntfy.sh, and a Sinhron server refuses those addresses: it
// only ever sends to its operator's own ntfy (`SINHRON_UNIFIEDPUSH_HOSTS`,
// found by the installer in DNS). The server names those hosts on
// `GET /v1/push/info`; Settings → Sounds & vibration then tells the person
// what to set in ntfy, with Copy / Install or Open ntfy / Connect
// (`features/settings/notifications_screen.dart`).

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'push.dart';
import 'server_address.dart';
import 'services/net_service.dart';

/// ntfy on Google Play (the same app is on F-Droid).
const kNtfyPlayUrl = 'https://play.google.com/store/apps/details?id=io.heckel.ntfy';

/// Is this an Android phone? (faked in tests)
final isAndroidProvider = Provider<bool>((ref) => Platform.isAndroid);

/// `/v1/push/info` → the hosts, lower case; null when the answer isn't one
/// (an older server has no such endpoint).
List<String>? parsePushHosts(int status, String body) {
  if (status != 200) return null;
  try {
    final j = jsonDecode(body);
    final hosts = j is Map ? j['unifiedpush_hosts'] : null;
    if (hosts is! List) return null;
    return [
      for (final h in hosts)
        if (h is String && h.trim().isNotEmpty) h.trim().toLowerCase(),
    ];
  } on FormatException {
    return null;
  }
}

/// ADR-057 — `/v1/push/info` → this server's Firebase ids for Google push
/// (`ids` null: it has none — an older server says nothing either); null
/// when the answer isn't one.
FcmIds? parseFcmIds(int status, String body) {
  if (status != 200) return null;
  try {
    final j = jsonDecode(body);
    if (j is! Map) return null;
    final f = j['fcm'];
    if (f is! Map) return (ids: null);
    final ids = <String, String>{
      for (final k in const ['project_id', 'app_id', 'api_key', 'sender_id'])
        if (f[k] is String && (f[k] as String).isNotEmpty) k: f[k] as String,
    };
    return (ids: ids.length == 4 ? ids : null);
  } on FormatException {
    return null;
  }
}

/// `ids` null = the server has no Google push; the whole answer null =
/// unknown (offline, no server yet).
typedef FcmIds = ({Map<String, String>? ids});

/// Asks the server for its Firebase ids (faked in tests).
final fcmIdsFetcherProvider = Provider<Future<FcmIds?> Function()>(
  (ref) => () async {
    final base = ref.read(netServiceProvider).httpBaseUrl;
    if (base == null || base.isEmpty) return null;
    try {
      final (status, body) = await ref.read(serverHttpGetProvider)(Uri.parse('$base/v1/push/info'));
      return parseFcmIds(status, body);
    } catch (_) {
      return null;
    }
  },
);

/// The hosts this server sends Android push to ([] = none); null = unknown
/// (offline, no server yet, an older server).
final pushHostsProvider = FutureProvider.autoDispose<List<String>?>((ref) async {
  final base = ref.read(netServiceProvider).httpBaseUrl;
  if (base == null || base.isEmpty) return null;
  try {
    final (status, body) = await ref.read(serverHttpGetProvider)(Uri.parse('$base/v1/push/info'));
    return parsePushHosts(status, body);
  } catch (_) {
    return null;
  }
});

enum NtfyStep {
  /// No ntfy on the phone.
  install,

  /// ntfy is there, but Sinhron has no address from it yet.
  setServer,

  /// ntfy gave an address on another server (ntfy.sh): nothing arrives.
  otherServer,

  /// This server sends no push to Android at all.
  serverHasNone,
}

class NtfyHint {
  const NtfyHint(this.step, {this.host = '', this.otherHost = ''});

  final NtfyStep step;

  /// Our push server's host.
  final String host;

  /// [NtfyStep.otherServer]: the host ntfy uses now.
  final String otherHost;

  /// What the person types in ntfy.
  String get serverUrl => 'https://$host';

  @override
  bool operator ==(Object other) =>
      other is NtfyHint && other.step == step && other.host == host && other.otherHost == otherHost;

  @override
  int get hashCode => Object.hash(step, host, otherHost);

  @override
  String toString() => 'NtfyHint($step, $host, $otherHost)';
}

/// What to tell the person, or null: push reaches this phone, or there is
/// nothing to say (notifications refused, server unknown).
NtfyHint? ntfyHintFor({required String status, required List<String>? hosts, required String? endpoint}) {
  if (hosts == null || status == 'denied' || status == 'unsupported') return null;
  // ADR-057 — Google push reaches this phone: ntfy isn't needed.
  if (endpoint != null && endpoint.startsWith('fcm:')) return null;
  if (hosts.isEmpty) return const NtfyHint(NtfyStep.serverHasNone);
  final host = hosts.first;
  if (status == 'noDistributor') return NtfyHint(NtfyStep.install, host: host);
  if (endpoint == null || endpoint.isEmpty) return NtfyHint(NtfyStep.setServer, host: host);
  final at = (Uri.tryParse(endpoint)?.host ?? '').toLowerCase();
  if (hosts.contains(at)) return null;
  return NtfyHint(NtfyStep.otherServer, host: host, otherHost: at);
}

/// The hint for this phone (Android only; re-read when the screen opens or
/// the app comes back).
final ntfyHintProvider = FutureProvider.autoDispose<NtfyHint?>((ref) async {
  if (!ref.read(isAndroidProvider)) return null;
  final hosts = await ref.watch(pushHostsProvider.future);
  final platform = ref.read(pushPlatformProvider);
  final status = await platform.status();
  final endpoint = (await platform.lastVoipToken())?.$1;
  return ntfyHintFor(status: status, hosts: hosts, endpoint: endpoint);
});

/// Is ntfy on the phone? ("Open ntfy" vs "Install ntfy")
final ntfyInstalledProvider = FutureProvider.autoDispose<bool>((ref) => ref.read(pushPlatformProvider).ntfyInstalled());
