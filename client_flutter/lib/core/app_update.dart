// ADR-058 — the Android app updates itself from our server (it isn't in a
// store, so nothing else would update it).
//
//   1. On start (after a short pause) and every few hours, and from
//      Settings → About → "Check for updates": GET
//      <server>/download/android.json — {version, build, notes,
//      apks: {abi: {url, sha256, size}}}, written by
//      scripts/android_release.sh, uploaded by scripts/publish_android.sh.
//   2. Newer build than ours → a calm banner over Chats (UpdateBanner).
//   3. "Update" → the APK for this phone's CPU (same bitness as the one
//      installed) downloads in the background with progress, into
//      cacheDir/updates/.
//   4. Before installing: its SHA-256 equals the manifest's, and Android
//      reads the file itself — package com.sinhron.sinhron, a higher
//      version code than ours, signed with OUR certificate
//      ([kApkCertSha256]). Any mismatch → the file is deleted, never
//      installed.
//   5. The system installer opens; Android always asks for one "Install"
//      tap (the first time also "allow from this source").
// Never on iOS (TestFlight / App Store update the app), never in dev builds
// (no build number), never when a store installed us, never when this
// build isn't signed with our key (Android would refuse the update anyway).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'push_server.dart' show isAndroidProvider;
import 'server_address.dart';
import 'services/net_service.dart';

/// SHA-256 of our Android release signing certificate (lower-case hex, no
/// colons) — 6F:04:86:35:…:69:18. `scripts/android_release.sh` refuses to
/// write a manifest for an APK signed with anything else.
const kApkCertSha256 = '6f048635c6991fe6bb3a4084e44af39fb31d63162aa75bdd5c8c8b8a6c6a6918';

const kAndroidPackage = 'com.sinhron.sinhron';

/// Where the manifest lives on a server.
const kUpdateManifestPath = '/download/android.json';

/// Biggest APK taken (real ones are 41-60 MB): a server can't fill the
/// phone by announcing any size (security-review-2026-11 app-surface:7).
const kMaxApkBytes = 200 << 20;

/// How often a running app looks again.
const kUpdateCheckEvery = Duration(hours: 6);

/// The first look after start: the connection comes first.
const kUpdateFirstCheckAfter = Duration(seconds: 30);

/// Installers that are stores: they update the app themselves.
const _storeInstallers = {
  'com.android.vending', // Google Play
  'com.sec.android.app.samsungapps', // Galaxy Store
  'ru.vk.store', // RuStore
  'com.huawei.appmarket', // AppGallery
  'com.xiaomi.market',
  'com.xiaomi.mipicks', // GetApps
  'com.heytap.market', // OPPO / realme
  'com.oppo.market',
  'com.bbk.appstore', // vivo
  'com.amazon.venezia', // Amazon Appstore
  'org.fdroid.fdroid', // F-Droid
  'com.aurora.store',
  'dev.imranr.obtainium', // Obtainium (updates from GitHub Releases)
};

/// Did a store install this app? null / a package installer / a browser /
/// a file manager = an APK we gave — ours to update.
bool installedFromStore(String? installer) => installer != null && _storeInstallers.contains(installer);

/// One APK in the manifest.
class ApkFile {
  const ApkFile({required this.url, required this.sha256, required this.size});

  final Uri url;

  /// Lower-case hex.
  final String sha256;
  final int size;
}

/// What android.json announces.
class AndroidRelease {
  const AndroidRelease({required this.version, required this.build, required this.apks, this.notes = ''});

  final String version;
  final int build;
  final String notes;

  /// By ABI ("arm64-v8a", "armeabi-v7a", "x86_64").
  final Map<String, ApkFile> apks;
}

final _hex64 = RegExp(r'^[0-9a-f]{64}$');

