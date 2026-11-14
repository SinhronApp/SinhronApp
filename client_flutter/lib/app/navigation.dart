// App navigation — wires every screen into the flow.
//
// Linear flow (the natural user journey):
//   Welcome
//   Welcome:
//     Get started → ServerInvite → Profile → SaveAccess → SettingUp → ChatList
//     Link a device → ServerInvite → PairQr → ChatList
//     Restore from phrase → ServerInvite → Restore → ChatList
//   ChatList:
//     tap chat row → ChatView
//     tabs → Calls / Contacts / Settings
//   ChatView:
//     tap header (avatar/name) → ChatInfo
//
// All back chevrons / iOS swipe gestures pop the route stack naturally
// (DsPageRoute — a CupertinoPageRoute — is the page builder).

import 'dart:async' show unawaited;

import 'dart:convert' show utf8;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../core/providers/presence.dart' show peerPresenceProvider, presenceLabel, isOnlineNow;
import '../core/providers/chat_actions.dart';
import '../core/providers/chat_providers.dart';
import '../core/providers/device_providers.dart';
import '../core/app_notice.dart';
import '../core/diag_log.dart';
import '../features/report_problem/problem_report.dart';
import '../features/report_problem/report_problem_screen.dart';
import '../features/settings/backup_screen.dart';
import '../core/providers/message_actions.dart' show peopleProvider;
import '../core/providers/people.dart';
import '../core/providers/personal_chats.dart' show personalChatsProvider;
import '../core/providers/saved_messages.dart';
import 'adaptive.dart';
import '../features/chat_list/folders.dart' show chatsInFolder, kFolderAll;
import 'theme/motion.dart';
import 'theme/tokens.dart' show DsTheme;
import '../features/documents/document_share.dart' show shareDecryptedFile, shareOrigin;
import '../features/chat_list/chat_data.dart' show ChatPreview;
import '../core/providers/core_providers.dart';
import '../core/contact_qr.dart';
import '../core/incoming_share.dart';
import '../core/invite_link.dart';
import '../core/push.dart' show waitForChat;
import '../core/qr_scan.dart';
import '../core/server_address.dart';
import '../core/services/net_service.dart';
import '../core/providers/settings_providers.dart';
import '../core/session.dart';
import '../features/account_delete/delete_account_screen.dart';
import '../core/account_deletion.dart';
import '../features/blocked_contacts/blocked_contacts_screen.dart';
import '../features/calls/active_call_provider.dart';
import '../features/calls/live_call_screen.dart';
import '../features/calls_list/call_history.dart';
import '../features/calls_list/calls_list_screen.dart';
import '../features/chat_list/archived_chats_screen.dart';
import '../features/chat_list/chat_list_screen.dart';
import '../features/chat_list/chat_folders_screen.dart';
import '../features/chat_list/folder_editor_screen.dart';
import '../features/chat_info/chat_info_screen.dart';
import '../features/chat_view/chat_view_screen.dart';
import '../features/share_into/share_target_screen.dart';
import '../features/compose/compose_screen.dart';
import '../features/contact_info/contact_profile_screen.dart';
import '../features/contacts_list/contacts_list_screen.dart';
import '../features/invite_link/invite_landing_screen.dart';
import '../features/new_group/new_group_screen.dart';
import '../features/onboarding/profile_screen.dart';
import '../features/onboarding/pair_qr_screen.dart';
import '../features/onboarding/restore_screen.dart';
import '../features/onboarding/save_access_screen.dart';
import '../features/onboarding/server_invite_screen.dart';
import '../features/onboarding/setting_up_screen.dart';
import '../features/onboarding/welcome_screen.dart';
import '../features/my_profile/my_profile_screen.dart';
import '../features/profile_edit/profile_edit_screen.dart';
import '../features/search/search_overlay_screen.dart';
import '../features/settings/proxy_screen.dart';
import '../features/settings/add_device_screen.dart';
import '../features/settings/app_lock_screen.dart';
import '../features/settings/appearance_screen.dart';
import '../features/settings/linked_devices_screen.dart';
import '../features/settings/notifications_screen.dart';
import '../features/settings/privacy_security_screen.dart';
import '../features/legal/legal_text_screen.dart';
import '../features/settings/phrase_prompt.dart';
import '../features/settings/account_access_screen.dart';
import '../features/settings/server_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/settings/storage_screen.dart';
import '../features/settings/storage_usage.dart';
import '../features/shared_media/shared_media_screen.dart';
import '../features/show_qr/show_qr_screen.dart';
import '../features/sign_out/sign_out_screen.dart';
import '../features/unlock/device_removed_screen.dart';
import '../features/unlock/unlock_screen.dart';
import '../features/verify/verify_contact.dart';
import '../l10n/l10n.dart';
import '../widgets/ds_action_sheet.dart';
import '../widgets/ds_page_route.dart';
import '../features/chat_view/forward_sheet.dart';
import '../widgets/ds_tab_bar.dart';
import 'app.dart' show SinhronApp;

/// Global diagnostic banner — visible at the root of the app, used to
/// surface async-error messages (Start chat fails, etc.) when normal
/// dialog/snackbar approaches don't render (theme / overlay / context
/// issues). Set the value to a message string to display; set to empty
/// string ('') to hide. Tap on the banner dismisses it.
final ValueNotifier<String> globalDiagnosticBanner = appNotice;

