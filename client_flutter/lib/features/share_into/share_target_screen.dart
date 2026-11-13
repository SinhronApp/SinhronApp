// ADR-060 — "Send to…": what another app shared, which chats get it.
//
// Opened by `handleIncomingShare` (app/navigation.dart) when something
// comes in through the share menu. Saved messages first, then recent chats
// (the chat list's order), search by name, several chats at once, a
// caption (or the shared text / link, editable). Send uses the chat's own
// send paths (share_send.dart); one chat → that chat opens, several → a
// "Sent" pill. Cancel, Back or a finished send deletes the shared copies.

import 'dart:async';

import 'package:flutter/services.dart' show TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/incoming_share.dart';
import '../../core/providers/chat_providers.dart';
import '../../core/providers/people.dart' show peerAvatarsProvider, withPhotos;
import '../../core/providers/saved_messages.dart';
import '../../core/services/video_tools.dart' show VideoTooLarge;
import '../../l10n/l10n.dart';
import '../../widgets/ds_avatar.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/ds_icon.dart';
import '../../widgets/ds_search_pill.dart';
import '../../widgets/ds_shared_glyphs.dart';
import '../../widgets/ds_text_field.dart';
import '../chat_list/chat_data.dart';
import 'share_send.dart';

/// Where a share can go: Saved messages first (made on first use), then
/// every chat in the list's order, archived ones left out (as Forward).
List<ChatPreview> shareTargets(List<ChatPreview> all) => [
  savedChatEntry(all),
  ...all.where((c) => c.id != null && !c.archived && !c.saved),
];

/// Chats whose name has [query] in it (any case).
List<ChatPreview> filterShareTargets(List<ChatPreview> chats, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return chats;
  return chats.where((c) => c.name.toLowerCase().contains(q)).toList();
}

/// "3 photos", "Video", "report.pdf", "4 files" — what's being sent; null
/// for text only (the text itself is in the field).
String? shareSummary(AppL10n l, IncomingShare s) {
  final files = s.files;
  if (files.isEmpty) return null;
  final kinds = files.map(sharedKindOf).toSet();
  if (kinds.length == 1) {
    switch (kinds.first) {
      case SharedKind.photo:
        return l.sharePhotos(files.length);
      case SharedKind.video:
        return l.shareVideos(files.length);
      case SharedKind.document:
        if (files.length == 1) return files.first.name;
    }
  }
  return l.shareFiles(files.length);
}

class ShareTargetScreen extends ConsumerStatefulWidget {
  const ShareTargetScreen({super.key, required this.share, this.onSent, this.onCancel});

  final IncomingShare share;

  /// Sent to these chats (real ids, Saved messages resolved). Null → pop.
  final void Function(List<({String id, ChatPreview chat})> sent)? onSent;

  /// Cancel. Null → pop.
  final VoidCallback? onCancel;

  @override
  ConsumerState<ShareTargetScreen> createState() => _ShareTargetScreenState();
}

class _ShareTargetScreenState extends ConsumerState<ShareTargetScreen> {
  final _search = TextEditingController();
  late final TextEditingController _caption;
  late final ShareParcel _parcel;
  late final SharePlatform _platform;

  /// Picked chats, in the order they were picked.
  final _picked = <String>[];

