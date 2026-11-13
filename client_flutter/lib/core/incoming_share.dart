// ADR-060 — sharing into Sinhron from another app's share menu (photos,
// videos, files, links, text), like Telegram / WhatsApp.
//
//   Android  ShareActivity (ACTION_SEND / SEND_MULTIPLE) copies each item
//            into the app's cache (`share/<id>/`) and hands it to
//            MainActivity → `dev.sinhron/share`.
//   iPhone   the Share Extension (ios/ShareExtension, no Rust, no database)
//            copies the items into the App Group (`Share/<id>/`), writes
//            `share.json` and opens `sinhron://share?id=…`.
//
// Dart → `takeInitial()` (a share that started the app before Dart
// listened), `finished(id)` (delete its files); native → `share(map)`.
// The picker ("Send to…") is features/share_into; the route is
// `handleIncomingShare` in app/navigation.dart. Nothing is sent before the
// person picks a chat — and the app lock covers the picker as it covers
// everything else.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One file another app shared (already a local copy the app may read and
/// delete).
class SharedFile {
  const SharedFile({required this.path, required this.name, required this.mimeType, this.size = 0});
  final String path;
  final String name;
  final String mimeType;
  final int size;

  static SharedFile? fromMap(Object? m) {
    if (m is! Map) return null;
    final path = m['path'];
    if (path is! String || path.isEmpty) return null;
    final name = m['name'];
    final mime = m['mime'];
    final size = m['size'];
    return SharedFile(
      path: path,
      name: name is String && name.isNotEmpty ? name : path.split('/').last,
      mimeType: mime is String && mime.isNotEmpty ? mime : 'application/octet-stream',
      size: size is int ? size : 0,
    );
  }
}

/// What came in through the share menu: files and / or text (a link, a
/// note, a page title with its address).
class IncomingShare {
  const IncomingShare({required this.id, this.files = const [], this.text = ''});
  final String id;
  final List<SharedFile> files;
  final String text;

  bool get isEmpty => files.isEmpty && text.trim().isEmpty;

  static IncomingShare? fromMap(Object? m) {
    if (m is! Map) return null;
    final id = m['id'];
    if (id is! String || id.isEmpty) return null;
    final files = m['files'];
    final text = m['text'];
    return IncomingShare(
      id: id,
      files: [
        if (files is List)
          for (final f in files) ?SharedFile.fromMap(f),
      ],
      text: text is String ? text : '',
    );
  }
}

/// How a shared file goes out.
enum SharedKind { photo, video, document }

/// Photos only in what the core re-encodes (JPEG / PNG — the extension and
/// Android turn HEIC / WebP into JPEG first); a GIF stays a file so it keeps
/// moving.
SharedKind sharedKindOf(SharedFile f) {
  final m = f.mimeType.toLowerCase();
  if (m == 'image/jpeg' || m == 'image/jpg' || m == 'image/png') return SharedKind.photo;
  if (m.startsWith('video/')) return SharedKind.video;
  return SharedKind.document;
}

/// The native side (faked in tests).
abstract class SharePlatform {
  /// A share that started the app before Dart listened, once.
  Future<IncomingShare?> takeInitial();

  /// Shares while the app runs.
  Stream<IncomingShare> get shares;

  /// Done with it (sent or cancelled): its copies are deleted.
  Future<void> finished(String id);
}

class ChannelSharePlatform implements SharePlatform {
  ChannelSharePlatform() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'share') return false;
      final s = IncomingShare.fromMap(call.arguments);
      if (s != null) _shares.add(s);
      return true;
    });
  }

  static const _channel = MethodChannel('dev.sinhron/share');
  final _shares = StreamController<IncomingShare>.broadcast();

  @override
  Stream<IncomingShare> get shares => _shares.stream;

  @override
  Future<IncomingShare?> takeInitial() async {
    try {
      return IncomingShare.fromMap(await _channel.invokeMethod<Object?>('takeInitial'));
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> finished(String id) async {
    try {
      await _channel.invokeMethod<void>('finished', id);
    } on MissingPluginException {
      // no native side (tests, desktop)
    } on PlatformException {
      // the files are swept on the next start anyway
    }
  }
}

final sharePlatformProvider = Provider<SharePlatform>((ref) => ChannelSharePlatform());

/// Delete the local copies of [share] (also when native cleanup fails) and
/// tell the native side it's done.
Future<void> finishShare(SharePlatform platform, IncomingShare share) async {
  for (final f in share.files) {
    try {
      await File(f.path).delete();
    } catch (_) {}
  }
  await platform.finished(share.id);
}

/// Mounted once at the app root: hands every share (and the one that
/// started the app) to [onShare], each once. Renders nothing.
class IncomingShareListener extends ConsumerStatefulWidget {
  const IncomingShareListener({super.key, required this.child, required this.onShare});
  final Widget child;
  final void Function(IncomingShare share) onShare;

  @override
  ConsumerState<IncomingShareListener> createState() => _IncomingShareListenerState();
}

class _IncomingShareListenerState extends ConsumerState<IncomingShareListener> {
  StreamSubscription<IncomingShare>? _sub;
  final _seen = <String>{};

  void _deliver(IncomingShare s) {
    // The same share can arrive twice (cold start + the live event).
    if (!_seen.add(s.id)) return;
    widget.onShare(s);
  }

  @override
  void initState() {
    super.initState();
    final platform = ref.read(sharePlatformProvider);
    _sub = platform.shares.listen(_deliver);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final first = await platform.takeInitial();
      if (first != null && mounted) _deliver(first);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
