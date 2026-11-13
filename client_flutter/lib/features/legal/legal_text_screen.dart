// ADR-037 — rules of use, privacy and support, in the app (App Store 1.2:
// terms that say there is no tolerance for objectionable content, a way to
// report, contact). Plain text from l10n; the same for every server.

import 'package:flutter/widgets.dart';

import '../../app/theme/tokens.dart';
import '../../widgets/ds_app_bar.dart';

class LegalTextScreen extends StatelessWidget {
  const LegalTextScreen({super.key, required this.title, required this.paragraphs, this.onBack});

  final String title;

  /// Shown in order; the first one a little larger.
  final List<String> paragraphs;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final parts = [for (final p in paragraphs) ...p.split('\n\n')].where((p) => p.trim().isNotEmpty).toList();
    return ColoredBox(
      color: tokens.bg,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top),
        child: Column(
          children: [
            DsAppBar(title: title, onBack: onBack),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.fromLTRB(DsSpace.gutter, DsSpace.x4, DsSpace.gutter, pad.bottom + DsSpace.x6),
                children: [
                  for (final (i, p) in parts.indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: DsSpace.x3),
                      child: Text(
                        p,
                        style: (i == 0 ? DsText.body : DsText.callout).copyWith(color: i == 0 ? tokens.text : tokens.text2),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
