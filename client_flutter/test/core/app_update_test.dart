// ADR-058 — the Android app updates itself from our server: the manifest,
// which build is newer, which APK fits the phone, and the checks before the
// system installer opens (SHA-256, package, our signing certificate).

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/app_update.dart';
import 'package:sinhron/core/push_server.dart';
import 'package:sinhron/core/server_address.dart';
import 'package:sinhron/core/services/net_service.dart';
import 'package:sinhron/features/app_update/update_banner.dart';

class _Net extends NetService {
  _Net(super.ref);
  @override
  String? get httpBaseUrl => 'https://srv';
}

class FakeUpdatePlatform extends UpdatePlatform {
  String? installer;
  bool is64 = true;
  List<String> abis = ['arm64-v8a', 'armeabi-v7a', 'armeabi'];
  List<String> ownCerts = [kApkCertSha256];
  ApkInfo? apk = const ApkInfo(packageName: kAndroidPackage, versionCode: 2026101902 + 2000, certs: [kApkCertSha256]);
  bool allowed = true;
  final installed = <String>[];

  @override
  Future<UpdateHostInfo?> info() async => UpdateHostInfo(
    installer: installer,
    abis: abis,
    is64: is64,
    versionCode: 2026101800 + 2000,
    certs: ownCerts,
    canInstall: allowed,
  );

  @override
  Future<ApkInfo?> inspect(String path) async => apk;

  @override
  Future<bool> canInstall() async => allowed;

  @override
  Future<bool> install(String path) async {
    installed.add(path);
    return true;
  }
}

String _sha(List<int> b) => crypto.sha256.convert(b).toString();

String _manifest({int build = 2026101902, String? sha, List<int> bytes = const [1, 2, 3]}) => jsonEncode({
  'version': '0.6.0',
  'build': build,
  'notes': '',
  'apks': {
    'arm64-v8a': {'url': 'sinhron-0.6.0-$build-arm64-v8a.apk', 'sha256': sha ?? _sha(bytes), 'size': bytes.length},
    'armeabi-v7a': {'url': 'sinhron-0.6.0-$build-armeabi-v7a.apk', 'sha256': sha ?? _sha(bytes), 'size': bytes.length},
  },
});

