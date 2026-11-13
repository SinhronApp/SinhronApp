// A small spinning arc — "working on it" (the chat list's "Connecting…").

import 'package:flutter/widgets.dart';

class DsSpinner extends StatefulWidget {
  const DsSpinner({super.key, required this.color, this.size = 18});
  final Color color;
  final double size;

  @override
  State<DsSpinner> createState() => _DsSpinnerState();
}

class _DsSpinnerState extends State<DsSpinner> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))
    ..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: _ctrl,
    child: CustomPaint(
      painter: _ArcPainter(widget.color),
      size: Size.square(widget.size),
    ),
  );
}

class _ArcPainter extends CustomPainter {
  _ArcPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final r = Rect.fromCircle(center: size.center(Offset.zero), radius: size.width / 2 - 1.5);
    canvas.drawArc(r, -1.5707963, 4.712389, false, paint);
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.color != color;
}
