// ADR-030 — screenshot alerts in chats with disappearing messages.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/providers/chat_actions.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/message_actions.dart';
import 'package:sinhron/core/providers/people.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/services/screenshot_watch.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/l10n/gen/app_l10n_en.dart';
import 'package:sinhron/l10n/gen/app_l10n_ru.dart';

import 'message_actions_test.dart' show FakeMessageStore, FakeSender;
import 'people_test.dart' show FakePeopleStore;
import 'settings_providers_test.dart' show MemoryStore;

final secret = 'ab' * 20; // disappearing messages on
final plain = 'cd' * 20; // no timer
final anna = 'a1' * 32;

void main() {
  late FakeMessageStore store;
  late FakeSender sender;
  late FakePeopleStore people;
  late ProviderContainer c;
  void Function()? shoot;
  void Function(bool)? record;

  setUp(() async {
    store = FakeMessageStore();
    sender = FakeSender();
    people = FakePeopleStore()..names_[anna] = 'Аня';
    c = ProviderContainer(
      overrides: [
        messageStoreProvider.overrideWithValue(store),
        messageSenderProvider.overrideWithValue(sender),
        peopleStoreProvider.overrideWithValue(people),
        settingsStoreProvider.overrideWithValue(MemoryStore()),
        screenshotSourceProvider.overrideWithValue((cb, rec) {
          shoot = cb;
          record = rec;
        }),
        chatsProvider.overrideWith(
          (ref) async => [
            ChatPreview(id: secret, name: 'Секрет', group: true, preview: '', time: '', disappearSecs: 3600),
            ChatPreview(id: plain, name: 'Обычный', preview: '', time: ''),
          ],
        ),
      ],
    );
    addTearDown(c.dispose);
    await c.read(chatsProvider.future);
    await c.read(peerNamesProvider.future);
  });

  test('a screenshot of an open disappearing chat tells everyone in it', () async {
    c.read(screenshotWatchProvider);
    c.read(openChatProvider.notifier).set(secret);
    shoot!();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(store.rows.single.body, 'screenshot:me');
    expect(sender.actions.single, {'t': 'screenshot'});
  });

  test('chats without a timer, and no open chat, stay quiet', () async {
    c.read(screenshotWatchProvider);
    shoot!(); // nothing open
    c.read(openChatProvider.notifier).set(plain);
    shoot!();
    await Future<void>.delayed(Duration.zero);
    expect(store.rows, isEmpty);
    expect(sender.actions, isEmpty);
  });

  test('a screenshot in a message request stays here', () async {
    final c2 = ProviderContainer(
      overrides: [
        messageStoreProvider.overrideWithValue(store),
        messageSenderProvider.overrideWithValue(sender),
        peopleStoreProvider.overrideWithValue(people),
        settingsStoreProvider.overrideWithValue(MemoryStore()),
        chatsProvider.overrideWith(
          (ref) async => [ChatPreview(id: secret, name: 'Чужой', preview: '', time: '', disappearSecs: 3600, request: true)],
        ),
      ],
    );
    addTearDown(c2.dispose);
    await c2.read(chatsProvider.future);
    expect(await c2.read(messageActionsProvider).screenshotTaken(secret), isFalse);
    expect(store.rows, isEmpty, reason: 'no line that would accept the request');
    expect(sender.actions, isEmpty, reason: 'the stranger learns nothing');
  });

  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('screen recording: told once per recording, also to a chat opened mid-recording', () async {
    c.read(screenshotWatchProvider);
    c.read(openChatProvider.notifier).set(plain);
    record!(true);
    await settle();
    expect(sender.actions, isEmpty, reason: 'no timer — nothing to say');

    c.read(openChatProvider.notifier).set(secret); // opened while recording
    await settle();
    expect(store.rows.single.body, 'recording:me');
    expect(sender.actions.single, {'t': 'screenshot', 'recording': true});

    c.read(openChatProvider.notifier).set(null);
    c.read(openChatProvider.notifier).set(secret);
    record!(true); // repeated event, same recording
    await settle();
    expect(sender.actions, hasLength(1), reason: 'once per recording');

    record!(false);
    record!(true); // a new recording
    await settle();
    expect(sender.actions, hasLength(2));
    expect(store.rows.map((r) => r.body), ['recording:me', 'recording:me']);
  });

  test("someone else's recording shows with their name", () async {
    final a = c.read(messageActionsProvider);
    expect(await a.onIncomingAction(secret, 'screenshot', '{"recording":true}', anna), isTrue);
    expect(store.rows.single.body, 'recording:peer:Аня');
  });

  test("someone else's screenshot shows with their name", () async {
    final a = c.read(messageActionsProvider);
    expect(await a.onIncomingAction(secret, 'screenshot', '{}', anna), isTrue);
    expect(store.rows.single.body, 'screenshot:peer:Аня');
    expect(await a.onIncomingAction(secret, 'screenshot', '{}', null), isFalse, reason: 'needs a sender');
  });

  test('system lines read in both languages', () {
    expect(systemLineText(AppL10nEn(), 'screenshot:me'), 'You took a screenshot');
    expect(systemLineText(AppL10nEn(), 'screenshot:peer:Anna'), 'Anna took a screenshot');
    expect(systemLineText(AppL10nRu(), 'screenshot:peer:Аня'), 'Аня: снимок экрана');
    expect(systemLineText(AppL10nEn(), 'recording:me'), 'You are recording the screen');
    expect(systemLineText(AppL10nEn(), 'recording:peer:Anna'), 'Anna is recording the screen');
    expect(systemLineText(AppL10nRu(), 'recording:peer:Аня'), 'Аня: запись экрана');
  });
}
