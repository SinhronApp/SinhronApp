// Linked devices — ADR-025. The person's devices as the server lists
// them; revoking goes through NetService (it serializes with device sync).

import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api/simple.dart' as core;
import '../services/net_service.dart';
import 'settings_providers.dart' show SettingsStore, settingsStoreProvider;

/// Our devices. Errors when offline (the screen says so).
final linkedDevicesProvider = FutureProvider.autoDispose<List<core.LinkedDevice>>(
  (ref) => ref.read(netServiceProvider).listDevices(),
);

/// ADR-027 — false on a QR-paired device (no account key): it can't add
/// or revoke devices.
final accountKeyHereProvider = FutureProvider.autoDispose<bool>((ref) => ref.read(netServiceProvider).hasAccountKey());

/// The server knows devices only by key, so the list showed a code
/// (owner, 2026-11-01). Each device names itself ("iPhone 16 Pro",
/// "iPad Air", "Galaxy S23") in this setting; settings with this prefix
/// sync to my other devices end-to-end (`devsync::SYNCED_PREFIXES`).
String deviceNameKey(String devicePkHex) => 'device_name:${devicePkHex.toLowerCase()}';

/// The name [devicePkHex] gave itself, null until it has.
final deviceNameProvider = FutureProvider.autoDispose.family<String?, String>((ref, devicePkHex) async {
  try {
    final v = await ref.read(settingsStoreProvider).get(deviceNameKey(devicePkHex));
    return v == null || v.trim().isEmpty ? null : v;
  } catch (_) {
    return null;
  }
});

/// This device's model as people know it.
Future<String> thisDeviceName() async {
  try {
    if (Platform.isIOS) {
      final i = await DeviceInfoPlugin().iosInfo;
      return i.modelName.trim().isNotEmpty ? i.modelName : i.model;
    }
    if (Platform.isAndroid) {
      final a = await DeviceInfoPlugin().androidInfo;
      return a.name.trim().isNotEmpty ? a.name : '${a.manufacturer} ${a.model}'.trim();
    }
  } catch (_) {}
  return Platform.operatingSystem;
}

bool _announced = false;

@visibleForTesting
void resetDeviceNameAnnounced() => _announced = false;

/// Once a run, after connecting: write this device's name under its key
/// (only when it changed — each write is a sync item for my devices).
Future<void> announceDeviceName(
  NetService net,
  SettingsStore settings, {
  Future<String> Function() name = thisDeviceName,
}) async {
  if (_announced) return;
  final me = (await net.listDevices()).where((d) => d.isThisDevice).firstOrNull;
  if (me == null) return;
  final key = deviceNameKey(me.devicePkHex);
  final mine = await name();
  if (await settings.get(key) != mine) await settings.set(key, mine);
  _announced = true;
}
