// ADR-060 — what the "Send to…" picker does with a share: the chat's own
// send paths (sendPhoto / sendVideo / sendDocument / text), so a shared
// item is encrypted, padded and shown "Sending…" / "Not sent — tap to
// retry" in the chat exactly like one picked inside the chat.

import 'dart:async';
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/incoming_share.dart';
import '../../core/providers/chat_providers.dart';
import '../../core/providers/message_actions.dart' show newWireId;
import '../../core/providers/saved_messages.dart';
import '../../core/services/net_service.dart';
import '../../core/services/video_tools.dart';
import '../documents/document_share.dart' show mimeTypeForFileName;

/// A video ready to go: bytes (compressed when large), poster, metadata.
typedef SharedVideo = ({PreparedVideo video, int durationMs, int width, int height});

/// One share, prepared once and sent to every picked chat: each file is read
/// into memory the first time (a video compressed, its copy deleted), so a
/// second chat — or "try again" — doesn't read it again.
class ShareParcel {
  ShareParcel(this.share);
  final IncomingShare share;
  final _bytes = <String, Uint8List>{};
  final _videos = <String, SharedVideo>{};
  bool _sizesChecked = false;

  /// Photos and files over [kMaxMediaBytes] can't go (videos are compressed
  /// first): refused before anything is sent.
  Future<void> checkSizes() async {
    if (_sizesChecked) return;
    for (final f in share.files) {
      if (sharedKindOf(f) == SharedKind.video || _bytes.containsKey(f.path)) continue;
      int size;
      try {
        size = await File(f.path).length();
      } catch (_) {
        size = f.size;
      }
      if (size > kMaxMediaBytes) throw ArgumentError('${f.name} is larger than ${kMaxMediaBytes ~/ (1024 * 1024)} MB');
    }
    _sizesChecked = true;
  }

  Future<Uint8List> bytes(SharedFile f) async => _bytes[f.path] ??= await File(f.path).readAsBytes();

  Future<SharedVideo> video(SharedFile f, VideoTools tools) async {
    final have = _videos[f.path];
    if (have != null) return have;
    var durationMs = 0, width = 0, height = 0;
    final probe = VideoPlayerController.file(File(f.path));
    try {
      await probe.initialize();
      durationMs = probe.value.duration.inMilliseconds;
      width = probe.value.size.width.round();
      height = probe.value.size.height.round();
    } catch (_) {
      // Unknown metadata is fine — the bubble just shows less.
    } finally {
      await probe.dispose();
    }
    // Throws VideoTooLarge; deletes the copy either way.
    final v = await prepareVideoForSending(tools, f.path);
    return _videos[f.path] = (video: v, durationMs: durationMs, width: width, height: height);
  }
}

/// Send [parcel] to one chat with [caption] (on the first file, or the text
/// itself when nothing else was shared). Returns the chat's real id (Saved
/// messages is made on first use). Throws before anything goes out when it
/// can't be sent at all; media then runs in the background like any send.
typedef ShareSend = Future<String> Function(WidgetRef ref, ShareParcel parcel, String chatId, String caption);

final shareSendProvider = Provider<ShareSend>((ref) => sendShareToChat);

Future<String> sendShareToChat(WidgetRef ref, ShareParcel parcel, String chatId, String caption) async {
  final net = ref.read(netServiceProvider);
  final saved = ref.read(savedMessagesProvider);
  final tools = ref.read(videoToolsProvider);
  final files = parcel.share.files;
  await parcel.checkSizes();
  // Opened from the share menu: the connection may still be coming up.
  if (files.isNotEmpty && net.status != NetStatus.connected) {
    await net.waitConnected(const Duration(seconds: 15));
  }
  final to = await saved.resolve(chatId);
  var text = caption.trim();
  if (files.isEmpty) {
    if (text.isNotEmpty) await sendMessage(ref, chatId: to, body: text);
    return to;
  }
  // Several photos travel as one album (one grid bubble), as from the chat.
  final photos = files.where((f) => sharedKindOf(f) == SharedKind.photo).length;
  final albumId = photos > 1 ? newWireId() : '';
  for (final f in files) {
    final c = text;
    text = '';
    switch (sharedKindOf(f)) {
      case SharedKind.photo:
        final bytes = await parcel.bytes(f);
        unawaited(sendPhoto(ref, chatId: to, bytes: bytes, caption: c, albumId: albumId));
      case SharedKind.video:
        final v = await parcel.video(f, tools);
        unawaited(
          sendVideo(
            ref,
            chatId: to,
            bytes: v.video.bytes,
            mimeType: v.video.mimeType,
            durationMs: v.durationMs,
            width: v.width,
            height: v.height,
            poster: v.video.poster,
            caption: c,
          ),
        );
      case SharedKind.document:
        final bytes = await parcel.bytes(f);
        final generic = f.mimeType == 'application/octet-stream';
        unawaited(
          sendDocument(
            ref,
            chatId: to,
            bytes: bytes,
            fileName: f.name,
            mimeType: generic ? mimeTypeForFileName(f.name) : f.mimeType,
            caption: c,
          ),
        );
    }
  }
  return to;
}
