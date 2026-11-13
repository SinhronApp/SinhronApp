// ADR-072 — our server's address when the phone's DNS answers wrong.
//
// The Rust core checks the system answer for our hosts (a TLS handshake
// with our certificate) and falls back to DNS-over-HTTPS / a remembered
// address (`sinhron_net::dns`). Its own connections (API, WebSocket, media,
// push registration) use that directly. This file does the same for the
// connections Dart makes itself: LiveKit's signalling WebSocket and its
// `/rtc/validate`, the APK update download, the server check — every
// `HttpClient` in the app, through `HttpOverrides.global`.
//
// For one of our hosts whose system answer failed the check, the TCP
// connection goes to the checked address and TLS still runs with our host
// name (SNI + certificate check) — a wrong certificate is refused exactly
// as before. Any other host, or when the system answer is fine: the usual
// connection.
//
// What this can't reach: WebRTC's own lookups (TURN hosts — Rust adds the
// checked address to the plain `turn:` URLs; `turns:` needs the name).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// The address to connect to instead of the system answer for [host], or
/// null to resolve as usual (Rust: `net_dns_override`).
typedef DnsOverride = Future<String?> Function(String host, int port);

class ServerDnsOverrides extends HttpOverrides {
  ServerDnsOverrides(this.lookup, {@visibleForTesting this.testContext});

  final DnsOverride lookup;

  /// Trust for clients made without a context (tests: the test CA).
  final SecurityContext? testContext;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final ctx = context ?? testContext;
    final client = super.createHttpClient(ctx);
    client.connectionFactory = (uri, proxyHost, proxyPort) =>
        connectVia(uri, proxyHost, proxyPort, lookup: lookup, context: ctx);
    return client;
  }
}

/// The connection `HttpClient` asks for. Direct https: a [SecureSocket] (the
/// client doesn't add TLS itself when a factory is set).
@visibleForTesting
Future<ConnectionTask<Socket>> connectVia(
  Uri uri,
  String? proxyHost,
  int? proxyPort, {
  required DnsOverride lookup,
  SecurityContext? context,
}) async {
  // Through a proxy the client makes the tunnel and its TLS.
  if (proxyHost != null && proxyPort != null) return Socket.startConnect(proxyHost, proxyPort);
  final secure = uri.isScheme('https') || uri.isScheme('wss');
  // Port 0 = the default: WebSocket.connect turns `wss://host/…` into
  // `https://host:0/…` (0.8.1 connected to port 0 — no call signalling,
  // every call failed; status 189).
  final port = uri.hasPort && uri.port != 0 ? uri.port : (secure ? 443 : 80);
  if (!secure) return Socket.startConnect(uri.host, port);
  String? ip;
  if (InternetAddress.tryParse(uri.host) == null) {
    try {
      ip = await lookup(uri.host, port).timeout(const Duration(seconds: 25));
    } catch (_) {
      ip = null; // the usual connection
    }
  }
  if (ip == null || ip.isEmpty) return SecureSocket.startConnect(uri.host, port, context: context);
  final tcp = await Socket.startConnect(ip, port);
  return ConnectionTask.fromSocket(
    tcp.socket.then((s) => SecureSocket.secure(s, host: uri.host, context: context)),
    tcp.cancel,
  );
}