/// Default home. Identity-aware boot routing (WU 73.2):
///   - If `identityProvider` is still loading → the plain theme
///     background (the Rust→SQLite read on cold launch is brief).
///   - If `identityProvider` returned non-null → skip directly to
///     ChatList. The user already onboarded on a previous launch; no
///     reason to walk through Welcome / ServerInvite / RecoveryPhrase
///     again (which would also re-generate a different BIP-39 phrase
///     and confuse the user about which one is "their" recovery).
///   - Otherwise (no identity / load errored) → the linear onboarding
///     flow starting at the welcome screen.
class AppRoot extends ConsumerWidget {
  const AppRoot({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ADR-021 — encrypted DB and no key here: unlock with the phrase.
    if (ref.watch(storageLockedProvider)) return const DsReadableWidth(child: UnlockScreen(locked: true));
    // Another of my devices removed this one: nothing here works any more.
    if (ref.watch(deviceRemovedProvider)) return const DsReadableWidth(child: DeviceRemovedScreen());
    final identity = ref.watch(identityProvider);
    return identity.when(
      // Loading (a moment on every launch): just the background — not
      // the welcome screen, which flashed before the chat list.
      loading: () => ColoredBox(color: DsTheme.of(context).bg, child: const SizedBox.expand()),
      // The account could not be read: also just the background. Never the
      // welcome screen — one tap on "Get started" there would make a new
      // account over the one that is still on this phone.
      error: (_, _) => ColoredBox(color: DsTheme.of(context).bg, child: const SizedBox.expand()),
      data: (row) {
        if (row != null) {
          // ADR-021 — a returning user is connected with the device key
          // from the Keychain. Without one (Keychain wiped, or onboarded
          // before keys were kept) the phrase reconnects them — never a
          // second onboarding, which would mint a brand-new account.
          final hasKey = ref.watch(hasDeviceKeyProvider);
          if (hasKey.value == false) return const DsReadableWidth(child: UnlockScreen(locked: false));
          if (hasKey.value == true) {
            Future.microtask(() => ref.read(sessionProvider).resume());
          }
          return _wireChatListBuilder()(context);
        }
        return _wireSplash(context);
      },
    );
  }
}

// ─── Forward routing helpers ─────────────────────────────────────────

/// ADR-076 — onboarding on an iPad: a readable column in the middle, not
/// fields across the whole screen.
WidgetBuilder _form(WidgetBuilder builder) => (context) => DsReadableWidth(child: builder(context));

Widget _wireSplash(BuildContext context) => _wireWelcomeBuilder()(context);

WidgetBuilder _wireWelcomeBuilder() => _form((context) {
  // ADR-032 — every path starts with the server: typed or scanned.
  return WelcomeScreen(
    onGetStarted: () => Navigator.of(context).push(_route(_wireServerInviteBuilder(next: _wireProfileBuilder()))),
    // ADR-025 — both mean "I already have an account": enter its phrase,
    // this phone becomes one more device of it.
    // Tech-debt 4.2 — "Link a device" shows a pairing QR for the other device.
    onLinkDevice: () =>
        Navigator.of(context).push(_route(_wireServerInviteBuilder(next: _wirePairQrBuilder(), step: null))),
    onRestore: () =>
        Navigator.of(context).push(_route(_wireServerInviteBuilder(next: _wireRestoreBuilder(), step: null))),
    onTerms: () => Navigator.of(context).push(_route(_wireTermsBuilder())),
  );
});

/// ADR-037 — the rules every account accepts (App Store 1.2).
WidgetBuilder _wireTermsBuilder() => (context) {
  final l = context.l10n;
  return LegalTextScreen(
    title: l.legalTermsRow,
    paragraphs: [l.legalTermsIntro, l.legalTermsBody],
    onBack: () => Navigator.of(context).pop(),
  );
};

WidgetBuilder _wirePrivacyTextBuilder() => (context) {
  final l = context.l10n;
  return LegalTextScreen(
    title: l.legalPrivacyRow,
    paragraphs: [l.legalPrivacyBody],
    onBack: () => Navigator.of(context).pop(),
  );
};

/// Help: who runs this server, how to report.
/// Settings → "Report a problem": the journal for the last hour + facts,
/// as a text file through the share sheet (Sinhron itself, Telegram, mail).
WidgetBuilder _wireReportProblemBuilder() => (context) {
  return Consumer(
    builder: (context, ref, _) {
      Future<String> build(String note) async {
        // The journal goes even when the phone's facts can't be read.
        ReportFacts facts;
        try {
          facts = await ref.refresh(problemReportFactsProvider.future).timeout(const Duration(seconds: 15));
        } catch (e) {
          facts = [('Факты о телефоне', 'не удалось собрать ($e)')];
        }
        return buildProblemReport(
          note: note,
          facts: facts,
          app: DiagLog.instance.recent(),
          native: await DiagLog.instance.nativeRecent(),
          now: DateTime.now(),
        );
      }

      return ReportProblemScreen(
        build: build,
        onBack: () => Navigator.of(context).pop(),
        onSend: (report) {
          final t = DateTime.now();
          String two(int n) => n.toString().padLeft(2, '0');
          return shareDecryptedFile(
            Uint8List.fromList(utf8.encode(report)),
            fileName: 'sinhron-report-${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}.txt',
            mimeType: 'text/plain',
          );
        },
        onCopy: (report) async {
          await Clipboard.setData(ClipboardData(text: report));
          if (context.mounted) showDone(context.l10n.reportProblemCopied);
        },
      );
    },
  );
};

WidgetBuilder _wireSupportBuilder() => (context) {
  return Consumer(
    builder: (context, ref, _) {
      final l = context.l10n;
      final host = serverHostOf(ref.watch(serverUrlProvider).value ?? '');
      return LegalTextScreen(
        title: l.legalSupportRow,
        paragraphs: [l.legalSupportBody, if (host.isNotEmpty) l.legalSupportOperator(host), l.legalSupportReportHint],
        onBack: () => Navigator.of(context).pop(),
      );
    },
  );
};

WidgetBuilder _wireRestoreBuilder() => _form((context) {
  return RestoreScreen(
    onBack: () => Navigator.of(context).pop(),
    // AppRoot (the first route) shows the chat list once signed in.
    onDone: () {
      final nav = Navigator.of(context);
      nav.popUntil((route) => route.isFirst);
      _offerPendingInvite(nav);
      // ADR-073 — the chats from the old phone's backup, if there is one.
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(offerBackupRestore(nav)));
    },
    onUseQr: () => Navigator.of(context).pushReplacement(_route(_wirePairQrBuilder())),
  );
});

WidgetBuilder _wirePairQrBuilder() => _form((context) {
  return PairQrScreen(
    onBack: () => Navigator.of(context).pop(),
    onDone: () => Navigator.of(context).popUntil((route) => route.isFirst),
    onUseWords: () => Navigator.of(context).pushReplacement(_route(_wireRestoreBuilder())),
  );
});

WidgetBuilder _wireServerInviteBuilder({required WidgetBuilder next, String? step = '1 / 3'}) => _form((context) {
  return ServerInviteScreen(
    step: step,
    onBack: () => Navigator.of(context).pop(),
    onContinue: () => Navigator.of(context).push(_route(next)),
  );
});

WidgetBuilder _wireProfileBuilder() => _form((context) {
  return ProfileScreen(
    onBack: () => Navigator.of(context).pop(),
    // The name typed here is the profile name (it used to be dropped).
    onName: (name) => ProviderScope.containerOf(context).read(profileNameProvider.notifier).save(name),
    onContinue: () => Navigator.of(context).push(_route(_wireRecoveryBuilder())),
  );
});

/// ADR-059 — step 3 "Keep access to your account" (Passwords / write
/// down / later); the account is made there.
WidgetBuilder _wireRecoveryBuilder() => _form((context) {
  return SaveAccessScreen(
    onBack: () => Navigator.of(context).pop(),
    onDone: () => Navigator.of(context).push(
      _route((ctx) {
        // No way back from here: the account already exists, and the step
        // behind would make it a second time.
        return PopScope(
          canPop: false,
          child: SettingUpScreen(
            // The server chosen on the first onboarding step (was the demo host).
            serverHost: serverHostOf(ProviderScope.containerOf(ctx).read(serverUrlProvider).value ?? ''),
            onFinished: () {
              final nav = Navigator.of(ctx);
              // A fresh root (it shows the chats now that the account exists)
              // instead of a chat list on top of the old root — Back showed a
              // second, identical chat list (2026-10-16 UI audit).
              nav.pushAndRemoveUntil(_route((_) => const AppRoot()), (_) => false);
              _offerPendingInvite(nav);
            },
          ),
        );
      }),
    ),
  );
});

/// ADR-076 — a tab on an iPad: its list on the left, what it opens on the
/// right ([AdaptiveSplit]); one column in a narrow window, as on iPhone.
Widget _adaptiveTab(
  BuildContext context, {
  required DsTabId tab,
  required WidgetBuilder list,
  Map<ShortcutActivator, void Function(BuildContext context, PaneController pane)> shortcuts = const {},
}) {
  final l = context.l10n;
  return AdaptiveSplit(
    memoryKey: tab,
    list: list,
    placeholder: switch (tab) {
      DsTabId.chats => l.splitPickChat,
      DsTabId.contacts => l.splitPickContact,
      DsTabId.calls => l.splitPickCall,
      DsTabId.settings => l.splitPickSetting,
    },
    phoneRoute: _route,
    paneRoute: _paneRoute,
    shortcuts: shortcuts,
  );
}

/// Opens what a tab's row leads to: on the right of an iPad, else on top.
void _detail(BuildContext context, WidgetBuilder builder, {Object? id}) =>
    openDetail(context, builder, id: id, fallback: _route);

WidgetBuilder _wireChatListBuilder() => (context) {
  return _adaptiveTab(
    context,
    tab: DsTabId.chats,
    list: (ctx) => _chatList(ctx),
    shortcuts: {
      // ⌥↑ / ⌥↓, Ctrl+Tab / Ctrl+Shift+Tab — the chat above / below.
      const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): (ctx, pane) => _stepChat(ctx, pane, -1),
      const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): (ctx, pane) => _stepChat(ctx, pane, 1),
      const SingleActivator(LogicalKeyboardKey.tab, control: true): (ctx, pane) => _stepChat(ctx, pane, 1),
      const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true): (ctx, pane) =>
          _stepChat(ctx, pane, -1),
      // ⌘F search, ⌘N a new message.
      const SingleActivator(LogicalKeyboardKey.keyF, meta: true): (ctx, pane) => _openSearch(ctx),
      const SingleActivator(LogicalKeyboardKey.keyN, meta: true): (ctx, pane) => _detail(ctx, _wireComposeBuilder()),
    },
  );
};

/// The chat [delta] rows from the open one in "All" (Saved first) — the
/// first one when none is open. Only beside the list (iPad).
Future<void> _stepChat(BuildContext context, PaneController pane, int delta) async {
  if (!pane.wide) return;
  final container = ProviderScope.containerOf(context, listen: false);
  final chats = container.read(chatsProvider).value ?? const <ChatPreview>[];
  final saved = savedChatEntry(chats);
  final order = [
    saved,
    ...chatsInFolder(kFolderAll, [
      for (final c in chats)
        if (!c.saved) c,
    ]),
  ];
  if (order.isEmpty) return;
  final at = order.indexWhere((c) => c.id != null && c.id == pane.selected.value);
  final next = at < 0 ? 0 : (at + delta).clamp(0, order.length - 1);
  if (next == at) return;
  final chat = await _realChat(context, order[next]);
  if (chat == null || !context.mounted) return;
  pane.open(
    _wireChatViewBuilder(chatId: chat.id, contactName: chat.name),
    id: chat.id,
  );
}

