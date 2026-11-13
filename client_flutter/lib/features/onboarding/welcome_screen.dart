// The first screen of a phone with no account: the mark, one line, and the
// ways in.
//   1. Get started — new account (server → name → keep access)
//   2. Link a device — pair by QR with a device already signed in
//   3. Sign in with the secret words
// None of them asks for a password, an email or a phone number (spec §6.1).

import 'package:flutter/widgets.dart';

import '../../app/theme/motion.dart';
import '../../app/theme/tokens.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/sinhron_mark.dart';

class WelcomeScreen extends StatefulWidget {
  final VoidCallback? onGetStarted;
  final VoidCallback? onLinkDevice;
  final VoidCallback? onRestore;

  /// ADR-037 — "By continuing you accept the Terms of use" (opens them).
  final VoidCallback? onTerms;

  const WelcomeScreen({super.key, this.onGetStarted, this.onLinkDevice, this.onRestore, this.onTerms});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> with TickerProviderStateMixin {
  // The mark settles first, then the words, then the buttons.
  late final _in = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));

  // The mark "breathes" — a slow, small swell (ADR-108). Still under Reduce Motion.
  late final _breath = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200));
  late final _breathScale = Tween(
    begin: 1.0,
    end: 1.05,
  ).animate(CurvedAnimation(parent: _breath, curve: Curves.easeInOut));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = DsMotion.reduced(context);
    if (_in.isDismissed) reduced ? _in.value = 1 : _in.forward();
    if (reduced) {
      _breath.value = 0;
    } else if (!_breath.isAnimating) {
      _breath.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    _in.dispose();
    super.dispose();
  }

  /// Fades in and rises a little during [from]..[to] of the entrance.
  Widget _arrive(double from, double to, Widget child) {
    final a = CurvedAnimation(parent: _in, curve: Interval(from, to, curve: DsMotion.enter));
    return FadeTransition(
      opacity: a,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.06), end: Offset.zero).animate(a),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final l = context.l10n;

    return ColoredBox(
      color: tokens.bg,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top, bottom: pad.bottom),
        // Scrolls only when it does not fit (a small phone, large text).
        child: _FitOrScroll(
          children: [
            const Spacer(flex: 5),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: DsSpace.x8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _arrive(
                    0,
                    0.6,
                    // Decoration: the name below is what VoiceOver reads.
                    ExcludeSemantics(
                      child: RepaintBoundary(
                        child: ScaleTransition(
                          key: const ValueKey('welcome-mark'),
                          scale: _breathScale,
                          child: Container(
                            width: 112,
                            height: 112,
                            decoration: BoxDecoration(color: tokens.accentSoft, shape: BoxShape.circle),
                            child: const Center(child: SinhronMark(size: 64)),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: DsSpace.x6),
                  _arrive(
                    0.2,
                    0.8,
                    Column(
                      children: [
                        Semantics(
                          header: true,
                          child: Text(
                            'Sinhron',
                            style: DsText.title1.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
                          ),
                        ),
                        const SizedBox(height: DsSpace.x2),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 280),
                          child: Text(
                            l.tagline,
                            textAlign: TextAlign.center,
                            style: DsText.bodyLarge.copyWith(fontWeight: FontWeight.w400, color: tokens.text2),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(flex: 7),
            _arrive(
              0.4,
              1,
              // A phone's width on an iPad, not edge to edge.
              Container(
                constraints: const BoxConstraints(maxWidth: 440),
                padding: const EdgeInsets.fromLTRB(DsSpace.x6, 0, DsSpace.x6, DsSpace.x4h5),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DsButton(label: l.getStarted, onPressed: () => widget.onGetStarted?.call()),
                    const SizedBox(height: DsSpace.x3),
                    DsButton(
                      label: l.linkDevice,
                      variant: DsButtonVariant.secondary,
                      onPressed: () => widget.onLinkDevice?.call(),
                    ),
                    const SizedBox(height: DsSpace.x1),
                    DsButton(
                      label: l.restoreFromKey,
                      variant: DsButtonVariant.ghost,
                      onPressed: () => widget.onRestore?.call(),
                    ),
                    if (widget.onTerms != null)
                      Semantics(
                        link: true,
                        child: GestureDetector(
                          key: const ValueKey('welcome-terms'),
                          behavior: HitTestBehavior.opaque,
                          onTap: widget.onTerms,
                          child: Padding(
                            padding: const EdgeInsets.only(top: DsSpace.x1),
                            child: Text(
                              l.welcomeAgreeTerms,
                              textAlign: TextAlign.center,
                              style: DsText.footnote.copyWith(color: tokens.text3),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FitOrScroll extends StatelessWidget {
  const _FitOrScroll({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: box.maxHeight),
        child: IntrinsicHeight(child: Column(children: children)),
      ),
    ),
  );
}
