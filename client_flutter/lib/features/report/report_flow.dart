// ADR-037 — report a person (App Store 1.2): why → with or without the
// message → sent → offer to block. The report goes to the operator of my
// server, signed; the message text only if I choose to send it (the
// server can't read chats otherwise).

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/message_actions.dart' show peopleProvider;
import '../../core/providers/people.dart';
import '../../core/server_address.dart';
import '../../core/services/net_service.dart';
import '../../core/session.dart' show serverUrlProvider;
import '../../l10n/l10n.dart';
import '../../src/rust/api/simple.dart' as core;
import '../../widgets/ds_action_sheet.dart';

/// Longest message text sent with a report (the server keeps ≤ 4000).
const kReportTextMax = 4000;

/// Sends a report (faked in tests): reported identity, reason, text.
final reportCallProvider = Provider<Future<void> Function(String peer, String reason, String? text)>((ref) {
  return (peer, reason, text) async {
    final base = ref.read(netServiceProvider).httpBaseUrl;
    if (base == null) throw StateError('offline');
    await core.reportPerson(serverBaseUrl: base, reportedIdentityHex: peer, reason: reason, messageText: text);
  };
});

/// Returns true when a report went out.
Future<bool> reportPerson(
  BuildContext context,
  WidgetRef ref, {
  required String peer,
  required String name,
  String? messageText,
  String? personalChatId,
}) async {
  final l = context.l10n;
  final server = serverHostOf(ref.read(serverUrlProvider).value ?? '');
  final reason = await showDsActionSheet<String>(
    context,
    title: '${l.reportTitle(name)}\n${l.reportBody(server)}',
    actions: [
      DsSheetAction(l.reportReasonSpam, 'spam'),
      DsSheetAction(l.reportReasonAbuse, 'abuse'),
      DsSheetAction(l.reportReasonIllegal, 'illegal'),
      DsSheetAction(l.reportReasonOther, 'other'),
    ],
  );
  if (reason == null || !context.mounted) return false;
  String? text;
  final message = messageText?.trim() ?? '';
  if (message.isNotEmpty) {
    final share = await showDsActionSheet<bool>(
      context,
      title: l.reportReasonTitle,
      actions: [DsSheetAction(l.reportWithMessage, true), DsSheetAction(l.reportWithoutMessage, false)],
    );
    if (share == null || !context.mounted) return false;
    if (share) text = message.length > kReportTextMax ? message.substring(0, kReportTextMax) : message;
  }
  try {
    await ref.read(reportCallProvider)(peer, reason, text);
  } catch (_) {
    if (context.mounted) await showDsActionSheet<void>(context, title: l.reportFailed, actions: const []);
    return false;
  }
  if (!context.mounted) return true;
  final blocked = (ref.read(blockedPeersProvider).value ?? const <String>{}).contains(peer);
  if (blocked) {
    await showDsActionSheet<void>(context, title: l.reportSent, actions: const []);
    return true;
  }
  final block = await showDsActionSheet<bool>(
    context,
    title: l.reportSent,
    actions: [DsSheetAction(l.chatInfoBlock, true, destructive: true)],
  );
  if (block == true) await ref.read(peopleProvider).setBlocked(peer, true, personalChatId: personalChatId);
  return true;
}
