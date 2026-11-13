// QR pairing of a new device — tech-debt 4.2 / ADR-025.
//
// New device: `offer(deviceSeed)` → QR text (with its own device key);
// `wait()` polls the server until the other device answers → a
// linked-device bundle (`sinhron-linked:v1:…`): certificate for its key +
// what it needs to receive — never the identity key (ADR-027).
// Existing device (one holding the account key): scans the QR (`scanQr`,
// native camera, channel `dev.sinhron/qrscan`) or takes a pasted code,
// then `send()` signs the certificate, seals the bundle to the QR's
// one-time key (Rust, HPKE) and leaves it on the server.

import 'server_address.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/rust/api/simple.dart' as core;
import 'qr_scan.dart';

/// The account secret in device-key form (ADR-021).
const kAccountSecretPrefix = 'sinhron-device-key:v1:';

/// ADR-027 — a QR-paired device's bundle (no identity key).
const kLinkedBundlePrefix = 'sinhron-linked:v1:';

/// A secret that isn't a phrase: the device key, or a linked bundle.
bool isAccountSecret(String s) => s.startsWith(kAccountSecretPrefix) || s.startsWith(kLinkedBundlePrefix);

/// Pairing failed because this device holds no account key (it was
/// itself paired by QR) — only a device where the 24 words were entered
/// can add devices.
bool isNoAccountKeyError(Object e) => e.toString().contains('no account key');

/// The server's 409 "already used" (ADR-091): another device answered
/// or took this pairing code first.
bool isPairingUsedError(Object e) => e.toString().contains('server 409');

/// `ws://host:port/v1/sync` → `http://host:port`.
String httpBaseFromWs(String wsUrl) => httpBaseOf(wsUrl);

/// Pairing calls — the Rust FFI in the app, fakes in tests.
class PairingOps {
  const PairingOps({
    required this.offer,
    required this.wait,
    required this.cancel,
    required this.isCode,
    required this.send,
    required this.sendWithPhrase,
    required this.scanQr,
  });

  /// [deviceSeedHex] — the new device's own key (kept in its Keychain).
  final Future<String> Function(String deviceSeedHex) offer;
  final Future<String?> Function(String httpBase, int timeoutSecs) wait;
  final void Function() cancel;
  final Future<bool> Function(String text) isCode;
  final Future<void> Function(String httpBase, String code) send;

  /// ADR-027 — the same from a device without the account key: the 24
  /// words authorize it (this call only).
  final Future<void> Function(String httpBase, String code, String phrase) sendWithPhrase;

  /// Camera → the QR's text, or null (closed, no camera, no permission).
  final Future<String?> Function() scanQr;

  static final ffi = PairingOps(
    offer: (seed) async => core.pairingOfferNew(deviceSeedHex: seed),
    wait: (base, secs) => core.pairingWait(serverBaseUrl: base, timeoutSecs: secs),
    cancel: () {
      try {
        core.pairingCancel().catchError((_) {});
      } catch (_) {}
    },
    isCode: (t) => core.pairingIsCode(text: t),
    send: (base, code) => core.pairingSend(serverBaseUrl: base, qrText: code),
    sendWithPhrase: (base, code, phrase) =>
        core.pairingSendWithPhrase(serverBaseUrl: base, qrText: code, phrase: phrase),
    scanQr: scanQrWithCamera, // camera denied → the paste field is there
  );
}

final pairingOpsProvider = Provider<PairingOps>((ref) => PairingOps.ffi);
