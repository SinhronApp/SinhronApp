// My profile (owner, 2026-10-18): my photo in the Chats / Calls / Contacts
// header opens it; it shows who I am and how to reach me, not a copy of
// Settings.

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/features/my_profile/my_profile_screen.dart';
import 'package:sinhron/features/settings/_shared.dart';
import 'package:sinhron/widgets/ds_header.dart';

void main() {
  Widget host(Widget child) => DsTheme(
    tokens: DsTokens.light,
    isDark: false,
    child: MediaQuery(
      data: const MediaQueryData(size: Size(390, 1200)),
      child: Directionality(textDirection: TextDirection.ltr, child: child),
    ),
  );

  testWidgets('shows me, my QR and the share / copy / edit actions', (t) async {
    t.view.physicalSize = const Size(390, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var shared = 0, copied = 0, edited = 0;
    await t.pumpWidget(
      host(
        MyProfileScreen(
          name: 'Grisha',
          about: 'Builds messengers',
          address: 'abcd 1234 ef56',
          qrPayload: 'sinhron-contact:${'ab' * 32}@chat.example.com',
          onEdit: () => edited++,
          onShare: () => shared++,
          onCopyAddress: () => copied++,
        ),
      ),
    );
    expect(find.text('Grisha'), findsOneWidget);
    expect(find.text('Builds messengers'), findsOneWidget);
    expect(find.text('abcd 1234 ef56'), findsOneWidget);
    expect(find.byKey(const ValueKey('my-profile-qr')), findsOneWidget);
    // Not a copy of Settings: none of its rows are here.
    expect(find.byType(SettingsRow), findsNothing);

    await t.tap(find.byKey(const ValueKey('my-profile-share')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('my-profile-copy')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('my-profile-edit')));
    await t.pumpAndSettle();
    expect((shared, copied, edited), (1, 1, 1));
  });

  testWidgets('before the phone has an address: no QR, sharing waits', (t) async {
    t.view.physicalSize = const Size(390, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var shared = 0;
    await t.pumpWidget(host(MyProfileScreen(name: 'Grisha', onShare: () => shared++)));
    expect(find.byKey(const ValueKey('my-profile-qr')), findsNothing);
    expect(find.text('Your address appears once the phone connects to the server.'), findsOneWidget);
    expect(find.text('A few words about you — tap Edit'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('my-profile-share')));
    await t.pumpAndSettle();
    expect(shared, 0);
  });

  testWidgets('my photo opens full screen; without one the tap goes to Edit', (t) async {
    var opened = 0, edited = 0;
    final photo = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==');
    await t.pumpWidget(
      host(MyProfileScreen(name: 'Grisha', photo: photo, onPhoto: () => opened++, onEdit: () => edited++)),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('my-profile-avatar')));
    expect((opened, edited), (1, 0));

    await t.pumpWidget(host(MyProfileScreen(name: 'Grisha', onPhoto: () => opened++, onEdit: () => edited++)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('my-profile-avatar')));
    expect((opened, edited), (1, 1));
  });

  testWidgets('the header avatar is a button only when it opens something', (t) async {
    var opened = 0;
    await t.pumpWidget(host(DsHeader(userName: 'Grisha', title: 'Chats', onProfile: () => opened++)));
    final avatar = find.byKey(const ValueKey('header-my-avatar'));
    expect(avatar, findsOneWidget);
    expect(find.bySemanticsLabel('My profile'), findsOneWidget);
    await t.tap(avatar);
    await t.pumpAndSettle();
    expect(opened, 1);

    await t.pumpWidget(host(const DsHeader(userName: 'Grisha', title: 'Chats')));
    expect(find.byKey(const ValueKey('header-my-avatar')), findsNothing);
  });

  testWidgets('a row that acts in place has no chevron; a subtitle says what it is for', (t) async {
    Future<int> chevrons(Widget row) async {
      await t.pumpWidget(host(row));
      return find.byWidgetPredicate((w) => w is CustomPaint && w.painter is RowChevronPainter).evaluate().length;
    }

    expect(await chevrons(SettingsRow(label: 'Devices', subtitle: 'Phones and computers', onTap: () {})), 1);
    expect(find.text('Phones and computers'), findsOneWidget);
    expect(await chevrons(SettingsRow(label: 'Reconnect', chevron: false, onTap: () {})), 0);
    expect(await chevrons(const SettingsRow(label: 'Text size', value: 'As on iPhone')), 0);
  });
}