  /// Already sent to (a retry after an error skips them).
  final _sent = <String, String>{};
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _parcel = ShareParcel(widget.share);
    _platform = ref.read(sharePlatformProvider);
    _caption = TextEditingController(text: widget.share.text);
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    _caption.dispose();
    // Sent, cancelled or swiped away: the shared copies go (what's being
    // sent is in memory by now).
    unawaited(finishShare(_platform, widget.share));
    super.dispose();
  }

  void _toggle(String id) {
    if (_busy) return;
    setState(() {
      _error = null;
      if (!_picked.remove(id)) _picked.add(id);
    });
  }

  String _errorText(AppL10n l, Object e) {
    if (e is VideoTooLarge) return l.errVideoTooLarge;
    if (e is UnsupportedError) return l.errNotEncrypted;
    if (e is ArgumentError) return l.errTooLarge;
    if (e is StateError) return l.errOffline;
    // ignore: avoid_print
    print('[sinhron] share send failed: $e');
    return l.errCouldNotSend;
  }

  Future<void> _send(List<ChatPreview> targets) async {
    if (_picked.isEmpty || _busy) return;
    final l = context.l10n;
    final send = ref.read(shareSendProvider);
    final byId = {for (final c in targets) c.id!: c};
    setState(() {
      _busy = true;
      _error = null;
    });
    for (final id in List.of(_picked)) {
      if (_sent.containsKey(id)) continue;
      try {
        _sent[id] = await send(ref, _parcel, id, _caption.text);
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = _errorText(l, e);
        });
        return;
      }
      if (!mounted) return;
    }
    final sent = [
      for (final id in _picked)
        if (byId[id] != null) (id: _sent[id]!, chat: byId[id]!),
    ];
    setState(() => _busy = false);
    final done = widget.onSent;
    if (done != null) {
      done(sent);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _cancel() {
    if (_busy) return;
    final cancel = widget.onCancel;
    if (cancel != null) {
      cancel();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    final mq = MediaQuery.of(context);
    final all = ref.watch(chatsProvider).value ?? const <ChatPreview>[];
    final targets = withPhotos(shareTargets(all), ref.watch(peerAvatarsProvider).value ?? const {});
    final shown = filterShareTargets(targets, _search.text);
    final summary = shareSummary(l, widget.share);
    final hasFiles = widget.share.files.isNotEmpty;
    final canSend = _picked.isNotEmpty && !_busy && (hasFiles || _caption.text.trim().isNotEmpty);
    return PopScope(
      canPop: !_busy,
      child: ColoredBox(
        color: tokens.bg,
        child: Padding(
          padding: EdgeInsets.only(top: mq.padding.top, bottom: mq.viewInsets.bottom > 0 ? 0 : mq.padding.bottom),
          child: Column(
            children: [
              _TopBar(title: l.shareSendTo, onCancel: _cancel),
              if (summary != null) _WhatCard(share: widget.share, summary: summary),
              DsSearchPill(key: const ValueKey('share-search'), controller: _search, hint: l.shareSearch),
              Expanded(
                child: shown.isEmpty
                    ? Center(
                        child: Text(
                          targets.length <= 1 && _search.text.isEmpty ? l.shareNoChats : l.noOtherChats,
                          style: DsText.body.copyWith(color: tokens.text3),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: DsSpace.x1h5),
                        itemCount: shown.length,
                        itemBuilder: (_, i) {
                          final c = shown[i];
                          return _ChatRow(
                            key: ValueKey('share-chat-${c.id}'),
                            chat: c,
                            checked: _picked.contains(c.id),
                            onTap: () => _toggle(c.id!),
                          );
                        },
                      ),
              ),
              _Composer(
                caption: _caption,
                hint: hasFiles ? l.shareCaptionHint : l.shareMessageHint,
                error: _error,
                label: _picked.isEmpty
                    ? l.sharePickChat
                    : _picked.length == 1
                    ? l.shareSend
                    : l.shareSendCount(_picked.length),
                busy: _busy,
                onChanged: () => setState(() => _error = null),
                onSend: canSend ? () => _send(targets) : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.title, required this.onCancel});
  final String title;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x2h5, DsSpace.x4, DsSpace.x2),
      child: Row(
        children: [
          Expanded(child: Text(title, style: DsText.headline.copyWith(color: tokens.text))),
          Semantics(
            button: true,
            child: GestureDetector(
              key: const ValueKey('share-cancel'),
              behavior: HitTestBehavior.opaque,
              onTap: onCancel,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: DsSpace.x1),
                child: Text(context.l10n.cancel, style: DsText.bodyLarge.copyWith(color: tokens.accent)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What came in: an icon and "3 photos" / the file's name.
class _WhatCard extends StatelessWidget {
  const _WhatCard({required this.share, required this.summary});
  final IncomingShare share;
  final String summary;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final kinds = share.files.map(sharedKindOf).toSet();
    final glyph = kinds.length == 1 && kinds.first == SharedKind.photo
        ? DsGlyph.gallery
        : kinds.length == 1 && kinds.first == SharedKind.video
        ? DsGlyph.video
        : DsGlyph.document;
    return Container(
      margin: const EdgeInsets.fromLTRB(DsSpace.x4, 0, DsSpace.x4, DsSpace.x2h5),
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3, vertical: DsSpace.x2h5),
      decoration: BoxDecoration(color: tokens.surface, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CustomPaint(painter: DsGlyphPainter(glyph, color: tokens.accent)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              summary,
              key: const ValueKey('share-summary'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DsText.body.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatRow extends StatelessWidget {
  const _ChatRow({super.key, required this.chat, required this.checked, required this.onTap});
  final ChatPreview chat;
  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Semantics(
      button: true,
      selected: checked,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: DsSpace.x4, vertical: DsSpace.x2),
          child: Row(
            children: [
              DsAvatar(name: chat.name, size: 42, group: chat.group, image: chat.avatar, saved: chat.saved),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  chat.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DsText.bodyLarge.copyWith(color: tokens.text),
                ),
              ),
              const SizedBox(width: 10),
              _CheckBox(checked: checked),
            ],
          ),
        ),
      ),
    );
  }
}

/// The 22×22 squircle check of the member picker.
class _CheckBox extends StatelessWidget {
  const _CheckBox({required this.checked});
  final bool checked;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: checked ? tokens.accent : DsPalette.transparent,
        borderRadius: BorderRadius.circular(7),
        border: checked ? null : Border.all(color: tokens.text4, width: 1.5),
      ),
      child: checked
          ? Center(
              child: SizedBox(
                width: 13,
                height: 13,
                child: CustomPaint(painter: DsCheckmarkGlyph(color: tokens.accentText)),
              ),
            )
          : null,
    );
  }
}

/// Caption (or message) field, the error line, the Send button.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.caption,
    required this.hint,
    required this.error,
    required this.label,
    required this.busy,
    required this.onChanged,
    required this.onSend,
  });
  final TextEditingController caption;
  final String hint;
  final String? error;
  final String label;
  final bool busy;
  final VoidCallback onChanged;
  final VoidCallback? onSend;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final style = DsText.body.copyWith(color: tokens.text);
    return Container(
      decoration: BoxDecoration(
        color: tokens.bg,
        border: Border(top: BorderSide(color: tokens.divider, width: 0.5)),
      ),
      padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x2h5, DsSpace.x3h5, DsSpace.x1h5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3, vertical: DsSpace.x2),
            decoration: BoxDecoration(color: tokens.bgSoft, borderRadius: BorderRadius.circular(12)),
            child: Stack(
              children: [
                if (caption.text.isEmpty)
                  IgnorePointer(child: Text(hint, style: style.copyWith(color: tokens.text3))),
                DsPlainField(
                  key: const ValueKey('share-caption'),
                  controller: caption,
                  style: style,
                  minLines: 1,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => onChanged(),
                ),
              ],
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: DsSpace.x2),
              child: Text(
                error!,
                key: const ValueKey('share-error'),
                style: DsText.footnote.copyWith(color: tokens.danger),
              ),
            ),
          const SizedBox(height: DsSpace.x2h5),
          DsButton(
            key: const ValueKey('share-send'),
            label: label,
            variant: DsButtonVariant.primary,
            loading: busy,
            onPressed: onSend,
          ),
        ],
      ),
    );
  }
}
