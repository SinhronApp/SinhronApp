// "Share contact" (owner, 2026-11-03): the profile sends the person's
// contact QR text as one message; the chat shows it as a card with "Message".

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/contact_qr.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/server_address.dart';
import 'package:sinhron/core/session.dart';
import 'package:sinhron/features/chat_view/chat_view_screen.dart';
import 'package:sinhron/features/contact_info/contact_profile_screen.dart';

import '../chat_view/chat_view_actions_test.dart' show Harness, bubble, kAnya, row, w1, w2;

void main() {
  testWidgets('a contact card: name, "Message", the tap opens their chat; other text stays text', (t) async {
    final card = contactQrPayload(kAnya, 'chat.example.com', name: 'Аня');
    final h = Harness(history: [row('c1', w1, 1, card), row('t1', w2, 2, 'see $card')]);
    final opened = <ContactQr>[];
    await h.pump(t, screen: ChatViewScreen(chatId: 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678', onOpenContact: opened.add));
    expect(find.byKey(const ValueKey('contact-card')), findsOneWidget);
    expect(find.text('Аня'), findsWidgets);
    expect(find.text('Address ${keyFingerprint(kAnya)}'), findsOneWidget);
    expect(find.text('Name from the card, not checked'), findsNothing, reason: 'Аня is someone I know');
    expect(bubble('sinhron-contact:'), findsOneWidget, reason: 'words around it: plain text');
    await t.tap(find.byKey(const ValueKey('contact-card-message')));
    await t.pump(const Duration(milliseconds: 500)); // past the double-tap wait
    expect(opened.single.identityHex, kAnya);
    expect(opened.single.name, 'Аня');
    expect(opened.single.serverHost, 'chat.example.com');
  });

  testWidgets('app-surface:9 — a card names a stranger "Мама": the key start shows and the name is marked unchecked', (t) async {
    final stranger = '5e' * 32;
    final h = Harness(history: [row('c1', w1, 1, contactQrPayload(stranger, 'chat.example.com', name: 'Мама'))]);
    await h.pump(t, screen: ChatViewScreen(chatId: 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678', onOpenContact: (_) {}));
    expect(find.text('Мама'), findsOneWidget);
    expect(find.text('Address 5e5e 5e5e 5e5e 5e5e'), findsOneWidget);
    expect(find.text('Name from the card, not checked'), findsOneWidget);
  });

  testWidgets('app-surface:9 — a card puts "Мама" on a key I know: it shows (and opens) under my name for them', (t) async {
    final h = Harness(history: [row('c1', w1, 1, contactQrPayload(kAnya, 'chat.example.com', name: 'Мама'))]);
    final opened = <ContactQr>[];
    await h.pump(t, screen: ChatViewScreen(chatId: 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678', onOpenContact: opened.add));
    expect(find.text('Мама'), findsNothing);
    expect(find.text('Name from the card, not checked'), findsNothing);
    await t.tap(find.byKey(const ValueKey('contact-card-message')));
    await t.pump(const Duration(milliseconds: 500));
    expect(opened.single.name, 'Аня');
  });

  // security-review-2026-11 app-surface:5 — my private name for her stays mine.
  testWidgets('"Share contact" sends their contact QR text, with her own name, not mine for her', (t) async {
    final h = Harness();
    await h.container.read(contactAliasesProvider.future);
    await h.container.read(contactAliasesProvider.notifier).set(kAnya, 'Бывшая');
    await h.pump(t, screen: ContactProfileScreen(peerId: kAnya.toUpperCase()));
    final share = find.byKey(const ValueKey('profile-share'));
    await t.scrollUntilVisible(share, 200, scrollable: find.byType(Scrollable).first);
    await t.tap(share);
    await t.pumpAndSettle();
    expect(find.text('Send contact to…'), findsOneWidget);
    expect(find.text('Maria'), findsNothing, reason: 'not back into their own chat');
    await t.tap(find.text('Boris'));
    await t.pumpAndSettle();
    final host = serverHostOf(await h.container.read(serverUrlProvider.future));
    expect(h.sender.sent.single.split('|').first, contactQrPayload(kAnya, host, name: 'Аня'));
  });
}