/// android.json → the release, or null when it isn't one. Relative APK
/// URLs are resolved against [manifestUrl]; an APK must come over https
/// (plain http only when the manifest itself is plain http — a test server
/// on a LAN). Broken entries are skipped.
AndroidRelease? parseAndroidRelease(String body, Uri manifestUrl) {
  Object? j;
  try {
    j = jsonDecode(body);
  } on FormatException {
    return null;
  }
  if (j is! Map) return null;
  final version = j['version'];
  final rawBuild = j['build'];
  final build = rawBuild is int ? rawBuild : (rawBuild is String ? int.tryParse(rawBuild) : null);
  final apks = j['apks'];
  if (version is! String || build == null || build <= 0 || apks is! Map) return null;
  // Audit U02 — the card shows these: a version is digits and dots, notes are short.
  if (!RegExp(r'^\d{1,4}(\.\d{1,4}){1,3}$').hasMatch(version.trim())) return null;
  final out = <String, ApkFile>{};
  for (final MapEntry(:key, :value) in apks.entries) {
    if (key is! String || value is! Map) continue;
    final url = value['url'];
    final sha = value['sha256'];
    final size = value['size'];
    if (url is! String || sha is! String || size is! int || size <= 0 || size > kMaxApkBytes) continue;
    final hash = sha.trim().toLowerCase();
    if (!_hex64.hasMatch(hash)) continue;
    final Uri resolved;
    try {
      resolved = manifestUrl.resolve(url.trim());
    } on FormatException {
      continue;
    }
    final okScheme = resolved.scheme == 'https' || (resolved.scheme == 'http' && manifestUrl.scheme == 'http');
    if (!okScheme || resolved.host.isEmpty) continue;
    out[key] = ApkFile(url: resolved, sha256: hash, size: size);
  }
  if (out.isEmpty) return null;
  final raw = j['notes'];
  final notes = raw is String ? String.fromCharCodes(raw.trim().runes.take(200)) : '';
  return AndroidRelease(version: version.trim(), build: build, notes: notes, apks: out);
}

/// Is [remote] a newer build than this one ([local] = `SINHRON_BUILD`)?
/// A dev build (no number) never updates.
bool isNewerBuild(int remote, String local) {
  final mine = int.tryParse(local.trim());
  return mine != null && remote > mine;
}

const _abis64 = {'arm64-v8a', 'x86_64'};

/// The APK for this phone: the first of [supported] (the phone's ABIs, best
/// first) the release has, of the same bitness as the app running now —
/// going from the 32-bit APK to the 64-bit one can look like a downgrade
/// to Android (split APK version codes differ by 1000 per CPU type).
String? pickAbi({required List<String> supported, required bool is64, required Iterable<String> available}) {
  final have = available.toSet();
  for (final abi in supported) {
    if (have.contains(abi) && _abis64.contains(abi) == is64) return abi;
  }
  return null;
}

/// What Android said about this app.
class UpdateHostInfo {
  const UpdateHostInfo({
    required this.installer,
    required this.abis,
    required this.is64,
    required this.versionCode,
    required this.certs,
    required this.canInstall,
  });

  final String? installer;
  final List<String> abis;
  final bool is64;
  final int versionCode;

  /// SHA-256s of the certificates this app is signed with.
  final List<String> certs;
  final bool canInstall;
}

/// What Android read from a downloaded APK.
class ApkInfo {
  const ApkInfo({required this.packageName, required this.versionCode, required this.certs});

  final String packageName;
  final int versionCode;
  final List<String> certs;
}

/// Why a downloaded file mustn't be installed.
enum ApkProblem {
  /// Not the bytes the manifest named (broken download, or swapped).
  hash,

  /// Android couldn't read it as an app.
  unreadable,

  /// Another app.
  package,

  /// Not signed with our key.
  signature,

  /// Not newer than what's installed (Android would refuse it).
  notNewer,
}

/// The checks before the installer opens; null = safe to install.
ApkProblem? checkApk({
  required String expectedSha256,
  required String actualSha256,
  required ApkInfo? info,
  required int installedVersionCode,
  String package = kAndroidPackage,
  String cert = kApkCertSha256,
}) {
  if (actualSha256.toLowerCase() != expectedSha256.toLowerCase()) return ApkProblem.hash;
  if (info == null) return ApkProblem.unreadable;
  if (info.packageName != package) return ApkProblem.package;
  if (!info.certs.map((c) => c.toLowerCase()).contains(cert)) return ApkProblem.signature;
  if (info.versionCode <= installedVersionCode) return ApkProblem.notNewer;
  return null;
}

