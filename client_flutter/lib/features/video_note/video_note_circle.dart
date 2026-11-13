// Round video messages ("кружки") — ADR-048. The one shape a round video
// is ever shown in.
//
// Privacy (owner, 2026-10-19): the person recording sees only the circle,
// so nothing outside it may ever be drawn — not the square's corners, not
// the edges of an old clip that went out uncropped (until 0.6.0 a failed
// crop sent the camera's whole frame). The chat bubble, the "Media & files"
// grid, the gallery's strip, its page and the Hero flight between them all
// draw a round video through [VideoNoteCircle]; the gallery offers no
// share / "Save to Photos" for it (the file may hold more than the circle).

import 'package:flutter/widgets.dart';

import '../../app/theme/palette.dart';

/// Is this stored media JSON a round video? (Rust writes `"round":true`
/// only for those — ADR-048.)
bool isVideoNoteJson(String? mediaJson) => mediaJson != null && mediaJson.contains('"round":true');

/// The largest circle that fits the box, centred, with [child] filling the
/// square around it (give it a cover-fitted picture). Nothing outside the
/// circle is painted.
class VideoNoteCircle extends StatelessWidget {
  const VideoNoteCircle({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
    child: AspectRatio(
      aspectRatio: 1,
      child: ClipOval(
        child: ColoredBox(
          color: DsPalette.art1C1E24,
          child: SizedBox.expand(child: child),
        ),
      ),
    ),
  );
}
