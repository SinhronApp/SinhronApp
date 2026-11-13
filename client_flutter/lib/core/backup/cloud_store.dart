// ADR-073 — where the chat backup lives: the person's own cloud.
//
//   iPhone  — iCloud Drive, the app's own hidden container
//             (`iCloud.com.sinhron.sinhron/Documents/Backup`): nothing to set
//             up when iCloud Drive is on; iOS uploads in its own time (and on
//             Wi-Fi unless "iCloud Drive over mobile data" is on).
//   Android — Google Drive's app data folder (hidden in Drive, only this app
//             sees it) after one "Sign in with Google"; the app uploads
//             itself, on unmetered networks unless asked now.
//
// Files are named by the SHA-256 of their bytes, plus `root.sinhron`. Every
// byte is already encrypted (lib/core/backup/backup_service.dart, Rust
// `sinhron_sync::backup`): Apple and Google keep what they can't read.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform, visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel, MissingPluginException, PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The native side (`dev.sinhron/backup`): iCloud on iPhone, the Google
/// sign-in and network kind on Android.
const backupChannel = MethodChannel('dev.sinhron/backup');

abstract class CloudStore {
  /// "iCloud" / "Google Drive" — for the settings screen.
  String get kind;

  /// Ready to use now (iCloud on and signed in; Google signed in).
  Future<bool> available();

  /// Android: ask the person to pick a Google account (one tap). iPhone:
  /// nothing to do — false when iCloud is off.
  Future<bool> connect();

  /// Signed out / turned off by the person.
  Future<void> disconnect() async {}

  /// Should a scheduled backup wait (mobile data on Android)?
  Future<bool> shouldWaitForWifi() async => false;

  /// Names in the backup folder.
  Future<Set<String>> list();
  Future<void> put(String name, File file);

  /// Into [dest]; false when there is no such file.
  Future<bool> get(String name, File dest);
  Future<void> delete(String name);

  /// Has the cloud taken [name] from this phone yet? (iCloud uploads when
  /// iOS decides — often only on Wi-Fi.) True where the write is the upload.
  Future<bool> uploaded(String name) async => true;
}

Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
  try {
    return await backupChannel.invokeMethod<T>(method, args);
  } on MissingPluginException {
    return null;
  }
}

/// iCloud Drive, the app's container (`BackupBridge` in Swift).
class IcloudStore extends CloudStore {
  @override
  String get kind => 'iCloud';

  @override
  Future<bool> available() async => await _call<bool>('icloudAvailable') ?? false;

  @override
  Future<bool> connect() => available();

  @override
  Future<Set<String>> list() async => {...?(await _call<List<Object?>>('icloudList'))?.whereType<String>()};

  @override
  Future<void> put(String name, File file) async {
    final ok = await _call<bool>('icloudPut', {'name': name, 'path': file.path});
    if (ok != true) throw const FileSystemException('iCloud: not written');
  }

  @override
  Future<bool> get(String name, File dest) async =>
      await _call<bool>('icloudGet', {'name': name, 'path': dest.path}) ?? false;

  @override
  Future<void> delete(String name) async => _call<bool>('icloudDelete', {'name': name});

  @override
  Future<bool> uploaded(String name) async => await _call<bool>('icloudUploaded', {'name': name}) ?? true;
}

/// Google Drive, the app data folder, over its REST API with a token from
/// Google sign-in (`BackupBridge.kt`: `driveToken`).
class DriveStore extends CloudStore {
  DriveStore({HttpClient? http}) : _http = http ?? HttpClient();
  final HttpClient _http;
  String? _token;
  final Map<String, String> _ids = {};

  static const _api = 'https://www.googleapis.com/drive/v3';
  static const _upload = 'https://www.googleapis.com/upload/drive/v3';

  @override
  String get kind => 'Google Drive';

  Future<String?> _getToken({bool interactive = false, bool fresh = false}) async {
    if (!fresh && _token != null) return _token;
    try {
      _token = await backupChannel.invokeMethod<String>('driveToken', {'interactive': interactive});
    } on PlatformException {
      _token = null;
    } on MissingPluginException {
      _token = null;
    }
    return _token;
  }

  @override
  Future<bool> available() async => await _getToken() != null;

  @override
  Future<bool> connect() async => await _getToken(interactive: true, fresh: true) != null;

  @override
  Future<void> disconnect() async {
    _token = null;
    await _call<bool>('driveSignOut');
  }

  @override
  Future<bool> shouldWaitForWifi() async => await _call<bool>('metered') ?? false;

