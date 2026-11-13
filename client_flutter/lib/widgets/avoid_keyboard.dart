// The keyboard never covers a field or a button (2026-10-16 UI audit: on
// every screen but the chat it slid over "Continue", the name field, the
// "type DELETE" box…). The app is a bare WidgetsApp — no Scaffold to do
// this — so the root does it once for every route: the screen shrinks to
// the space above the keyboard, the way iOS apps behave, and the screens
// below see no keyboard inset (nobody pads twice).

import 'package:flutter/widgets.dart';

import '../app/theme/tokens.dart';

class AvoidKeyboard extends StatelessWidget {
  const AvoidKeyboard({super.key, required this.child});
  final Widget child;

  /// The keyboard's height the last time it was up — the chat's emoji
  /// panel takes the same place.
  static double lastKeyboard = 0;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final keyboard = mq.viewInsets.bottom;
    if (keyboard > 200) lastKeyboard = keyboard;
    return ColoredBox(
      color: DsTheme.of(context).bg,
      child: Padding(
        padding: EdgeInsets.only(bottom: keyboard),
        child: MediaQuery(data: mq.removeViewInsets(removeBottom: true), child: child),
      ),
    );
  }
}