/// ADR-055 — the Saved messages stand-in becomes the real chat (made now,
/// on first open); any other chat as it is. Null when it couldn't be made.
Future<ChatPreview?> _realChat(BuildContext context, ChatPreview chat) async {
  if (chat.id != kSavedChatPendingId) return chat;
  try {
    final id = await ProviderScope.containerOf(context, listen: false).read(savedMessagesProvider).ensure();
    return ChatPreview(id: id, name: chat.name, preview: chat.preview, time: chat.time, saved: true);
  } catch (e) {
    // ignore: avoid_print
    print('[sinhron] saved messages not made: $e');
    globalDiagnosticBanner.value = lookupAppL10n(Locale(currentLanguage)).savedMessagesFailed;
    return null;
  }
}

Widget _chatList(BuildContext context) {
  return ChatListScreen(
    onChatTap: (tapped) async {
      final chat = await _realChat(context, tapped);
      if (chat == null || !context.mounted) return;
      _detail(
        context,
        _wireChatViewBuilder(chatId: chat.id, contactName: chat.name),
        id: chat.id,
      );
    },
    onTabChange: (tab) => _onMainTabChange(context, tab),
    onCompose: () => _detail(context, _wireComposeBuilder()),
    onSearch: () => _openSearch(context),
    onProfile: () => _detail(context, _wireMyProfileBuilder()),
    onEditFolder: (folder) =>
        _detail(context, (ctx) => FolderEditorScreen(folder: folder, onDone: () => Navigator.of(ctx).pop())),
    onSaveAccess: () => _detail(context, _wireRecoveryPhraseStatusBuilder()),
    onOpenArchive: () => _detail(context, _wireArchiveBuilder()),
  );
}

/// Search over the whole screen; a chat found opens on the right of an
/// iPad (the search closes), else in place of the search.
void _openSearch(BuildContext context) {
  final pane = AdaptiveSplit.maybeOf(context);
  rootNavigator(context).push(_searchRoute(_wireSearchBuilder(pane: pane)));
}

WidgetBuilder _wireArchiveBuilder() =>
    (ctx) => ArchivedChatsScreen(
      onBack: () => Navigator.of(ctx).pop(),
      onChatTap: (chat) => Navigator.of(
        ctx,
      ).push(_route(_wireChatViewBuilder(chatId: chat.id, contactName: chat.name))),
    );

WidgetBuilder _wireSearchBuilder({PaneController? pane}) => (context) {
  // Replace the search with the chat, so Back returns to the list — on an
  // iPad the chat opens on the right instead.
  void show(ChatPreview chat, {String? wireId}) {
    final chatView = _wireChatViewBuilder(
      chatId: chat.id,
      contactName: chat.name,
      openAtWireId: wireId,
    );
    if (pane != null && pane.wide) {
      Navigator.of(context).pop();
      pane.open(chatView, id: chat.id);
    } else {
      Navigator.of(context).pushReplacement(_route(chatView));
    }
  }

  return SearchOverlayScreen(
    onCancel: () => Navigator.of(context).pop(),
    onOpenChat: show,
    onOpenMessage: (chat, wireId) => show(chat, wireId: wireId),
  );
};

WidgetBuilder _wireComposeBuilder() => (context) {
  return Consumer(
    builder: (context, ref, _) => ComposeScreen(
      onCancel: () => Navigator.of(context).pop(),
      // My contacts (ADR-052): search them, open their chat — or start one
      // if there is none. Status is real presence only (ADR-031).
      contacts: [
        for (final c in contactEntries(
          ref.watch(contactsProvider).value ?? const <ContactRecord>[],
          ref.watch(chatsProvider).value ?? const <ChatPreview>[],
          ref.watch(peerNamesProvider).value ?? const <String, String>{},
        ))
          ComposeContact(
            chatId: c.chatId ?? '',
            name: c.name,
            key: c.peerId,
            status: presenceLabel(context.l10n, ref.watch(peerPresenceProvider)[c.peerId]),
            online: isOnlineNow(ref.watch(peerPresenceProvider)[c.peerId]),
            photo: peerAvatarOf(ref, c.peerId),
          ),
      ],
      onOpenContact: (c) => c.chatId.isEmpty
          ? _startChatByIdentity(context, ref, c.key, name: c.name)
          : Navigator.of(context).pushReplacement(_route(_wireChatViewBuilder(chatId: c.chatId, contactName: c.name))),
      // ADR-034 — real groups of several people.
      onNewGroup: () => Navigator.of(context).push(_route(_wireNewGroupBuilder())),
      onInviteQr: () => Navigator.of(context).push(_route(_wireShowQrBuilder(mode: ShowQrMode.invite))),
      onScanQr: () => _scanContactAndStartChat(context, ref),
      onInviteByIdentity: (identityHex) => _startChatByIdentity(context, ref, identityHex),
    ),
  );
};

/// Scan a contact's QR (My QR code on their phone) → start the chat.
Future<void> _scanContactAndStartChat(BuildContext context, WidgetRef ref) async {
  final l = context.l10n;
  final text = await ref.read(qrScannerProvider)();
  if (text == null || !context.mounted) return; // closed / no camera
  final contact = parseContactQr(text);
  if (contact == null) {
    globalDiagnosticBanner.value = l.scanContactNotSinhron;
    return;
  }
  await _startChatWithContact(context, ref, contact);
}

/// A scanned QR or a contact card in a chat → their chat (not with myself,
/// not across servers). [replace]: the screen it came from goes (New chat);
/// from a chat, Back returns to it.
Future<void> _startChatWithContact(
  BuildContext context,
  WidgetRef ref,
  ContactQr contact, {
  bool replace = true,
}) async {
  final l = context.l10n;
  if (contact.identityHex == ref.read(netServiceProvider).myIdentityHex) {
    globalDiagnosticBanner.value = l.scanContactSelf;
    return;
  }
  final mine = serverHostOf(await ref.read(serverUrlProvider.future));
  if (contact.serverHost != null && contact.serverHost != mine.toLowerCase()) {
    globalDiagnosticBanner.value = l.scanContactOtherServer(contact.serverHost!);
    return;
  }
  if (!context.mounted) return;
  await _startChatByIdentity(context, ref, contact.identityHex, name: contact.name, replace: replace);
}

/// Encrypted 1:1 chat with [identityHex] (typed key or scanned QR). [name]
/// comes from their contact QR; without it the chat is "Chat `<key start>`"
/// until their profile arrives.
Future<void> _startChatByIdentity(
  BuildContext context,
  WidgetRef ref,
  String identityHex, {
  String? name,
  bool replace = true,
}) async {
  final container = ProviderScope.containerOf(context);
  // ADR-052 — scanning their QR, opening their link or typing their key
  // adds them to my contacts (and they stay there if the chat goes).
  unawaited(container.read(peopleProvider).addContact(identityHex, name: name));
  // Already chatting with them: open that chat — scanning their QR again
  // made a second, empty one (2026-10-16 UI audit). Read from storage, and
  // by the group's members when the row doesn't know its person yet: the
  // cached list is empty on a cold start from a link, and a chat that came
  // by invite had no person (owner, 2026-11-03 — two chats).
  final key = identityHex.toLowerCase();
  String? existing;
  try {
    existing = await container.read(personalChatsProvider).find(key);
  } catch (_) {}
  existing ??= (container.read(chatsProvider).value ?? const <ChatPreview>[])
      .where((c) => !c.group && c.peerId?.toLowerCase() == key && c.id != null)
      .firstOrNull
      ?.id;
  if (!context.mounted) return;
  if (existing != null) {
    final shown = (container.read(chatsProvider).value ?? const <ChatPreview>[])
        .where((c) => c.id == existing)
        .firstOrNull
        ?.name;
    _showChat(context, _wireChatViewBuilder(chatId: existing, contactName: shown ?? name), replace: replace);
    return;
  }
  // Setting up takes seconds: a second tap doesn't make a second chat,
  // and the top line says it's on its way (it showed nothing).
  if (!_startingChats.add(key)) return;
  appNotice.value = context.l10n.startingChat;
  try {
    await _startChatByIdentityOnce(context, ref, container, identityHex, name: name, replace: replace);
  } finally {
    _startingChats.remove(key);
    if (appNotice.value == lookupAppL10n(Locale(currentLanguage)).startingChat) appNotice.value = '';
  }
}

final _startingChats = <String>{};

void _showChat(BuildContext context, WidgetBuilder chat, {required bool replace}) {
  final nav = Navigator.of(context);
  replace ? nav.pushReplacement(_route(chat)) : nav.push(_route(chat));
}

