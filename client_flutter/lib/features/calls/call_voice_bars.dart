// The other side's voice as five soft bars under their photo (owner,
// 2026-10-18: "bars that jump to the tone, like an equalizer — cheap, and
// not tiring").
//
// LiveKit reports each speaker's level a few times a second (the server's
// speaker updates — no audio analysis on the phone). Between reports every
// bar eases toward its share of the level with a slow sway of its own, so
// the row moves with the voice without flicker. Cheap: five rounded boxes,
// redrawn at most ~30 times a second and only while there is sound — in
// silence the bars settle low and the ticker stops (no frames at all).
// Reduce Motion: no sway, the bars just step with the level.

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/widgets.dart';

import '../../app/theme/motion.dart';
import '../../app/theme/palette.dart';

class CallVoiceBars extends StatefulWidget {
  const CallVoiceBars({super.key, required this.level, this.color = DsPalette.white, this.height = 28});

  /// 0..1 — the other side's voice (LiveKit `audioLevel`), 0 in silence.
  final ValueListenable<double> level;
  final Color color;
  final double height;

  /// Each bar's share of the level (middle tallest) and sway speed.
  static const shape = [0.55, 0.8, 1.0, 0.8, 0.55];
  static const _sway = [5.1, 7.3, 6.2, 8.1, 5.7];

  /// Heights 0..1 for a [level] at [seconds] — pure, for tests. Quiet → a
  /// low resting line; speech → up to full height, swaying ±25 %.
  static List<double> heightsFor(double level, double seconds, {bool sway = true}) {
    final l = math.sqrt(level.clamp(0.0, 1.0)); // speech sits low on LiveKit's scale
    return [
      for (var i = 0; i < shape.length; i++)
        _rest + (1 - _rest) * (l * shape[i] * (sway ? 0.75 + 0.25 * math.sin(seconds * _sway[i] + i * 1.3) : 1)).clamp(0.0, 1.0),
    ];
  }

  static const _rest = 0.16;

  @override
  State<CallVoiceBars> createState() => _CallVoiceBarsState();
}

class _CallVoiceBarsState extends State<CallVoiceBars> with SingleTickerProviderStateMixin {
  Ticker? _ticker; // made on the first sound
  List<double> _h = CallVoiceBars.heightsFor(0, 0);
  double _level = 0; // smoothed: quick up, slow down
  Duration _lastPaint = Duration.zero;
  bool _reduced = false;

  @override
  void initState() {
    super.initState();
    widget.level.addListener(_onLevel);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = DsMotion.reduced(context);
    _onLevel(); // a voice already there when the bars appear
  }

  @override
  void didUpdateWidget(CallVoiceBars old) {
    super.didUpdateWidget(old);
    if (old.level != widget.level) {
      old.level.removeListener(_onLevel);
      widget.level.addListener(_onLevel);
      _onLevel();
    }
  }

  @override
  void dispose() {
    widget.level.removeListener(_onLevel);
    _ticker?.dispose();
    super.dispose();
  }

  void _onLevel() {
    if (_reduced) {
      setState(() => _h = CallVoiceBars.heightsFor(widget.level.value, 0, sway: false));
      return;
    }
    final ticker = _ticker ??= createTicker(_tick);
    if (!ticker.isActive && (widget.level.value > 0 || _level > 0.001)) ticker.start();
  }

  void _tick(Duration elapsed) {
    // ~30 fps is plenty for a level meter.
    if (elapsed - _lastPaint < const Duration(milliseconds: 33)) return;
    _lastPaint = elapsed;
    final target = widget.level.value;
    _level += (target - _level) * (target > _level ? 0.45 : 0.12);
    final goal = CallVoiceBars.heightsFor(_level, elapsed.inMilliseconds / 1000);
    var moving = false;
    final next = [
      for (var i = 0; i < _h.length; i++) _h[i] + (goal[i] - _h[i]) * 0.35,
    ];
    for (var i = 0; i < next.length; i++) {
      if ((next[i] - goal[i]).abs() > 0.004) moving = true;
    }
    setState(() => _h = next);
    // Silence and settled: stop drawing.
    if (target == 0 && _level < 0.001 && !moving) {
      _level = 0;
      _ticker?.stop();
      _lastPaint = Duration.zero;
    }
  }

  @override
  Widget build(BuildContext context) {
    const w = 5.0, gap = 5.0;
    return ExcludeSemantics(
      child: SizedBox(
        key: const ValueKey('call-voice-bars'),
        height: widget.height,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (var i = 0; i < _h.length; i++) ...[
              if (i > 0) const SizedBox(width: gap),
              Container(
                width: w,
                height: math.max(w, widget.height * _h[i]),
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: 0.3 + 0.7 * _h[i]),
                  borderRadius: BorderRadius.circular(w / 2),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
