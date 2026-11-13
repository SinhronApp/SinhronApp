// Live call video — tech-debt 4.9. The call screen used placeholder art
// only; this renders the LiveKit room: every remote participant's camera
// in a grid (1 → full screen, 2 → stacked, 3-4 → 2×2, more → 3 columns)
// and our own camera for the picture-in-picture. Participants without
// video show their initials from the identity key.

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../../core/providers/people.dart';
import 'active_call_provider.dart' show participantMicMuted;
import 'call_screen.dart' show CallMicOffBadge, CallPeerAvatar, kCallBarClearance, kCallTopClearance;

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';

/// Rebuilds whenever the room changes (people join, tracks arrive, someone
/// starts speaking or mutes). A LiveKit identity is the person's identity
/// key, so tiles show their name and photo from the people store.
class CallVideoGrid extends ConsumerWidget {
  const CallVideoGrid({super.key, required this.room, this.waitingLabel});
  final lk.Room room;

  /// Shown while nobody else is in the room (a group call still ringing).
  final String? waitingLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final names = ref.watch(peerNamesProvider).value ?? const <String, String>{};
    final photos = ref.watch(peerAvatarsProvider).value ?? const <String, Uint8List>{};
    return ListenableBuilder(
      listenable: room,
      builder: (context, _) {
        final people = room.remoteParticipants.values.toList()..sort((a, b) => a.identity.compareTo(b.identity));
        if (people.isEmpty) {
          return waitingLabel == null
              ? const SizedBox.expand()
              : Center(
                  key: const ValueKey('call-waiting'),
                  child: Text(waitingLabel!, style: DsTextArt.t14w500),
                );
        }
        final tiles = [
          for (final p in people)
            CallTile(
              key: ValueKey(p.identity),
              name: displayNameOf(p.identity, names),
              photo: photos[p.identity],
              // The camera; a shared screen shows big on its own (ADR-061).
              video: p.videoTrackPublications
                  .where((t) => t.source == lk.TrackSource.camera && t.subscribed && !t.muted)
                  .firstOrNull
                  ?.track,
              speaking: p.isSpeaking,
              // Their microphone (a shared screen's sound isn't it).
              micOff: participantMicMuted(p) ?? true,
              compact: people.length > 1,
            ),
        ];
        if (tiles.length == 1) return tiles.first;
        // Several tiles: between the top row and the button bar, so no name
        // hides under them (owner, 2026-10-19).
        final pad = MediaQuery.paddingOf(context);
        return Padding(
          padding: EdgeInsets.fromLTRB(
            pad.left + DsSpace.x1,
            pad.top + kCallTopClearance,
            pad.right + DsSpace.x1,
            pad.bottom + kCallBarClearance,
          ),
          child: _layout(tiles),
        );
      },
    );
  }

  /// Columns for `n` people: 1 → 1 (full screen), 2 → 1 (stacked),
  /// 3-4 → 2, more → 3.
  static int columnsFor(int n) => n <= 2 ? 1 : (n <= 4 ? 2 : 3);

  static Widget _layout(List<Widget> tiles) {
    final n = tiles.length;
    if (n == 1) return tiles.first;
    final cols = columnsFor(n);
    final rows = <Widget>[];
    for (var i = 0; i < n; i += cols) {
      final row = tiles.sublist(i, (i + cols).clamp(0, n));
      rows.add(
        Expanded(
          child: Row(
            children: [
              for (final t in row)
                Expanded(
                  child: Padding(padding: const EdgeInsets.all(DsSpace.nudge1), child: t),
                ),
              for (var k = row.length; k < cols; k++) const Expanded(child: SizedBox()),
            ],
          ),
        ),
      );
    }
    return Column(children: rows);
  }
}

/// One person in the call: their camera, or their photo / initials; their
/// name (several on screen); a green ring while they speak; a crossed mic
/// when they're muted.
class CallTile extends StatelessWidget {
  const CallTile({
    super.key,
    required this.name,
    this.photo,
    this.video,
    this.speaking = false,
    this.micOff = false,
    this.compact = false,
  });
  final String name;
  final Uint8List? photo;
  final lk.VideoTrack? video;
  final bool speaking;
  final bool micOff;

  /// Several tiles on screen: smaller avatar, name label on the tile.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: DsPalette.navy,
        borderRadius: BorderRadius.circular(compact ? 14 : 0),
        border: speaking ? Border.all(color: tokens.success, width: 3) : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (video != null)
            lk.VideoTrackRenderer(video!, fit: lk.VideoViewFit.cover)
          else
            Center(
              // Alone on screen, no name tag: the crossed mic sits on their
              // photo (a 1:1 video call with their camera off).
              child: CallPeerAvatar(name: name, photo: photo, size: compact ? 64 : 120, micOff: micOff && !compact),
            ),
          // A name tag on each of several tiles. Alone on the screen (a 1:1
          // call) there's none: the name sat at the very bottom edge, under
          // the buttons, like a stray label (owner, 2026-10-19).
          if (compact)
            Positioned(
              left: 6,
              bottom: 6,
              right: 6,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(DsSpace.x1, DsSpace.x0h5, DsSpace.x2, DsSpace.x0h5),
                  decoration: BoxDecoration(color: DsPalette.black40, borderRadius: BorderRadius.circular(999)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (micOff)
                        const CallMicOffBadge(key: ValueKey('tile-mic-off'))
                      else
                        const SizedBox(width: DsSpace.x1),
                      const SizedBox(width: DsSpace.x1),
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DsTextArt.t13w600Mono.copyWith(fontFamily: null),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Our own camera for the picture-in-picture (mirrored like a mirror).
class CallSelfView extends StatelessWidget {
  const CallSelfView({super.key, required this.room});
  final lk.Room room;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: room,
      builder: (context, _) {
        final track = room.localParticipant?.videoTrackPublications
            .where((t) => t.source == lk.TrackSource.camera)
            .firstOrNull
            ?.track;
        if (track == null) return const ColoredBox(color: DsPalette.navy);
        return lk.VideoTrackRenderer(track, fit: lk.VideoViewFit.cover, mirrorMode: lk.VideoViewMirrorMode.mirror);
      },
    );
  }
}