void main() {
  group('android.json', () {
    final at = Uri.parse('https://chat.example.org/download/android.json');

    test('a release with relative APK names', () {
      final r = parseAndroidRelease(_manifest(), at)!;
      expect(r.version, '0.6.0');
      expect(r.build, 2026101902);
      expect(r.apks.keys, ['arm64-v8a', 'armeabi-v7a']);
      expect(r.apks['arm64-v8a']!.url, Uri.parse('https://chat.example.org/download/sinhron-0.6.0-2026101902-arm64-v8a.apk'));
      expect(r.apks['arm64-v8a']!.size, 3);
    });

    test('broken entries are skipped; nothing usable = no release', () {
      final good = _sha([1]);
      final body = jsonEncode({
        'version': '0.6.0',
        'build': '2026101902', // a string number is fine
        'apks': {
          'arm64-v8a': {'url': 'a.apk', 'sha256': good.toUpperCase(), 'size': 1},
          'armeabi-v7a': {'url': 'http://evil.example/b.apk', 'sha256': good, 'size': 1}, // not https
          'x86_64': {'url': 'c.apk', 'sha256': 'abc', 'size': 1}, // not a SHA-256
          'x86': {'url': 'd.apk', 'sha256': good}, // no size
        },
      });
      final r = parseAndroidRelease(body, at)!;
      expect(r.build, 2026101902);
      expect(r.apks.keys, ['arm64-v8a']);
      expect(r.apks['arm64-v8a']!.sha256, good);
      expect(parseAndroidRelease('<html>', at), isNull);
      expect(parseAndroidRelease('{"version":"1","build":0,"apks":{}}', at), isNull);
      expect(parseAndroidRelease('{"version":"1","build":5,"apks":{}}', at), isNull);
      expect(parseAndroidRelease('[]', at), isNull);
    });

    test('audit U02 — the server cannot write its own text into the card', () {
      Map<String, dynamic> m() => jsonDecode(_manifest()) as Map<String, dynamic>;
      expect(parseAndroidRelease(jsonEncode(m()..['version'] = 'Send your 24 words to the admin'), at), isNull);
      final r = parseAndroidRelease(jsonEncode(m()..['notes'] = 'x\n' * 5000), at)!;
      expect(r.notes.length, lessThanOrEqualTo(200));
    });

    test('plain http only from a plain-http server (a LAN test box)', () {
      final lan = Uri.parse('http://192.168.1.5:8080/download/android.json');
      expect(parseAndroidRelease(_manifest(), lan)!.apks['arm64-v8a']!.url.scheme, 'http');
    });
  });

  test('which build is newer', () {
    expect(isNewerBuild(2026101902, '2026101800'), isTrue);
    expect(isNewerBuild(2026101800, '2026101800'), isFalse);
    expect(isNewerBuild(2026101700, '2026101800'), isFalse);
    // Dev builds (no number) never update themselves.
    expect(isNewerBuild(2026101902, ''), isFalse);
  });

  test('the APK for this phone keeps the bitness of the app running now', () {
    const both = ['arm64-v8a', 'armeabi-v7a'];
    expect(pickAbi(supported: ['arm64-v8a', 'armeabi-v7a', 'armeabi'], is64: true, available: both), 'arm64-v8a');
    // The 32-bit APK on a 64-bit phone stays 32-bit (else Android may see a downgrade).
    expect(pickAbi(supported: ['arm64-v8a', 'armeabi-v7a', 'armeabi'], is64: false, available: both), 'armeabi-v7a');
    expect(pickAbi(supported: ['armeabi-v7a', 'armeabi'], is64: false, available: both), 'armeabi-v7a');
    expect(pickAbi(supported: ['x86_64'], is64: true, available: both), isNull);
  });

  test('a store installed us → the store updates the app', () {
    expect(installedFromStore('com.android.vending'), isTrue);
    expect(installedFromStore('ru.vk.store'), isTrue);
    expect(installedFromStore('com.sec.android.app.samsungapps'), isTrue);
    expect(installedFromStore(null), isFalse);
    expect(installedFromStore('com.google.android.packageinstaller'), isFalse);
    expect(installedFromStore('com.android.chrome'), isFalse);
  });

  test('the checks before installing', () {
    final sha = _sha([1, 2, 3]);
    const ok = ApkInfo(packageName: kAndroidPackage, versionCode: 200, certs: [kApkCertSha256]);
    ApkProblem? check({String? actual, ApkInfo? info = ok, int installed = 100}) => checkApk(
      expectedSha256: sha,
      actualSha256: actual ?? sha,
      info: info,
      installedVersionCode: installed,
    );
    expect(check(), isNull);
    expect(check(actual: sha.toUpperCase()), isNull);
    expect(check(actual: _sha([9])), ApkProblem.hash);
    expect(check(info: null), ApkProblem.unreadable);
    expect(
      check(info: const ApkInfo(packageName: 'com.evil', versionCode: 200, certs: [kApkCertSha256])),
      ApkProblem.package,
    );
    expect(
      check(info: ApkInfo(packageName: kAndroidPackage, versionCode: 200, certs: ['00' * 32])),
      ApkProblem.signature,
    );
    expect(
      check(info: ApkInfo(packageName: kAndroidPackage, versionCode: 200, certs: [kApkCertSha256.toUpperCase()])),
      isNull,
    );
    expect(check(installed: 200), ApkProblem.notNewer);
  });

  test('who may update itself', () {
    UpdateHostInfo host({String? installer, List<String> certs = const [kApkCertSha256]}) => UpdateHostInfo(
      installer: installer,
      abis: const ['arm64-v8a'],
      is64: true,
      versionCode: 1,
      certs: certs,
      canInstall: false,
    );
    expect(selfUpdateAllowed(android: true, build: '2026101800', host: host()), isTrue);
    expect(selfUpdateAllowed(android: false, build: '2026101800', host: host()), isFalse);
    expect(selfUpdateAllowed(android: true, build: '', host: host()), isFalse);
    expect(selfUpdateAllowed(android: true, build: '2026101800', host: null), isFalse);
    expect(selfUpdateAllowed(android: true, build: '2026101800', host: host(installer: 'com.android.vending')), isFalse);
    // A debug-signed build: Android would refuse our update anyway.
    expect(selfUpdateAllowed(android: true, build: '2026101800', host: host(certs: ['ab' * 32])), isFalse);
  });

  group('check → download → install', () {
    late Directory dir;
    late FakeUpdatePlatform platform;
    late List<Uri> asked;
    late List<Uri> fetched;
    late String manifest;
    late List<int> served;

    ProviderContainer container({bool android = true, String build = '2026101800', ApkDownload? download}) {
      final c = ProviderContainer(
        overrides: [
          isAndroidProvider.overrideWithValue(android),
          appBuildProvider.overrideWithValue(build),
          netServiceProvider.overrideWith((ref) => _Net(ref)),
          updatePlatformProvider.overrideWithValue(platform),
          updateDirProvider.overrideWithValue(Future.value(dir)),
          serverHttpGetProvider.overrideWithValue((u) async {
            asked.add(u);
            return (200, manifest);
          }),
          apkDownloadProvider.overrideWithValue(
            download ??
                (u, to, progress) async {
            fetched.add(u);
            progress(1, served.length);
            await to.writeAsBytes(served);
            progress(served.length, served.length);
          }),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    setUp(() {
      dir = Directory.systemTemp.createTempSync('sinhron-update-');
      addTearDown(() => dir.deleteSync(recursive: true));
      platform = FakeUpdatePlatform();
      asked = [];
      fetched = [];
      served = [1, 2, 3];
      manifest = _manifest(bytes: served);
    });

    test('a newer build: download, check, open the installer', () async {
      final c = container();
      final ctl = c.read(appUpdateProvider.notifier);
      await ctl.check();
      expect(asked, [Uri.parse('https://srv/download/android.json')]);
      var s = c.read(appUpdateProvider);
      expect(s.phase, UpdatePhase.available);
      expect(s.release!.version, '0.6.0');
      expect(s.showBanner, isTrue);

      await ctl.download();
      s = c.read(appUpdateProvider);
      expect(s.phase, UpdatePhase.ready);
      expect(fetched.single.path, '/download/sinhron-0.6.0-2026101902-arm64-v8a.apk');
      await ctl.install();
      expect(platform.installed.single, '${dir.path}/sinhron-2026101902-arm64-v8a.apk');
    });

    test('the 32-bit app gets the 32-bit APK', () async {
      platform.is64 = false;
      final c = container();
      final ctl = c.read(appUpdateProvider.notifier);
      await ctl.check();
      await ctl.download();
      expect(fetched.single.path, endsWith('armeabi-v7a.apk'));
    });

    // security-review-2026-11 app-surface:7.
    test('a server streaming more than it announced is cut off, not left to fill the disk', () async {
      var got = 0;
      final c = container(
        download: (u, to, progress) async {
          for (got = 1024; got <= 100 << 20; got += 1024) {
            progress(got, -1);
          }
        },
      );
      final ctl = c.read(appUpdateProvider.notifier);
      await ctl.check();
      await ctl.download();
      expect(got, 1024, reason: 'stopped at the first chunk past 3 bytes');
      expect(c.read(appUpdateProvider).phase, UpdatePhase.failed);
      expect(platform.installed, isEmpty);
      final absurd = jsonEncode(jsonDecode(manifest)..['apks']['arm64-v8a']['size'] = 1 << 40);
      expect(parseAndroidRelease(absurd, Uri.parse('https://srv/a.json'))!.apks.keys, ['armeabi-v7a'], reason: 'an absurd size is no APK');
    });

    test('bytes that don\'t match the manifest are deleted, never installed', () async {
      manifest = _manifest(sha: _sha([7, 7, 7]), bytes: served);
      final c = container();
      final ctl = c.read(appUpdateProvider.notifier);
      await ctl.check();
      await ctl.download();
      final s = c.read(appUpdateProvider);
      expect(s.phase, UpdatePhase.failed);
      expect(s.failure, UpdateFailure.badFile);
      expect(dir.listSync(), isEmpty);
      await ctl.install();
      expect(platform.installed, isEmpty);
    });

    test('an APK signed by someone else is refused', () async {
      platform.apk = ApkInfo(packageName: kAndroidPackage, versionCode: 2026103000, certs: ['cd' * 32]);
      final c = container();
      final ctl = c.read(appUpdateProvider.notifier);
      await ctl.check();
      await ctl.download();
      expect(c.read(appUpdateProvider).failure, UpdateFailure.badFile);
      expect(platform.installed, isEmpty);
    });

    test('same build or older: up to date, no banner', () async {
      manifest = _manifest(build: 2026101800);
      final c = container();
      await c.read(appUpdateProvider.notifier).check(manual: true);
      final s = c.read(appUpdateProvider);
      expect(s.phase, UpdatePhase.upToDate);
      expect(s.showBanner, isFalse);
    });

    test('installed from a store, off Android, or a dev build: never asks', () async {
      platform.installer = 'com.android.vending';
      await container().read(appUpdateProvider.notifier).check(manual: true);
      platform.installer = null;
      await container(android: false).read(appUpdateProvider.notifier).check(manual: true);
      await container(build: '').read(appUpdateProvider.notifier).check(manual: true);
      expect(asked, isEmpty);
    });

    test('offline: a quiet look changes nothing, a tapped one says so', () async {
      final c = ProviderContainer(
        overrides: [
          isAndroidProvider.overrideWithValue(true),
          appBuildProvider.overrideWithValue('2026101800'),
          netServiceProvider.overrideWith((ref) => _Net(ref)),
          updatePlatformProvider.overrideWithValue(platform),
          updateDirProvider.overrideWithValue(Future.value(dir)),
          serverHttpGetProvider.overrideWithValue((u) async => throw const SocketException('down')),
        ],
      );
      addTearDown(c.dispose);
      final ctl = c.read(appUpdateProvider.notifier);
      await ctl.check();
      expect(c.read(appUpdateProvider).phase, UpdatePhase.idle);
      await ctl.check(manual: true);
      expect(c.read(appUpdateProvider).failure, UpdateFailure.offline);
    });

    test('"Later" hides the banner; a newer build brings it back', () async {
      final c = container();
      final ctl = c.read(appUpdateProvider.notifier);
      await ctl.check();
      ctl.dismiss();
      expect(c.read(appUpdateProvider).showBanner, isFalse);
      await ctl.check();
      expect(c.read(appUpdateProvider).showBanner, isFalse);
      manifest = _manifest(build: 2026102000);
      await ctl.check();
      expect(c.read(appUpdateProvider).showBanner, isTrue);
    });

    testWidgets('the banner: Update → first time, explain what Android asks → installer', (t) async {
      platform.allowed = false;
      final c = container();
      await t.runAsync(() => c.read(appUpdateProvider.notifier).check());
      t.view.physicalSize = const Size(390, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: DsTheme(
            tokens: DsTokens.light,
            isDark: false,
            child: const MediaQuery(
              data: MediaQueryData(size: Size(390, 800)),
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: Navigator(onGenerateRoute: _route),
              ),
            ),
          ),
        ),
      );
      await t.pump();
      expect(find.text('Update 0.6.0 is available'), findsOneWidget);
      expect(find.textContaining('Android asks you to tap Install'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('update-action')));
      final explain = find.textContaining('Allow from this source');
      for (var i = 0; i < 40 && explain.evaluate().isEmpty; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump(const Duration(milliseconds: 100));
      }
      await t.pumpAndSettle();
      expect(c.read(appUpdateProvider).phase, UpdatePhase.ready);
      expect(explain, findsOneWidget);
      expect(platform.installed, isEmpty);
      await t.tap(find.text('Continue'));
      await t.pumpAndSettle();
      expect(platform.installed, hasLength(1));
      // The auto-check timer of a real phone is running; stop it.
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('"Later" hides it', (t) async {
      final c = container();
      await t.runAsync(() => c.read(appUpdateProvider.notifier).check());
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: DsTheme(
            tokens: DsTokens.light,
            isDark: false,
            child: const Directionality(textDirection: TextDirection.ltr, child: UpdateBanner()),
          ),
        ),
      );
      await t.pump();
      expect(find.byKey(const ValueKey('update-banner')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('update-later')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('update-banner')), findsNothing);
      // The auto-check timer of a real phone is running; stop it.
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });
  });
}

Route<void> _route(RouteSettings s) =>
    PageRouteBuilder(pageBuilder: (_, _, _) => const Column(children: [UpdateBanner()]));
