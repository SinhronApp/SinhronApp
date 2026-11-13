import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/features/show_qr/show_qr_screen.dart';

void main() {
  Widget host(Widget child) => DsTheme(
    tokens: DsTokens.light,
    isDark: false,
    child: MediaQuery(
      data: const MediaQueryData(size: Size(390, 1200)),
      child: Directionality(textDirection: TextDirection.ltr, child: child),
    ),
  );

  testWidgets('real mode: my data, a real QR, share and copy address', (t) async {
    t.view.physicalSize = const Size(390, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var shared = 0, copied = 0;
    await t.pumpWidget(
      host(
        ShowQrScreen(
          name: 'Grisha',
          username: 'abcd 1234',
          server: 'chat.example.com',
          qrPayload: 'sinhron-contact:${'ab' * 32}@chat.example.com',
          onShare: () => shared++,
          onCopyKey: () => copied++,
        ),
      ),
    );
    expect(find.text('Grisha'), findsOneWidget);
    expect(find.text('Vera Kuznetsova'), findsNothing);
    expect(find.byKey(const ValueKey('my-contact-qr')), findsOneWidget);
    expect(find.text('Save image'), findsNothing); // not built — not offered

    await t.tap(find.text('Share'));
    await t.tap(find.text('Copy address'));
    expect((shared, copied), (1, 1));
  });

  testWidgets('design preview keeps the drawn mock', (t) async {
    t.view.physicalSize = const Size(390, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(host(const ShowQrScreen()));
    expect(find.byKey(const ValueKey('my-contact-qr')), findsNothing);
    expect(find.text('Save image'), findsOneWidget);
  });
}
