import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/pending_media.dart';
import 'package:sinhron/features/chat_view/pending_media_bubble.dart';

PendingMedia _item(PendingMediaState state, {String? wireId}) => PendingMedia(
      id: 'p1',
      chatId: 'c',
      kind: 'photo',
      label: 'Photo',
      state: state,
      job: (_) async {},
      wireId: wireId,
    );

Widget _host(PendingMedia item, double Function(String) progress, {VoidCallback? onRetry}) =>
    ProviderScope(
      overrides: [uploadProgressProvider.overrideWithValue(progress)],
      child: DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: PendingMediaBubble(item: item, onRetry: onRetry ?? () {}, onDismiss: () {}),
        ),
      ),
    );

void main() {
  testWidgets('shows preparing, then live upload percentage', (t) async {
    var p = 0.0;
    await t.pumpWidget(_host(_item(PendingMediaState.sending, wireId: 'w'), (_) => p));
    expect(find.text('Preparing photo…'), findsOneWidget);
    p = 0.42;
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Sending photo… 42%'), findsOneWidget);
    p = 1.0;
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Sending photo… 100%'), findsOneWidget);
  });

  testWidgets('no wire id yet → plain sending label', (t) async {
    await t.pumpWidget(_host(_item(PendingMediaState.sending), (_) => 0.5));
    expect(find.text('Sending photo…'), findsOneWidget);
  });

  testWidgets('failed item offers retry on tap', (t) async {
    var retried = 0;
    await t.pumpWidget(_host(_item(PendingMediaState.failed, wireId: 'w'), (_) => -1, onRetry: () => retried++));
    expect(find.text('Not sent: photo — tap to retry'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('pending-p1')));
    expect(retried, 1);
  });
}