/// Can this install update itself at all?
bool selfUpdateAllowed({required bool android, required String build, required UpdateHostInfo? host}) =>
    android &&
    int.tryParse(build.trim()) != null &&
    host != null &&
    !installedFromStore(host.installer) &&
    host.certs.map((c) => c.toLowerCase()).contains(kApkCertSha256);

/// The Android side (`dev.sinhron/update`, AppUpdate.kt). A seam for tests.
class UpdatePlatform {
  const UpdatePlatform();

  static const _ch = MethodChannel('dev.sinhron/update');

  Future<UpdateHostInfo?> info() async {
    final m = await _ch.invokeMapMethod<String, Object?>('info');
    if (m == null) return null;
    return UpdateHostInfo(
      installer: m['installer'] as String?,
      abis: [for (final a in (m['abis'] as List?) ?? const []) if (a is String) a],
      is64: m['is64'] == true,
      versionCode: (m['versionCode'] as num?)?.toInt() ?? 0,
      certs: [for (final c in (m['certs'] as List?) ?? const []) if (c is String) c],
      canInstall: m['canInstall'] == true,
    );
  }

  Future<ApkInfo?> inspect(String path) async {
    final m = await _ch.invokeMapMethod<String, Object?>('inspect', {'path': path});
    if (m == null) return null;
    return ApkInfo(
      packageName: m['packageName'] as String? ?? '',
      versionCode: (m['versionCode'] as num?)?.toInt() ?? 0,
      certs: [for (final c in (m['certs'] as List?) ?? const []) if (c is String) c],
    );
  }

  Future<bool> canInstall() async => await _ch.invokeMethod<bool>('canInstall') ?? false;

  Future<bool> openInstallSettings() async => await _ch.invokeMethod<bool>('openInstallSettings') ?? false;

  Future<bool> install(String path) async => await _ch.invokeMethod<bool>('install', {'path': path}) ?? false;
}

final updatePlatformProvider = Provider<UpdatePlatform>((ref) => const UpdatePlatform());

/// Download [url] into [to], reporting (bytes so far, total or -1).
typedef ApkDownload = Future<void> Function(Uri url, File to, void Function(int got, int total) progress);

Future<void> _download(Uri url, File to, void Function(int got, int total) progress) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final part = File('${to.path}.part');
  try {
    final req = await client.getUrl(url).timeout(const Duration(seconds: 20));
    final res = await req.close().timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: url);
    final total = res.contentLength;
    final sink = part.openWrite();
    var got = 0;
    try {
      // A minute without a byte = the connection is gone.
      await for (final chunk in res.timeout(const Duration(seconds: 60))) {
        sink.add(chunk);
        got += chunk.length;
        progress(got, total);
      }
    } finally {
      await sink.close();
    }
    await part.rename(to.path);
  } finally {
    client.close(force: true);
    if (part.existsSync()) part.deleteSync();
  }
}

final apkDownloadProvider = Provider<ApkDownload>((ref) => _download);

/// The folder for update files (cacheDir/updates — the only one
/// UpdateFileProvider shares with the installer).
final updateDirProvider = Provider<Future<Directory>>((ref) async {
  final d = Directory('${(await getTemporaryDirectory()).path}/updates');
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
});

/// SHA-256 of a file, lower-case hex.
Future<String> sha256OfFile(File f) async => (await crypto.sha256.bind(f.openRead()).first).toString();

enum UpdatePhase {
  /// Nothing to show (not checked yet, or no updates for this install).
  idle,
  checking,
  upToDate,
  available,
  downloading,
  ready,
  failed,
}

/// Why it failed: no connection / server, or a file that failed the checks.
enum UpdateFailure { offline, badFile, installer }

class UpdateState {
  const UpdateState({
    this.phase = UpdatePhase.idle,
    this.release,
    this.progress = 0,
    this.failure,
    this.dismissed = false,
    this.manual = false,
  });

  final UpdatePhase phase;
  final AndroidRelease? release;