  /// One request with the token; a 401 gets a fresh token once.
  Future<HttpClientResponse> _send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Future<void> Function(HttpClientRequest r)? body,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final token = await _getToken(fresh: attempt > 0);
      if (token == null) throw const HttpException('Google Drive: not signed in');
      final req = await _http.openUrl(method, uri);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      headers.forEach(req.headers.set);
      if (body != null) {
        await body(req);
      }
      final res = await req.close();
      if (res.statusCode == 401 && attempt == 0) {
        await res.drain<void>();
        continue;
      }
      return res;
    }
    throw const HttpException('Google Drive: unauthorized');
  }

  Future<Map<String, Object?>> _json(HttpClientResponse res) async {
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 300) throw HttpException('Google Drive ${res.statusCode}: $text');
    return text.isEmpty ? const {} : (jsonDecode(text) as Map).cast<String, Object?>();
  }

  @override
  Future<Set<String>> list() async {
    _ids.clear();
    String? page;
    do {
      final uri = Uri.parse('$_api/files').replace(
        queryParameters: {
          'spaces': 'appDataFolder',
          'fields': 'nextPageToken,files(id,name)',
          'pageSize': '1000',
          'pageToken': ?page,
        },
      );
      final j = await _json(await _send('GET', uri));
      for (final f in (j['files'] as List? ?? const []).cast<Map>()) {
        _ids[f['name'] as String] = f['id'] as String;
      }
      page = j['nextPageToken'] as String?;
    } while (page != null);
    return _ids.keys.toSet();
  }

  @override
  Future<void> put(String name, File file) async {
    final size = await file.length();
    final existing = _ids[name];
    // Resumable session: works for any size, streamed from the file.
    final start = existing == null
        ? Uri.parse('$_upload/files?uploadType=resumable')
        : Uri.parse('$_upload/files/$existing?uploadType=resumable');
    final meta = existing == null ? {'name': name, 'parents': ['appDataFolder']} : <String, Object?>{};
    final init = await _send(
      existing == null ? 'POST' : 'PATCH',
      start,
      headers: {
        HttpHeaders.contentTypeHeader: 'application/json; charset=UTF-8',
        'X-Upload-Content-Type': 'application/octet-stream',
        'X-Upload-Content-Length': '$size',
      },
      body: (r) async => r.write(jsonEncode(meta)),
    );
    final session = init.headers.value(HttpHeaders.locationHeader);
    await init.drain<void>();
    if (init.statusCode >= 300 || session == null) throw HttpException('Google Drive: upload refused (${init.statusCode})');
    final res = await _send(
      'PUT',
      Uri.parse(session),
      headers: {HttpHeaders.contentLengthHeader: '$size', HttpHeaders.contentTypeHeader: 'application/octet-stream'},
      body: (r) async {
        r.contentLength = size;
        await r.addStream(file.openRead());
      },
    );
    final j = await _json(res);
    if (j['id'] is String) _ids[name] = j['id'] as String;
  }

  @override
  Future<bool> get(String name, File dest) async {
    if (_ids.isEmpty) await list();
    final id = _ids[name];
    if (id == null) return false;
    final res = await _send('GET', Uri.parse('$_api/files/$id?alt=media'));
    if (res.statusCode == 404) {
      await res.drain<void>();
      return false;
    }
    if (res.statusCode >= 300) {
      await res.drain<void>();
      throw HttpException('Google Drive ${res.statusCode}');
    }
    final tmp = File('${dest.path}.part');
    await res.pipe(tmp.openWrite());
    await tmp.rename(dest.path);
    return true;
  }

  @override
  Future<void> delete(String name) async {
    final id = _ids[name];
    if (id == null) return;
    final res = await _send('DELETE', Uri.parse('$_api/files/$id'));
    await res.drain<void>();
    if (res.statusCode < 300 || res.statusCode == 404) _ids.remove(name);
  }
}

/// A folder on this computer — tests and the design gallery.
@visibleForTesting
class DirCloudStore extends CloudStore {
  DirCloudStore(this.dir, {this.connected = true});
  final Directory dir;
  bool connected;

  @override
  String get kind => 'folder';

  @override
  Future<bool> available() async => connected;

  @override
  Future<bool> connect() async => connected = true;

  @override
  Future<Set<String>> list() async {
    if (!await dir.exists()) return {};
    return {
      for (final f in dir.listSync().whereType<File>()) f.uri.pathSegments.last,
    };
  }

  @override
  Future<void> put(String name, File file) async {
    await dir.create(recursive: true);
    await file.copy('${dir.path}/$name');
  }

  @override
  Future<bool> get(String name, File dest) async {
    final f = File('${dir.path}/$name');
    if (!await f.exists()) return false;
    await f.copy(dest.path);
    return true;
  }

  @override
  Future<void> delete(String name) async {
    final f = File('${dir.path}/$name');
    if (await f.exists()) await f.delete();
  }
}

/// This phone's cloud (none on desktop).
final cloudStoreProvider = Provider<CloudStore?>((ref) {
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS => IcloudStore(),
    TargetPlatform.android => DriveStore(),
    _ => null,
  };
});