Future<void> _startChatByIdentityOnce(
  BuildContext context,
  WidgetRef ref,
  ProviderContainer container,
  String identityHex, {
  String? name,
  bool replace = true,
}) async {
  // MLS dance via FFI: create group + invite + ship Welcome — on the
  // server this phone joined (ADR-032), not a build-time constant.
  final given = name?.trim() ?? '';
  final chatName = given.isNotEmpty ? given : context.l10n.newChatPlaceholder;
  final httpBase =
      container.read(netServiceProvider).httpBaseUrl ?? httpBaseOf(await container.read(serverUrlProvider.future));
  // Only failures reach the banner (the "[start chat] dialing / ok" debug
  // lines used to stay on screen for everyone).
  try {
    // Just back from copying the key in another app: the connection may
    // still be coming up — wait for it a little rather than fail at once.
    final net = container.read(netServiceProvider);
    if (net.status != NetStatus.connected) {
      unawaited(container.read(sessionProvider).reconnect().catchError((Object _) => false));
      await net.waitConnected(const Duration(seconds: 10));
    }
    final groupId = await createMlsChat(
      ref,
      recipientIdentityHex: identityHex,
      displayName: chatName,
      httpBaseUrl: httpBase,
    );
    if (!context.mounted) return;
    _showChat(context, _wireChatViewBuilder(chatId: groupId, contactName: chatName), replace: replace);
  } catch (e) {
    // ignore: avoid_print
    print('[sinhron] MLS chat create failed: $e');
    globalDiagnosticBanner.value = _humaniseChatCreateError(e.toString());
    final err = e.toString().toLowerCase();
    // No connection at all: open it again now, so "try again" works.
    if (err.contains('not connected')) {
      unawaited(container.read(sessionProvider).reconnect().catchError((Object _) => false));
    }
    // The sync client isn't up in this process (its start failed, or iOS
    // restarted the app): start it again with the device key. Tech-debt
    // 2.37 — this used to send the person to onboarding, where "Create
    // account" would have made a new account over the existing one
    // (ADR-021: never a second onboarding). No key on this phone → the
    // root shows "Unlock" (the 24 words), as on launch.
    if (isSyncNotStarted(err)) {
      final started = await container.read(sessionProvider).resume(force: true).catchError((Object _) => false);
      final nav = SinhronApp.navigatorKey.currentState;
      if (!started && nav != null) {
        nav.pushAndRemoveUntil(_route((_) => const AppRoot()), (route) => false);
      }
    }
  }
}

/// "sync not initialised" (Rust: no SyncClient in this process).
bool isSyncNotStarted(String error) {
  final l = error.toLowerCase();
  return l.contains('sync not initialised') || l.contains('not initialized');
}

// ── ADR-043 — invite links ─────────────────────────────────────────

/// A link reached the app (`InviteLinkListener` at the root). A short one
/// is fetched from its server first; verified in Rust; then: no account
/// here → onboarding on the invite's server; same server → "add to
/// contacts"; my own link / another server → a line.
Future<void> handleInviteLink(String link) async {
  final nav = SinhronApp.navigatorKey.currentState;
  if (nav == null) return;
  final container = ProviderScope.containerOf(nav.context);
  final l = lookupAppL10n(Locale(currentLanguage));
  Object? me;
  try {
    me = await container.read(identityProvider.future);
  } catch (_) {}
  final myHost = serverHostOf(await container.read(serverUrlProvider.future).catchError((Object _) => ''));
  // app-surface:3 — a short link is fetched from the server it names (my
  // IP goes there): before a tap only from my own server. An account on
  // another server → the line at once; no account → ask first.
  if (isShortInviteLink(link)) {
    final host = shortInviteHost(link);
    if (me != null && host != myHost.toLowerCase()) {
      globalDiagnosticBanner.value = l.scanContactOtherServer(host);
      return;
    }
    if (me == null) {
      final ctx = nav.context;
      if (!ctx.mounted) return;
      final open = await showDsActionSheet<bool>(
        ctx,
        title: '${l.inviteLandingTitle}\n$host',
        actions: [DsSheetAction(l.openLink, true)],
      );
      if (open != true) return;
    }
  }
  final OpenedInvite invite;
  try {
    invite = await container.read(inviteOpenerProvider)(link);
  } on InviteLinkError catch (e) {
    if (e.code == 'not_invite') return;
    globalDiagnosticBanner.value = switch (e.code) {
      'forged' => l.inviteForged,
      'expired' => l.inviteExpired,
      'offline' => l.inviteOffline,
      _ => l.inviteDamaged,
    };
    return;
  }
  switch (inviteActionFor(
    invite,
    hasAccount: me != null,
    myIdentityHex: container.read(netServiceProvider).myIdentityHex,
    myServerHost: myHost,
  )) {
    case InviteAction.self:
      globalDiagnosticBanner.value = l.scanContactSelf;
    case InviteAction.otherServer:
      globalDiagnosticBanner.value = l.scanContactOtherServer(invite.serverHost);
    case InviteAction.addContact:
      nav.push(_route(_wireInviteAddContactBuilder(invite)));
    case InviteAction.newAccount:
      nav.push(_route((ctx) => _InviteNewAccountScreen(invite: invite)));
  }
}

// ── ADR-060 — sharing into Sinhron from another app ───────────────

/// Something came in through the share menu (`IncomingShareListener` at
/// the root): "Send to…" on top of whatever is open — under the app lock
/// when it's on. No account here yet → a line, and the copies go.
Future<void> handleIncomingShare(IncomingShare share) async {
  final nav = SinhronApp.navigatorKey.currentState;
  if (nav == null) return;
  final container = ProviderScope.containerOf(nav.context);
  final platform = container.read(sharePlatformProvider);
  final l = lookupAppL10n(Locale(currentLanguage));
  if (share.isEmpty) {
    globalDiagnosticBanner.value = l.shareNothing;
    await finishShare(platform, share);
    return;
  }
  Object? me;
  try {
    me = await container.read(identityProvider.future);
  } catch (_) {}
  if (me == null) {
    globalDiagnosticBanner.value = l.shareNoAccount;
    await finishShare(platform, share);
    return;
  }
  nav.push(
    _route(
      (context) => ShareTargetScreen(
        share: share,
        onCancel: () => Navigator.of(context).pop(),
        onSent: (sent) {
          // One chat → it opens (Back returns to where you were); several → a pill.
          if (sent.length == 1) {
            final c = sent.single;
            Navigator.of(
              context,
            ).pushReplacement(_route(_wireChatViewBuilder(chatId: c.id, contactName: c.chat.name)));
          } else {
            Navigator.of(context).pop();
            showDone(l.shareSent);
          }
        },
      ),
    ),
  );
}

/// The account was just made (or signed in) after accepting an invite: offer
/// the inviter at once.
void _offerPendingInvite(NavigatorState nav) {
  final invite = ProviderScope.containerOf(nav.context).read(pendingInviteProvider.notifier).take();
  if (invite == null) return;
  WidgetsBinding.instance.addPostFrameCallback((_) => nav.push(_route(_wireInviteAddContactBuilder(invite))));
}

String _inviterName(AppL10n l, OpenedInvite invite) =>
    invite.name.isNotEmpty ? invite.name : l.newChatPlaceholder;

/// Same server: who invites, their key's start → "Add to contacts" → the chat.
WidgetBuilder _wireInviteAddContactBuilder(OpenedInvite invite) => (context) {
  return Consumer(
    builder: (context, ref, _) {
      final l = context.l10n;
      final name = _inviterName(l, invite);
      return InviteLandingScreen(
        server: invite.serverHost,
        inviterName: name,
        inviterUsername: '',
        token: l.inviteKeyRow(keyFingerprint(invite.identityHex)),
        expiresIn: '',
        reachability: l.inviteYourServer,
        showSteps: false,
        acceptLabel: l.inviteAddContact(name),
        onBack: () => Navigator.of(context).pop(),
        // Replaces this screen with the new chat.
        onAccept: () => _startChatByIdentity(context, ref, invite.identityHex, name: invite.name),
      );
    },
  );
};

/// No account yet: the invite's server is checked and saved, then the
/// usual steps (name, 24 words); the inviter is offered once it's done.
class _InviteNewAccountScreen extends ConsumerStatefulWidget {
  const _InviteNewAccountScreen({required this.invite});
  final OpenedInvite invite;

  @override
  ConsumerState<_InviteNewAccountScreen> createState() => _InviteNewAccountScreenState();
}

class _InviteNewAccountScreenState extends ConsumerState<_InviteNewAccountScreen> {
  ServerCheck? _check;
  bool _busy = false;
  String? _error;

