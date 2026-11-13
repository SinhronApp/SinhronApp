// The server a person joins — typed in or scanned from the installer's QR
// (ADR-032). Nothing is compiled in: a release build has no server until
// the person gives one.
//
// Accepted forms (all become `wss://host[:port]/v1/sync`):
//   sinhron.example.com            sinhron.example.com:8443
//   https://sinhron.example.com    sinhron-server:https://sinhron.example.com  (QR)
//   wss://sinhron.example.com/v1/sync
// Plain `http://` / `ws://` are kept only for a test server on this machine
// or a home network (localhost, 127.x, 10.x, 172.16–31.x, 192.168.x);
// anywhere else they are refused — no silent traffic without TLS (CN-02).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/rust/api/simple.dart' as core;

/// Prefix of the server QR the installer prints.
const kServerQrPrefix = 'sinhron-server:';

/// Dev builds may prefill the field (`--dart-define=SINHRON_WS_URL=…`);
/// release builds leave it empty.
const String kDevServerUrl = String.fromEnvironment('SINHRON_WS_URL');

final _host = RegExp(
  r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$',
);
final _ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');

bool _validHost(String h) {
  if (h.isEmpty || h.length > 253) return false;
  final v4 = _ipv4.firstMatch(h);
  if (v4 != null) return [for (var i = 1; i <= 4; i++) int.parse(v4.group(i)!)].every((n) => n <= 255);
  if (h.startsWith('[') && h.endsWith(']')) return InternetAddress.tryParse(h.substring(1, h.length - 1)) != null;
  // A bare word ("localhost") is fine; anything else needs a dot.
  return _host.hasMatch(h);
}

/// Plain (no TLS) is only for this machine or a home / private network:
/// private and link-local IPv4, Tailscale (100.64.0.0/10), a name with no dot
/// ("nas") or ending in ".local", IPv6 loopback / unique-local / link-local.
bool _plainAllowed(String h) {
  if (h.startsWith('[') && h.endsWith(']')) {
    final a = InternetAddress.tryParse(h.substring(1, h.length - 1));
    if (a == null || a.type != InternetAddressType.IPv6) return false;
    final b = a.rawAddress;
    return a.isLoopback || (b[0] & 0xfe) == 0xfc || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80);
  }
  final v4 = _ipv4.firstMatch(h);
  if (v4 == null) return !h.contains('.') || h.endsWith('.local');
  final a = int.parse(v4.group(1)!), b = int.parse(v4.group(2)!);
  return a == 127 ||
      a == 10 ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168) ||
      (a == 100 && b >= 64 && b <= 127) ||
      (a == 169 && b == 254);
}

/// Typed or scanned text → the WebSocket URL, or null if it isn't a
/// server address.
String? normalizeServerInput(String raw) {
  var s = raw.trim();
  if (s.toLowerCase().startsWith(kServerQrPrefix)) s = s.substring(kServerQrPrefix.length).trim();
  if (s.isEmpty || s.contains(RegExp(r'\s'))) return null;
  if (!s.contains('://')) s = 'https://$s';
  final Uri u;
  try {
    u = Uri.parse(s);
  } catch (_) {
    return null;
  }
  final scheme = switch (u.scheme.toLowerCase()) {
    'https' || 'wss' => 'wss',
    'http' || 'ws' => 'ws',
    _ => null,
  };
  if (scheme == null || u.userInfo.isNotEmpty || u.hasQuery || u.hasFragment) return null;
  final host = u.host.toLowerCase();
  final bracketed = host.contains(':') ? '[$host]' : host;
  if (!_validHost(bracketed)) return null;
  if (scheme == 'ws' && !_plainAllowed(bracketed)) return null;
  if (u.hasPort && (u.port < 1 || u.port > 65535)) return null;
  // Only the server's root or its sync endpoint — not some page on it.
  final path = u.path;
  if (path.isNotEmpty && path != '/' && path != '/v1/sync' && path != '/v1/sync/') return null;
  final port = u.hasPort ? ':${u.port}' : '';
  return '$scheme://$bracketed$port/v1/sync';
}

/// `wss://host/v1/sync` → `https://host` (what HTTP calls use).
String httpBaseOf(String wsUrl) {
  var u = wsUrl;
  if (u.startsWith('wss://')) {
    u = 'https://${u.substring(6)}';
  } else if (u.startsWith('ws://')) {
    u = 'http://${u.substring(5)}';
  }
  final scheme = u.indexOf('://');
  if (scheme < 0) return u; // not a URL (empty: no server chosen yet)
  final slash = u.indexOf('/', scheme + 3);
  return slash >= 0 ? u.substring(0, slash) : u;
}

/// `wss://host:port/v1/sync` → `host:port` (what the person typed, for
/// display). Empty when no server is chosen yet.
String serverHostOf(String wsUrl) {
  final base = httpBaseOf(wsUrl);
  final scheme = base.indexOf('://');
  return scheme < 0 ? base : base.substring(scheme + 3);
}

/// What a server answered on `/_healthz`.
enum ServerCheck { ok, notSinhron, unreachable }

/// GET [url] → (status, body), or throws. A seam for tests.
typedef HttpGet = Future<(int, String)> Function(Uri url);

Future<(int, String)> _get(Uri url) async {
  // ADR-072 — the server the person typed is ours: checked address / DoH.
  try {
    core.netDnsAddOurHost(url: url.toString());
  } catch (_) {}
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.getUrl(url).timeout(const Duration(seconds: 8));
    final res = await req.close().timeout(const Duration(seconds: 8));
    final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 8));
    return (res.statusCode, body);
  } finally {
    client.close(force: true);
  }
}

final serverHttpGetProvider = Provider<HttpGet>((ref) => _get);

/// Is there a Sinhron server at [wsUrl]? `/_healthz` must say so.
Future<ServerCheck> checkServer(String wsUrl, {HttpGet get = _get}) async {
  try {
    final (status, body) = await get(Uri.parse('${httpBaseOf(wsUrl)}/_healthz'));
    if (status != 200) return ServerCheck.notSinhron;
    final json = jsonDecode(body);
    return json is Map && json['service'] == 'sinhron-server' ? ServerCheck.ok : ServerCheck.notSinhron;
  } on FormatException {
    return ServerCheck.notSinhron; // answered, but not with our JSON
  } catch (_) {
    return ServerCheck.unreachable;
  }
}
