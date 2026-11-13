// Tech-debt 2.21 — "Change photo" sets a real photo (it used to do nothing).

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/message_actions.dart';
import 'package:sinhron/core/providers/people.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/profile_edit/profile_edit_screen.dart';
import 'package:sinhron/l10n/gen/app_l10n.dart';

import '../../core/message_actions_test.dart' show FakeMessageStore, FakeSender;
import '../../core/people_test.dart' show FakePeopleStore;
import '../../core/settings_providers_test.dart' show MemoryStore;

void main() {
  testWidgets('choose a photo: re-encoded, saved, shown, shared; remove takes it away', (t) async {
    t.view.physicalSize = const Size(390, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final settings = MemoryStore()..map['profile_name'] = 'Вера';
    final sender = FakeSender();
    final prepared = <int>[];
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(settings),
          messageStoreProvider.overrideWithValue(FakeMessageStore()),
          messageSenderProvider.overrideWithValue(sender),
          peopleStoreProvider.overrideWithValue(FakePeopleStore()),
          chatsProvider.overrideWith(
            (ref) async => [ChatPreview(id: 'ab' * 20, name: 'Семья', group: true, preview: '', time: '')],
          ),
          avatarSourceProvider.overrideWithValue(() async => Uint8List.fromList([9, 9, 9])),
          avatarPrepareProvider.overrideWithValue((image) async {
            prepared.add(image.length);
            return Uint8List.fromList([1, 2, 3]); // "re-encoded"
          }),
        ],
        child: Localizations(
          locale: const Locale('en'),
          delegates: const [AppL10n.delegate, GlobalWidgetsLocalizations.delegate],
          child: DsTheme(
            tokens: DsTokens.light,
            isDark: false,
            child: MediaQuery(
              data: const MediaQueryData(size: Size(390, 1200)),
              child: Navigator(
                onGenerateRoute: (_) => PageRouteBuilder<void>(pageBuilder: (_, _, _) => const ProfileEditScreen()),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('avatar-photo')), findsNothing);

    await t.tap(find.byKey(const ValueKey('profile-change-photo')));
    await t.pumpAndSettle();
    expect(find.text('Remove photo'), findsNothing, reason: 'nothing to remove yet');
    await t.tap(find.text('Choose photo'));
    await t.pumpAndSettle();
    expect(prepared, [3], reason: 'the picked image goes through Rust');
    expect(settings.map['profile_avatar'], 'AQID');
    expect(find.byKey(const ValueKey('avatar-photo')), findsWidgets, reason: 'the photo replaces the initials');
    expect(sender.actions.last, {'t': 'profile', 'name': 'Вера', 'avatar': 'AQID'});

    await t.tap(find.byKey(const ValueKey('profile-change-photo')));
    await t.pumpAndSettle();
    await t.tap(find.text('Remove photo'));
    await t.pumpAndSettle();
    expect(settings.map['profile_avatar'], '');
    expect(find.byKey(const ValueKey('avatar-photo')), findsNothing);
    expect(sender.actions.last, {'t': 'profile', 'name': 'Вера'});
  });
}