  /// An invite only ever leads to a TLS server (security-review-2026-11 app-surface:1).
  String? get _url {
    final u = normalizeServerInput(widget.invite.serverHost);
    return u != null && u.startsWith('wss://') ? u : null;
  }

  /// Save the server; true when it's saved.
  Future<bool> _saveServer() async {
    final l = context.l10n;
    final url = _url;
    if (url == null) {
      setState(() => _error = l.inviteDamaged);
      return false;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final c = await checkServer(url, get: ref.read(serverHttpGetProvider));
    if (!mounted) return false;
    if (c == ServerCheck.notSinhron) {
      setState(() {
        _busy = false;
        _check = c;
        _error = l.inviteNotSinhron;
      });
      return false;
    }
    try {
      await ref.read(serverUrlProvider.notifier).save(url);
    } catch (_) {
      setState(() {
        _busy = false;
        _error = l.inviteNotSaved;
      });
      return false;
    }
    ref.read(pendingInviteProvider.notifier).set(widget.invite);
    if (mounted) setState(() => _busy = false);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final name = _inviterName(l, widget.invite);
    return InviteLandingScreen(
      server: widget.invite.serverHost,
      inviterName: name,
      inviterUsername: '',
      token: l.inviteKeyRow(keyFingerprint(widget.invite.identityHex)),
      expiresIn: '',
      reachability: switch (_check) {
        null => _busy ? l.inviteServerChecking : '',
        ServerCheck.ok => l.inviteServerOk,
        ServerCheck.notSinhron => l.inviteNotSinhron,
        _ => l.inviteServerUnreachable,
      },
      reachable: _check == ServerCheck.ok,
      busy: _busy,
      error: _error,
      onBack: () => Navigator.of(context).pop(),
      onAccept: () async {
        if (await _saveServer() && context.mounted) {
          Navigator.of(context).push(_route(_wireProfileBuilder()));
        }
      },
      // Already have an account (the 24 words) — sign in on this server.
      onAlreadyHaveAccount: () async {
        if (await _saveServer() && context.mounted) {
          Navigator.of(context).push(_route(_wireRestoreBuilder()));
        }
      },
    );
  }
}

/// Map noisy FFI / MLS error strings to short user-friendly messages.
String _humaniseChatCreateError(String raw) {
  final l = raw.toLowerCase();
  if (l.contains('duplicatesignaturekey')) {
    return lookupAppL10n(Locale(currentLanguage)).navErrKeyAlreadyInChat;
  }
  if (l.contains('no keypackage available') || l.contains('empty: no keypackage')) {
    return lookupAppL10n(Locale(currentLanguage)).navErrNoKeyPackage;
  }
  if (l.contains('rate limit') || l.contains('429')) {
    return lookupAppL10n(Locale(currentLanguage)).navErrRateLimited;
  }
  // "net not connected" (Rust: no connection right now) — owner's
  // screenshot 2026-10-16 showed it raw after a Wi-Fi → LTE switch.
  if (l.contains('not connected') || isSyncNotStarted(l)) {
    return lookupAppL10n(Locale(currentLanguage)).navErrNotConnected;
  }
  if (l.contains('connection') || l.contains('socket') || l.contains('timeout')) {
    return lookupAppL10n(Locale(currentLanguage)).navErrServerUnreachable;
  }
  if (l.contains('invalid') && l.contains('hex')) {
    return lookupAppL10n(Locale(currentLanguage)).navErrBadKeyFormat;
  }
  // Anything else: one plain line (it used to show up to 240 characters
  // of the raw error); the details go to the log for a report.
  // ignore: avoid_print
  print('[sinhron] chat action failed: $raw');
  return lookupAppL10n(Locale(currentLanguage)).groupActionFailed;
}

/// Opens a chat on top of whatever is on screen — used by the in-app
/// banner (UI backlog §8 item 57); Back returns to where you were.
/// ADR-066 — a notification about [chatId] was tapped (`PushSync`): that
/// chat opens over whatever is on screen (Back returns there) — on a cold
/// start once the root navigator and the chat list are up; under the app
/// lock when it is on, so the chat is there after Face ID / the code. The
/// chat already on screen → nothing.
Future<void> openChatFromNotification(String chatId) async {
  NavigatorState? nav;
  for (var i = 0; i < 100 && nav == null; i++) {
    nav = SinhronApp.navigatorKey.currentState;
    if (nav == null) await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  if (nav == null || !nav.mounted) return;
  final container = ProviderScope.containerOf(nav.context);
  final chat = await waitForChat(chatId, chats: () => container.read(chatsProvider.future));
  if (chat == null || !nav.mounted || container.read(openChatProvider) == chatId) return;
  pushChatFromAnywhere(nav, chatId: chatId, name: chat.name);
}

void pushChatFromAnywhere(NavigatorState nav, {required String chatId, required String name}) {
  final chat = _wireChatViewBuilder(chatId: chatId, contactName: name);
  // ADR-076 — the chats are beside the list (iPad): it opens on the right.
  final pane = AdaptiveSplit.visible(DsTabId.chats);
  if (pane != null) {
    pane.open(chat, id: chatId);
  } else {
    nav.push(_route(chat));
  }
}

WidgetBuilder _wireChatViewBuilder({String? chatId, String? contactName, String? openAtWireId}) => (context) {
  return Consumer(
    builder: (context, ref, _) => ChatViewScreen(
      chatId: chatId,
      openAtWireId: openAtWireId,
      contactName: contactName ?? '',
      onBack: () => Navigator.of(context).pop(),
      onContactInfo: chatId == null
          ? null
          : () => Navigator.of(context).push(
              _route(
                // ADR-055 — Saved messages has no one to show: straight to its media & files.
                ProviderScope.containerOf(context, listen: false).read(savedChatIdProvider).value == chatId
                    ? _wireSharedMediaBuilder(chatId: chatId, contactName: contactName ?? '')
                    : _wireChatInfoBuilder(chatId: chatId, contactName: contactName ?? ''),
              ),
            ),
      // CD4 — Call / Video buttons route into the live activeCallProvider;
      // `chatId` doubles as the MLS group_id (1:1 chat = 1:1 MLS group keyed
      // by hex group id).
      onCall: chatId == null
          ? null
          : () => _startLiveCall(context, chatId: chatId, contactName: contactName ?? '', kind: CallKind.audio),
      onVideo: chatId == null
          ? null
          : () => _startLiveCall(context, chatId: chatId, contactName: contactName ?? '', kind: CallKind.video),
      // A shared contact card's "Message": their chat over this one.
      onOpenContact: (contact) => _startChatWithContact(context, ref, contact, replace: false),
    ),
  );
};

/// CD4 — outgoing call entry point. Wraps activeCallProvider invocation
/// + navigation.
void _startLiveCall(
  BuildContext context, {
  required String chatId,
  required String contactName,
  required CallKind kind,
}) {
  // Real call. Read the ProviderContainer through context — Provider-
  // Scope ancestor was installed in main.dart.
  final container = ProviderScope.containerOf(context);
  final notifier = container.read(activeCallProvider.notifier);

  // Push first, kick off invite second — the LiveCallScreen subscribes
  // to provider state and is ready before the network ack lands.
  // ADR-076 — over both columns of an iPad, not inside the right one.
  final nav = rootNavigator(context);
  final l = context.l10n;
  final route = callScreenRoute((ctx) => LiveCallScreen(contactName: contactName));
  nav.push(route);

  // A refused permission or a failed invite used to leave nothing on
  // screen: close the call screen and say why.
  unawaited(
    notifier.invite(groupIdHex: chatId, kind: kind).then<void>((_) {}, onError: (Object e) {
      if (route.isActive) nav.removeRoute(route);
      final m = e.toString();
      globalDiagnosticBanner.value = m.contains('microphone permission')
          ? l.callErrMic
          : m.contains('camera permission')
          ? l.callErrCamera
          : l.callErrFailed;
    }),
  );
}

/// Real chats (tech-debt 2.22 / 2.27): members with their own names,
/// safety numbers, timer, mute, block, delete.
WidgetBuilder _wireChatInfoBuilder({required String chatId, required String contactName}) => (context) {
  return ChatInfoScreen(
    chatId: chatId,
    onBack: () => Navigator.of(context).pop(),
    onSharedMedia: () =>
        Navigator.of(context).push(_route(_wireSharedMediaBuilder(chatId: chatId, contactName: contactName))),
    onVerify: (name, peer) => Navigator.of(context).push(
      _route(
        (ctx) => VerifyContactScreen(
          chatId: chatId,
          contactName: name,
          peerKeyHex: peer,
          onBack: () => Navigator.of(ctx).pop(),
        ),
      ),
    ),
    // Back past the (now deleted) chat to the list.
    onDeleted: () => Navigator.of(context).popUntil((r) => r.isFirst),
    // ADR-034 — groups: add people (one Commit that reaches every member).
    onAddMembers: () => Navigator.of(context).push(_route(_wireNewGroupBuilder(addToChatId: chatId))),
    onOpenGroup: (id, name) =>
        Navigator.of(context).push(_route(_wireChatViewBuilder(chatId: id, contactName: name))),
    onOpenProfile: (peer, name) => Navigator.of(context).push(_route(_wireContactProfileBuilder(peerId: peer, name: name))),
  );
};

/// ADR-052 — a person's profile (from Contacts or a group's members): message / call / video,
/// bio, key check, media, groups in common, favourite, remove, block.
WidgetBuilder _wireContactProfileBuilder({required String peerId, String name = ''}) => (context) {
  return Consumer(
    builder: (context, ref, _) => ContactProfileScreen(
      peerId: peerId,
      fallbackName: name,
      onBack: () => Navigator.of(context).pop(),
      // Their chat, or a new one if it was deleted / never started.
      onMessage: (chatId, name) => chatId == null
          ? _startChatByIdentity(context, ref, peerId, name: name)
          : Navigator.of(context).push(_route(_wireChatViewBuilder(chatId: chatId, contactName: name))),
      onCall: (chatId, name, video) => _startLiveCall(
        context,
        chatId: chatId,
        contactName: name,
        kind: video ? CallKind.video : CallKind.audio,
      ),
      onSafetyNumber: (chatId, name) => Navigator.of(context).push(
        _route(
          (ctx) => VerifyContactScreen(chatId: chatId, contactName: name, onBack: () => Navigator.of(ctx).pop()),
        ),
      ),
      onSharedMedia: (chatId, name) =>
          Navigator.of(context).push(_route(_wireSharedMediaBuilder(chatId: chatId, contactName: name))),
      onOpenGroup: (id, name) =>
          Navigator.of(context).push(_route(_wireChatViewBuilder(chatId: id, contactName: name))),
    ),
  );
};

WidgetBuilder _wireSharedMediaBuilder({required String chatId, String contactName = ''}) => (context) {
  return SharedMediaScreen(
    contactName: contactName,
    chatId: chatId,
    onBack: () => Navigator.of(context).pop(),
    // Gallery "Show in chat": the chat opens at that message; Back returns
    // here (Telegram).
    onShowInChat: (wireId) => Navigator.of(
      context,
    ).push(_route(_wireChatViewBuilder(chatId: chatId, contactName: contactName, openAtWireId: wireId))),
  );
};

WidgetBuilder _wireShowQrBuilder({ShowQrMode mode = ShowQrMode.myQr}) => (context) {
  // The real contact card: my name, key and server (was the demo "Vera").
  return Consumer(
    builder: (context, ref, _) {
      final l = context.l10n;
      final key = ref.watch(netServiceProvider).myIdentityHex ?? '';
      final host = serverHostOf(ref.watch(serverUrlProvider).value ?? '');
      final name = ref.watch(profileNameProvider).value ?? '';
      return ShowQrScreen(
        mode: mode,
        name: name.isEmpty ? l.you : name,
        username: keyFingerprint(key),
        server: host,
        photo: ref.watch(myAvatarProvider),
        qrPayload: key.isEmpty ? null : contactQrPayload(key, host, name: name),
        onBack: () => Navigator.of(context).pop(),
        onScanInstead: () => _scanContactAndStartChat(context, ref),
        // ADR-043 — share a signed invite link: one tap on the other phone
        // sets the server and adds me (the key as text if signing fails).
        onShare: key.isEmpty ? null : () => _shareMyContact(context, ref),
        onCopyKey: key.isEmpty ? null : () => _copyMyAddress(context, ref),
      );
    },
  );
};

/// ADR-043 — share a signed invite link: one tap on the other phone sets
/// the server and adds me (the address as text if signing fails).
Future<void> _shareMyContact(BuildContext context, WidgetRef ref) async {
  final l = context.l10n;
  final key = ref.read(netServiceProvider).myIdentityHex ?? '';
  final host = serverHostOf(ref.read(serverUrlProvider).value ?? '');
  final name = ref.read(profileNameProvider).value ?? '';
  String text;
  try {
    final link = await ref.read(inviteLinkCreatorProvider)(host, name);
    text = l.inviteShareText(link);
  } catch (_) {
    text = l.showQrShareText(key, host);
  }
  await SharePlus.instance.share(ShareParams(text: text, sharePositionOrigin: shareOrigin()));
}

Future<void> _copyMyAddress(BuildContext context, WidgetRef ref) async {
  final l = context.l10n;
  await Clipboard.setData(ClipboardData(text: ref.read(netServiceProvider).myIdentityHex ?? ''));
  showDone(l.showQrKeyCopied);
}

/// My profile (owner, 2026-10-18): my photo at the top-left of Chats /
/// Calls / Contacts and the Settings card open it — photo, name, About, my
/// QR and "Share so people can message me"; Edit opens the profile editor.
WidgetBuilder _wireMyProfileBuilder() => (context) {
  return Consumer(
    builder: (context, ref, _) {
      final l = context.l10n;
      final key = ref.watch(netServiceProvider).myIdentityHex ?? '';
      final host = serverHostOf(ref.watch(serverUrlProvider).value ?? '');
      final name = ref.watch(profileNameProvider).value ?? '';
      return MyProfileScreen(
        name: name.isEmpty ? l.yourName : name,
        about: ref.watch(profileAboutProvider).value ?? '',
        photo: ref.watch(myAvatarProvider),
        address: key.isEmpty ? null : keyFingerprint(key),
        qrPayload: key.isEmpty ? null : contactQrPayload(key, host, name: name),
        onBack: () => Navigator.of(context).pop(),
        onEdit: () => Navigator.of(context).push(_route(_wireProfileEditBuilder())),
        onShare: () => _shareMyContact(context, ref),
        onCopyAddress: () => _copyMyAddress(context, ref),
        onPhoto: () {
          final photo = ref.read(myAvatarProvider);
          if (photo != null) openAvatarFullScreen(context, name.isEmpty ? l.you : name, photo);
        },
      );
    },
  );
};

WidgetBuilder _wireSignOutBuilder() => (context) {
  // Wrapped in Consumer so onConfirm can read `ref` to wipe the
  // identities + chats tables AND the MLS-state file (WU C6), then
  // invalidate the providers — AppRoot re-routes back to splash/
  // welcome on the next frame.
  return Consumer(
    builder: (context, ref, _) => SignOutScreen(
      // Who is signing out: my name and key (was the demo "Vera").
      name: switch (ref.watch(profileNameProvider).value ?? '') {
        '' => context.l10n.you,
        final n => n,
      },
      username: keyFingerprint(ref.watch(netServiceProvider).myIdentityHex ?? ''),
      // My other devices (0 while offline / unknown → that line is hidden).
      otherDeviceCount: (ref.watch(linkedDevicesProvider).value ?? const []).where((d) => !d.isThisDevice).length,
      onBack: () => Navigator.of(context).pop(),
      onConfirm: () async {
        final nav = rootNavigator(context);
        // ADR-021 — chats DB, MLS state and the device key in the
        // Keychain all go; AppRoot re-routes to onboarding.
        try {
          await ref.read(sessionProvider).eraseAndStartOver();
        } catch (e) {
          // ignore: avoid_print
          print('[sinhron] sign-out wipe failed: $e');
          // Stay here and say so — it used to land back in the chats as
          // if nothing happened (2026-10-16 UI audit).
          if (context.mounted) appNotice.value = context.l10n.signOutFailed;
          return;
        }
        ref.invalidate(identityProvider);
        ref.invalidate(chatsProvider);
        // The old account's chat stays out of the right column.
        AdaptiveSplit.forgetAll();
        if (!context.mounted) return;
        nav.popUntil((route) => route.isFirst);
      },
    ),
  );
};

WidgetBuilder _wireSettingsBuilder() => (context) {
  return _adaptiveTab(
    context,
    tab: DsTabId.settings,
    list: (context) => Consumer(
      builder: (context, ref, _) {
        return SettingsScreen(
          onTabChange: (tab) => _onMainTabChange(context, tab),
          onAppearanceTap: () => _detail(context, (ctx) => AppearanceScreen(onBack: () => Navigator.of(ctx).pop())),
          onStorageTap: () => _detail(context, _wireStorageBuilder()),
          onTermsTap: () => _detail(context, _wireTermsBuilder()),
          onPrivacyPolicyTap: () => _detail(context, _wirePrivacyTextBuilder()),
          onSupportTap: () => _detail(context, _wireSupportBuilder()),
          onReportProblemTap: () => _detail(context, _wireReportProblemBuilder()),
          onBackupTap: () => _detail(context, (ctx) => BackupScreen(onBack: () => Navigator.of(ctx).pop())),
          onLinkedDevicesTap: () => _detail(context, _wireLinkedDevicesBuilder()),
          onPrivacyTap: () => _detail(context, _wirePrivacyBuilder()),
          onServerTap: () => _detail(context, _wireServerBuilder()),
          onNotificationsTap: () => _detail(context, _wireNotificationsBuilder()),
          onAppLockTap: () => _detail(context, _wireAppLockBuilder()),
          onRecoveryPhraseTap: () => _detail(context, _wireRecoveryPhraseStatusBuilder()),
          onProfileTap: () => _detail(context, _wireMyProfileBuilder()),
          onChatFoldersTap: () => _detail(context, (ctx) => ChatFoldersScreen(onBack: () => Navigator.of(ctx).pop())),
          onArchiveTap: () => _detail(context, _wireArchiveBuilder()),
          onProxyTap: () => _detail(context, (ctx) => ProxyScreen(onBack: () => Navigator.of(ctx).pop())),
        );
      },
    ),
  );
};

WidgetBuilder _wireProfileEditBuilder() => (context) {
  return ProfileEditScreen(
    onCancel: () => Navigator.of(context).pop(),
    onSave: () => Navigator.of(context).pop(),
    onPrivacy: () => Navigator.of(context).push(_route(_wirePrivacyBuilder())),
    onSignOut: () => Navigator.of(context).push(_route(_wireSignOutBuilder())),
    // ADR-037 — delete the account.
    onDeleteAccount: () => Navigator.of(context).push(_route(_wireDeleteAccountBuilder())),
  );
};

/// ADR-037 — delete my account: server first, then this phone; back to
/// the start like sign-out.
WidgetBuilder _wireDeleteAccountBuilder() => (context) {
  return Consumer(
    builder: (context, ref, _) => DeleteAccountScreen(
      server: serverHostOf(ref.watch(serverUrlProvider).value ?? ''),
      needsPhrase: ref.watch(accountKeyHereProvider).value == false,
      askPhrase: () => promptPhrase(context),
      otherDevices: (ref.watch(linkedDevicesProvider).value ?? const []).where((d) => !d.isThisDevice).length,
      onBack: () => Navigator.of(context).pop(),
      onDelete: (phrase) async {
        final nav = rootNavigator(context);
        await ref.read(accountDeletionProvider).run(phrase: phrase);
        ref.invalidate(identityProvider);
        ref.invalidate(chatsProvider);
        // The old account's chat stays out of the right column.
        AdaptiveSplit.forgetAll();
        nav.popUntil((route) => route.isFirst);
      },
    ),
  );
};

/// ADR-059 — Settings → Secret words: saved or not, save now, check them,
/// the second device. (The phrase isn't kept once saved, so it can't be
/// shown again — spec §6.8.)
WidgetBuilder _wireRecoveryPhraseStatusBuilder() => (context) {
  return AccountAccessScreen(
    onBack: () => Navigator.of(context).pop(),
    onLinkDevice: () => Navigator.of(context).push(_route(_wireLinkedDevicesBuilder())),
  );
};

WidgetBuilder _wireAppLockBuilder() => (context) {
  return AppLockScreen(onBack: () => Navigator.of(context).pop());
};

WidgetBuilder _wireNotificationsBuilder() => (context) {
  return NotificationsScreen(onBack: () => Navigator.of(context).pop());
};

/// ADR-034 — New group (from New chat) or, with [addToChatId], "Add
/// member" for an existing group. Picks from real people: my accepted
/// personal chats with a known key, by the names they chose.
WidgetBuilder _wireNewGroupBuilder({String? addToChatId}) => (context) {
  return Consumer(
    builder: (context, ref, _) {
      final l = context.l10n;
      final chats = ref.watch(chatsProvider).value ?? const <ChatPreview>[];
      final names = ref.watch(peerNamesProvider).value ?? const <String, String>{};
      final blocked = ref.watch(blockedPeersProvider).value ?? const <String>{};
      final me = ref.watch(netServiceProvider).myIdentityHex ?? '';
      final myName = ref.watch(profileNameProvider).value ?? '';
      final contacts = contactEntries(ref.watch(contactsProvider).value ?? const [], chats, names);
      final members = addToChatId == null
          ? const <String>[]
          : (ref.watch(chatMembersProvider(addToChatId)).value ?? const <String>[]);
      Future<String> httpBase() async =>
          ref.read(netServiceProvider).httpBaseUrl ?? httpBaseOf(await ref.read(serverUrlProvider.future));
      // Errors go to the banner; the screen stays so the user can retry.
      Future<void> guarded(Future<void> Function() job) async {
        try {
          await job();
        } catch (e) {
          // ignore: avoid_print
          print('[sinhron] group: $e');
          globalDiagnosticBanner.value = _humaniseChatCreateError(e.toString());
          rethrow;
        }
      }

      return NewGroupScreen(
        contacts: groupCandidates(
          chats,
          names,
          exclude: {me, ...members},
          blocked: blocked,
          photos: ref.watch(peerAvatarsProvider).value ?? const {},
          verified: ref.watch(verifiedPeersProvider(verifiedPeersKey(contacts))).value ?? const {},
          contacts: contacts,
        ),
        me: NewGroupContact(
          id: me,
          name: myName.isEmpty ? l.you : myName,
          subtitle: shortKey(me),
          photo: ref.watch(myAvatarProvider),
        ),
        onCancel: () => Navigator.of(context).pop(),
        onCreate: addToChatId != null
            ? null
            : (name, ids) => guarded(() async {
                final chatId = await createMlsGroup(
                  ref,
                  name: name,
                  memberIdentityHexes: ids,
                  httpBaseUrl: await httpBase(),
                );
                if (!context.mounted) return;
                // New group → the chat; back from it lands on the list,
                // not on New chat.
                final nav = Navigator.of(context);
                nav.pop();
                nav.pushReplacement(_route(_wireChatViewBuilder(chatId: chatId, contactName: name)));
              }),
        onAdd: addToChatId == null
            ? null
            : (ids) => guarded(() async {
                final name = chats.where((c) => c.id == addToChatId).firstOrNull?.name ?? '';
                await addGroupMembers(
                  ref,
                  chatId: addToChatId,
                  name: name,
                  memberIdentityHexes: ids,
                  httpBaseUrl: await httpBase(),
                );
                ref.invalidate(chatMembersProvider(addToChatId));
                if (context.mounted) Navigator.of(context).pop();
              }),
      );
    },
  );
};

/// The server this phone joined — host, connection, transport. Operator,
/// policies and Switch server have no backend yet, so the screen doesn't
/// show them.
WidgetBuilder _wireServerBuilder() => (context) {
  return Consumer(
    builder: (context, ref, _) {
      final url = ref.watch(serverUrlProvider).value ?? '';
      return ServerScreen(
        onBack: () => Navigator.of(context).pop(),
        host: serverHostOf(url),
        connected: ref.watch(netStatusProvider) == NetStatus.connected,
        protocol: url.startsWith('wss:') ? 'WSS · TLS' : 'WS',
      );
    },
  );
};

WidgetBuilder _wirePrivacyBuilder() => (context) {
  return PrivacySecurityScreen(
    onBack: () => Navigator.of(context).pop(),
    onBlockedList: () => Navigator.of(context).push(_route(_wireBlockedContactsBuilder())),
    onAppLock: () => Navigator.of(context).push(_route(_wireAppLockBuilder())),
  );
};

WidgetBuilder _wireBlockedContactsBuilder() => (context) {
  return BlockedContactsScreen(onBack: () => Navigator.of(context).pop());
};

/// Tech-debt 2.32 — this phone's real numbers; clearing deletes the media
/// copies and re-reads them.
WidgetBuilder _wireStorageBuilder() => (context) {
  return Consumer(
    builder: (context, ref, _) {
      final usage = ref.watch(storageUsageProvider);
      return StorageScreen(
        onBack: () => Navigator.of(context).pop(),
        usage: usage.value ?? const StorageUsage(),
        onClearCopies: () async {
          final freed = await ref.read(storageSpaceOpsProvider).clearCopies();
          ref.invalidate(storageUsageProvider);
          return freed;
        },
        // Tech-debt 2.32 — keep unused copies forever / a month / a week;
        // a shorter time applies at once (and each time storage opens).
        keepDays: int.tryParse(ref.watch(mediaKeepDaysProvider).value ?? '0') ?? 0,
        onKeepDays: (days) async {
          await ref.read(mediaKeepDaysProvider.notifier).save('$days');
          if (days > 0) {
            try {
              await ref.read(storageSpaceOpsProvider).clearOlderThan?.call(days);
            } catch (_) {}
            ref.invalidate(storageUsageProvider);
          }
        },
      );
    },
  );
};

WidgetBuilder _wireLinkedDevicesBuilder() => (context) {
  return LinkedDevicesScreen(
    onBack: () => Navigator.of(context).pop(),
    onAddDevice: () =>
        Navigator.of(context).push(_route((ctx) => AddDeviceScreen(onBack: () => Navigator.of(ctx).pop()))),
  );
};

void _onMainTabChange(BuildContext context, DsTabId tab) {
  // Tab switches are peer-level, not "going deeper" — use an instant
  // route so the swap feels native (UITabBarController has no transition).
  // pushAndRemoveUntil keeps the stack flat: [splash, current_tab].
  final WidgetBuilder builder = switch (tab) {
    DsTabId.chats => _wireChatListBuilder(),
    DsTabId.settings => _wireSettingsBuilder(),
    DsTabId.calls => _wireCallsListBuilder(),
    DsTabId.contacts => _wireContactsListBuilder(),
  };
  rootNavigator(context).pushAndRemoveUntil(_instantRoute(builder), (route) => route.isFirst);
}

/// Calls tab — this phone's real call history; a tap calls back, ⓘ opens the chat.
WidgetBuilder _wireCallsListBuilder() => (context) {
  return _adaptiveTab(
    context,
    tab: DsTabId.calls,
    list: (context) => Consumer(
      builder: (context, ref, _) {
        final chats = ref.watch(chatsProvider).value ?? const <ChatPreview>[];
        final names = ref.watch(peerNamesProvider).value ?? const <String, String>{};
        final history = ref.watch(callHistoryProvider);
        final calls = callEntries(history.value ?? const [], chats, names);
        final myName = ref.watch(profileNameProvider).value ?? '';
        return CallsListScreen(
          onTabChange: (tab) => _onMainTabChange(context, tab),
          onProfile: () => _detail(context, _wireMyProfileBuilder()),
          calls: calls,
          loading: !history.hasValue,
          myName: myName.isEmpty ? context.l10n.you : myName,
          myPhoto: ref.watch(myAvatarProvider),
          photos: chatPhotos(chats, ref.watch(peerAvatarsProvider).value ?? const {}),
          unreadChats: ref.watch(unreadChatsCountProvider),
          onCallTap: (chatId) {
            final call = calls.firstWhere((c) => c.chatId == chatId);
            _detail(
              context,
              _wireChatViewBuilder(chatId: chatId, contactName: call.name),
              id: chatId,
            );
          },
          // Overnight item 5 — a tap calls back (ⓘ opens the chat).
          // Tech-debt 2.34 — "new call": pick a contact, an audio call starts.
          onNewCall: () async {
            // Calls go through a chat: contacts we have one with.
            final people = [
              for (final c in contactEntries(ref.read(contactsProvider).value ?? const [], chats, names))
                if (c.chatId != null) c,
            ];
            if (people.isEmpty) {
              _onMainTabChange(context, DsTabId.contacts);
              return;
            }
            // The same list as "Forward to…": photos, scrolls with any
            // number of people (it was a plain list of names).
            final byId = {for (final c in chats) c.id: c};
            final targets = [for (final p in people) ?byId[p.chatId!]];
            final picked = await showForwardSheet(
              context,
              withPhotos(targets, ref.read(peerAvatarsProvider).value ?? const {}),
              title: context.l10n.callsNewCallTitle,
            );
            final chatId = picked?.id;
            if (picked == null || chatId == null || !context.mounted) return;
            _startLiveCall(context, chatId: chatId, contactName: picked.name, kind: CallKind.audio);
          },
          onCallBack: (chatId, video) {
            final call = calls.firstWhere((c) => c.chatId == chatId);
            _startLiveCall(
              context,
              chatId: chatId,
              contactName: call.name,
              kind: video ? CallKind.video : CallKind.audio,
            );
          },
        );
      },
    ),
  );
};

/// Contacts tab (ADR-052) — my contacts, their own list; a tap opens the
/// person's profile, the phone calls, my card opens my QR code, + starts a
/// new chat, "Invite friends" shares my invite link.
WidgetBuilder _wireContactsListBuilder() => (context) {
  return _adaptiveTab(
    context,
    tab: DsTabId.contacts,
    list: (context) => Consumer(
      builder: (context, ref, _) {
        final l = context.l10n;
        final chats = ref.watch(chatsProvider).value ?? const <ChatPreview>[];
        final names = ref.watch(peerNamesProvider).value ?? const <String, String>{};
        final myName = ref.watch(profileNameProvider).value ?? '';
        final contacts = contactEntries(ref.watch(contactsProvider).value ?? const [], chats, names);
        return ContactsListScreen(
          onTabChange: (tab) => _onMainTabChange(context, tab),
          onProfile: () => _detail(context, _wireMyProfileBuilder()),
          contacts: contacts,
          verifiedPeers: ref.watch(verifiedPeersProvider(verifiedPeersKey(contacts))).value ?? const {},
          photos: ref.watch(peerAvatarsProvider).value ?? const {},
          me: MyContactCard(
            name: myName.isEmpty ? l.you : myName,
            keyLabel: keyFingerprint(ref.watch(netServiceProvider).myIdentityHex ?? ''),
            server: serverHostOf(ref.watch(serverUrlProvider).value ?? ''),
            photo: ref.watch(myAvatarProvider),
          ),
          unreadChats: ref.watch(unreadChatsCountProvider),
          onOpen: (c) => _detail(
            context,
            _wireContactProfileBuilder(peerId: c.peerId, name: c.name),
            id: c.peerId,
          ),
          onCall: (c) => _startLiveCall(context, chatId: c.chatId!, contactName: c.name, kind: CallKind.audio),
          onInvite: () => _detail(context, _wireShowQrBuilder(mode: ShowQrMode.invite)),
          onMyCard: () => _detail(context, _wireShowQrBuilder()),
          onAdd: () => _detail(context, _wireComposeBuilder()),
        );
      },
    ),
  );
};

// ─── Route factories ─────────────────────────────────────────────────

/// iOS-style slide-in. Used for "going deeper" (chat list → chat view, etc.).
Route<T> _route<T>(WidgetBuilder builder) {
  // iOS slide + edge-swipe back; crossfade under Reduce Motion.
  return DsPageRoute<T>(builder: builder);
}

/// Tab-bar swap. Quick crossfade between sibling tabs — softer than the
/// previous `Duration.zero` swap (which felt jarring on device) but no
/// horizontal slide (a slide reads as "going deeper" in iOS). 180ms
/// easeOut matches the cadence WhatsApp/Telegram use for the same
/// gesture.
Route<T> _instantRoute<T>(WidgetBuilder builder) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, _, _) => builder(context),
    transitionsBuilder: (_, animation, _, child) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      );
    },
    transitionDuration: const Duration(milliseconds: 180),
    reverseTransitionDuration: const Duration(milliseconds: 140),
  );
}

/// ADR-076 — what opens on the right of an iPad: the tab-swap fade; Esc
/// closes it (the route's own Esc goes to its barrier, which the page
/// covers — nothing to tap).
Route<T> _paneRoute<T>(WidgetBuilder builder) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, _, _) => builder(context),
    barrierDismissible: true,
    transitionsBuilder: (_, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    ),
    transitionDuration: const Duration(milliseconds: 180),
    reverseTransitionDuration: const Duration(milliseconds: 140),
  );
}

/// Search over the chat list: fades in with a few points of rise, like the
/// iOS search controller — a sideways slide read as "a new screen".
Route<T> _searchRoute<T>(WidgetBuilder builder) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, _, _) => builder(context),
    transitionsBuilder: (context, animation, _, child) {
      if (DsMotion.reduced(context)) return FadeTransition(opacity: animation, child: child);
      final t = CurvedAnimation(parent: animation, curve: DsMotion.emphasized, reverseCurve: DsMotion.exit);
      return FadeTransition(
        opacity: t,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.015), end: Offset.zero).animate(t),
          child: child,
        ),
      );
    },
    transitionDuration: DsMotion.base,
    reverseTransitionDuration: DsMotion.fast,
  );
}