  /// 0..1 while downloading (0 when the size is unknown).
  final double progress;
  final UpdateFailure? failure;

  /// "Later" on the banner: hidden until the app starts again.
  final bool dismissed;

  /// The person asked (Settings) — say "up to date" / "offline" then.
  final bool manual;

  /// The banner over Chats.
  bool get showBanner =>
      !dismissed &&
      release != null &&
      (phase == UpdatePhase.available ||
          phase == UpdatePhase.downloading ||
          phase == UpdatePhase.ready ||
          phase == UpdatePhase.failed);

  UpdateState copyWith({
    UpdatePhase? phase,
    AndroidRelease? release,
    double? progress,
    UpdateFailure? failure,
    bool clearFailure = false,
    bool? dismissed,
    bool? manual,
  }) => UpdateState(
    phase: phase ?? this.phase,
    release: release ?? this.release,
    progress: progress ?? this.progress,
    failure: clearFailure ? null : (failure ?? this.failure),
    dismissed: dismissed ?? this.dismissed,
    manual: manual ?? this.manual,
  );
}

/// The build this app is — the same `--dart-define=SINHRON_BUILD` as
/// `kAppBuild` in Settings (empty in dev builds); overridable in tests.
final appBuildProvider = Provider<String>((ref) => const String.fromEnvironment('SINHRON_BUILD'));

/// Android's facts about this install, asked once.
final updateHostProvider = FutureProvider<UpdateHostInfo?>((ref) async {
  if (!ref.watch(isAndroidProvider)) return null;
  try {
    return await ref.watch(updatePlatformProvider).info();
  } catch (_) {
    return null;
  }
});

/// Does this install update itself (Android, our APK, our key)?
final selfUpdateSupportedProvider = FutureProvider<bool>((ref) async {
  final host = await ref.watch(updateHostProvider.future);
  return selfUpdateAllowed(android: ref.watch(isAndroidProvider), build: ref.watch(appBuildProvider), host: host);
});

class AppUpdateController extends Notifier<UpdateState> {
  Timer? _timer;
  bool _started = false;
  String? _apkPath;
  String? _abi;

  @override
  UpdateState build() {
    ref.onDispose(() => _timer?.cancel());
    return const UpdateState();
  }

  /// Looks shortly after start, then every [kUpdateCheckEvery]. Safe to call
  /// more than once.
  void startAutoCheck() {
    // Nothing to look for off Android or in a dev build (no timer either).
    if (_started || !ref.read(isAndroidProvider) || int.tryParse(ref.read(appBuildProvider)) == null) return;
    _started = true;
    _timer = Timer(kUpdateFirstCheckAfter, () {
      unawaited(check());
      _timer = Timer.periodic(kUpdateCheckEvery, (_) => unawaited(check()));
    });
  }

  /// Fetch the manifest. [manual]: the person tapped "Check for updates".
  Future<void> check({bool manual = false}) async {
    final s = state.phase;
    if (s == UpdatePhase.checking || s == UpdatePhase.downloading) return;
    if (!manual && s == UpdatePhase.ready) return;
    if (!await ref.read(selfUpdateSupportedProvider.future)) return;
    final base = ref.read(netServiceProvider).httpBaseUrl;
    if (base == null || base.isEmpty) {
      if (manual) state = state.copyWith(phase: UpdatePhase.failed, failure: UpdateFailure.offline, manual: true);
      return;
    }
    final before = state;
    state = state.copyWith(phase: UpdatePhase.checking, manual: manual, clearFailure: true);
    final url = Uri.parse('$base$kUpdateManifestPath');
    AndroidRelease? rel;
    try {
      final (status, body) = await ref.read(serverHttpGetProvider)(url);
      if (status == 200) rel = parseAndroidRelease(body, url);
      if (status != 200 && status != 404) throw HttpException('HTTP $status');
    } catch (_) {
      // A quiet look that failed changes nothing on screen.
      state = manual
          ? before.copyWith(phase: UpdatePhase.failed, failure: UpdateFailure.offline, manual: true)
          : before;
      return;
    }
    final host = await ref.read(updateHostProvider.future);
    final abi = rel == null || host == null ? null : pickAbi(supported: host.abis, is64: host.is64, available: rel.apks.keys);
    if (rel == null || abi == null || !isNewerBuild(rel.build, ref.read(appBuildProvider))) {
      unawaited(_cleanUp(keep: null));
      state = UpdateState(phase: UpdatePhase.upToDate, manual: manual);
      return;
    }
    final same = before.release?.build == rel.build;
    _abi = abi;
    state = UpdateState(
      phase: same && before.phase == UpdatePhase.ready ? UpdatePhase.ready : UpdatePhase.available,
      release: rel,
      manual: manual,
      // A newer build than the one put off brings the banner back.
      dismissed: same && before.dismissed && !manual,
    );
  }

