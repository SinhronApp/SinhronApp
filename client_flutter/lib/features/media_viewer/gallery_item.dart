// One photo or video of the chat gallery (photo_gallery_screen.dart).

class GalleryItem {
  const GalleryItem({
    required this.mediaJson,
    required this.heroTag,
    this.caption = '',
    this.sender = '',
    this.date = '',
    this.isVideo = false,
    this.round = false,
    this.rowId,
    this.wireId,
    this.isMine = false,
    this.sentTs,
  });

  final String mediaJson;
  final Object heroTag;
  final String caption;

  /// "You" / "Maria" and "Apr 28 · 14:22" — the top bar under "3 of 27".
  final String sender;
  final String date;

  final bool isVideo;

  /// A round video message (ADR-048): shown only as a circle, never the
  /// whole frame; no share / "Save to Photos" (owner, 2026-10-19).
  final bool round;

  /// Stored row / wire id: delete, forward and "show in chat" need them.
  final String? rowId;
  final String? wireId;
  final bool isMine;

  /// Unix seconds it was sent — delete-for-everyone window.
  final int? sentTs;

  /// e.g. "Maria · 14:22".
  String get subtitle => [sender, date].where((s) => s.isNotEmpty).join(' · ');
}
