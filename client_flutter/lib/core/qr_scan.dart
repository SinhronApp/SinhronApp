// Camera QR scanning — the native scanner in AppDelegate.swift
// (`QRScannerViewController`, channel `dev.sinhron/qrscan`). Used to link a
// device (ADR-027) and to verify a safety number by scanning the other
// person's screen (tech-debt 2.27).

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Camera → the QR's text, or null (closed, no camera, no permission).
typedef QrScanner = Future<String?> Function();

const _channel = MethodChannel('dev.sinhron/qrscan');

Future<String?> scanQrWithCamera() async {
  try {
    return await _channel.invokeMethod<String>('scan');
  } on MissingPluginException {
    return null; // desktop / tests
  } on PlatformException {
    return null; // camera denied
  }
}

final qrScannerProvider = Provider<QrScanner>((ref) => scanQrWithCamera);