  /// "Update": download, check, then open the installer.
  Future<void> download() async {
    final rel = state.release;
    final abi = _abi;
    if (rel == null || abi == null || state.phase == UpdatePhase.downloading) return;
    final apk = rel.apks[abi]!;
    state = state.copyWith(phase: UpdatePhase.downloading, progress: 0, clearFailure: true);
    final dir = await ref.read(updateDirProvider);
    final file = File('${dir.path}/sinhron-${rel.build}-$abi.apk');
    await _cleanUp(keep: file.path);
    try {
      final have = file.existsSync() && file.lengthSync() == apk.size && await sha256OfFile(file) == apk.sha256;
      if (!have) {
        if (file.existsSync()) file.deleteSync();
        await ref.read(apkDownloadProvider)(apk.url, file, (got, total) {
          // More than announced: stop now, not after the disk is full.
          if (got > apk.size || (total > 0 && total != apk.size)) throw const HttpException('size mismatch');
          final all = total > 0 ? total : apk.size;
          final p = (got / all).clamp(0.0, 1.0);
          // Whole percents only: a 60 MB file is ~1000 chunks.
          if ((p * 100).floor() != (state.progress * 100).floor()) state = state.copyWith(progress: p);
        });
      }
    } catch (_) {
      state = state.copyWith(phase: UpdatePhase.failed, failure: UpdateFailure.offline);
      return;
    }
    final platform = ref.read(updatePlatformProvider);
    final host = await ref.read(updateHostProvider.future);
    ApkInfo? info;
    try {
      info = await platform.inspect(file.path);
    } catch (_) {
      info = null;
    }
    final problem = checkApk(
      expectedSha256: apk.sha256,
      actualSha256: await sha256OfFile(file),
      info: info,
      installedVersionCode: host?.versionCode ?? 0,
    );
    if (problem != null) {
      if (file.existsSync()) file.deleteSync();
      state = state.copyWith(phase: UpdatePhase.failed, failure: UpdateFailure.badFile);
      return;
    }
    _apkPath = file.path;
    state = state.copyWith(phase: UpdatePhase.ready, progress: 1);
  }

  /// May Sinhron install apps already? If not, the UI explains first what
  /// Android will ask.
  Future<bool> canInstall() async {
    try {
      return await ref.read(updatePlatformProvider).canInstall();
    } catch (_) {
      return false;
    }
  }

  /// The system installer for the checked file.
  Future<void> install() async {
    final path = _apkPath;
    if (state.phase != UpdatePhase.ready || path == null || !File(path).existsSync()) {
      state = state.copyWith(phase: UpdatePhase.available);
      return;
    }
    bool ok;
    try {
      ok = await ref.read(updatePlatformProvider).install(path);
    } catch (_) {
      ok = false;
    }
    if (!ok) state = state.copyWith(phase: UpdatePhase.failed, failure: UpdateFailure.installer);
  }

  /// "Later": hide the banner until the app starts again.
  void dismiss() => state = state.copyWith(dismissed: true);

  /// Delete old update files (an installed update, a stale download).
  Future<void> _cleanUp({required String? keep}) async {
    try {
      final dir = await ref.read(updateDirProvider);
      for (final f in dir.listSync()) {
        if (f is File && f.path != keep) f.deleteSync();
      }
    } catch (_) {}
  }
}

final appUpdateProvider = NotifierProvider<AppUpdateController, UpdateState>(AppUpdateController.new);
