// Short messages at the top of the app, shown by `AppNoticeHost`
// (lib/widgets/app_notice_host.dart) as a small pill that hides itself.
//   • [appNotice] — something that went wrong in the background ("couldn't
//     save", "no connection"), or a note. Any screen can set it; a tap or
//     the timer clears it.
//   • [showDone] — a quick confirmation ("Key copied"): a check pill.

import 'package:flutter/foundation.dart';

final ValueNotifier<String> appNotice = ValueNotifier<String>('');

/// The latest confirmation. [seq] changes on every call, so the same text
/// twice in a row shows twice.
final ValueNotifier<({int seq, String text})> appDone = ValueNotifier((seq: 0, text: ''));

/// Confirm a finished action with a short check pill ("Key copied").
void showDone(String text) => appDone.value = (seq: appDone.value.seq + 1, text: text);
