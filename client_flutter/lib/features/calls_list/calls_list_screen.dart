// Calls tab — call history list.
//
// No dedicated design file in the handoff (calls.jsx only covers the 4
// in-call screens). Built from spec §10 + native iOS Phone.app pattern.
//
// Layout:
//   1. DsHeader-style: avatar + "Calls" title + search icon + new-call icon
//   2. Filter strip: All · Missed (DsFilterPill)
//   3. Date-sectioned call rows: Today / Yesterday / Earlier
//      Row: avatar + name + call-type-glyph (incoming/outgoing/missed) +
//      audio/video badge + subtitle ("12 min · audio" or "Missed · audio")
//      + time on right + info chevron
//   4. DsTabBar at the bottom with Calls active
//
// [CallsListScreen.calls] is this phone's call history (CD9
// `storageCallsList`, names from the chat list).

import 'dart:typed_data';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../widgets/ds_avatar.dart';
import '../../widgets/ds_header.dart';
import '../../widgets/ds_filter_pill.dart';
import '../../widgets/ds_icon.dart';
import '../../widgets/ds_icon_button.dart';
import '../../widgets/ds_search_pill.dart';
import '../../widgets/ds_tab_bar.dart';
import '../../widgets/ds_motion.dart';
import '../chat_list/chat_data.dart' show formatChatTime;
import '../../l10n/l10n.dart';

enum CallFilter { all, missed }

/// One call from this phone's history (CD9).
class CallEntry {
  final String chatId;
  final String name;
  final bool isGroup;
  final bool outgoing;
  final bool video;

  /// `completed` / `missed` / `declined` / another end reason.
  final String status;
  final int startedAtUnix;
  final int? durationSecs;

  const CallEntry({
    required this.chatId,
    required this.name,
    required this.outgoing,
    required this.video,
    required this.status,
    required this.startedAtUnix,
    this.isGroup = false,
    this.durationSecs,
  });
}

class CallsListScreen extends StatefulWidget {
  final ValueChanged<DsTabId>? onTabChange;

  /// This phone's history, newest first.
  final List<CallEntry> calls;

  /// My name for the header avatar.
  final String myName;

  /// My photo for the header avatar, if I set one.
  final Uint8List? myPhoto;

  /// Chat id → the other person's photo (personal chats that have one).
  final Map<String, Uint8List> photos;

  /// Unread chats for the Chats tab badge.
  final int unreadChats;

  /// ⓘ on a call (or the row, without [onCallBack]) → its chat.
  final ValueChanged<String>? onCallTap;

  /// Tap on a call → call back (same chat, same kind), like Recents on iOS.
  final void Function(String chatId, bool video)? onCallBack;

  /// "New call" in the header → pick someone to call (real mode).
  final VoidCallback? onNewCall;

  /// My photo at the top-left → My profile.
  final VoidCallback? onProfile;

  /// History still loading (it is read anew each time the tab opens): the
  /// list stays empty and its rows play their entrance once they arrive,
  /// like Chats / Contacts / Settings.
  final bool loading;

  const CallsListScreen({
    super.key,
    this.onTabChange,
    required this.calls,
    required this.myName,
    this.myPhoto,
    this.photos = const {},
    this.unreadChats = 0,
    this.onCallTap,
    this.onCallBack,
    this.onNewCall,
    this.onProfile,
    this.loading = false,
  });

  @override
  State<CallsListScreen> createState() => _CallsListScreenState();
}

class _CallsListScreenState extends State<CallsListScreen> {
  CallFilter _filter = CallFilter.all;

  /// Tech-debt 2.34 — search by name, under the header.
  bool _searching = false;
  final _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final mq = MediaQuery.of(context);
    final all = [for (final c in widget.calls) _Call.from(context, c)];
    final q = _searching ? _query.text.trim().toLowerCase() : '';
    final filtered = [
      for (final c in all)
        if ((_filter == CallFilter.all || c.kind == _CallKind.missed) && (q.isEmpty || c.name.toLowerCase().contains(q))) c,
    ];

    // Group by date section.
    final sections = <_DateSection, List<_Call>>{};
    for (final call in filtered) {
      sections.putIfAbsent(call.section, () => []).add(call);
    }

    // While loading: nothing yet — the rows animate in when the history arrives.
    final children = <Widget>[];
    if (!widget.loading && filtered.isEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(DsSpace.x6, DsSpace.x6, DsSpace.x6, 0),
          child: Text(
            q.isNotEmpty ? context.l10n.noResults(_query.text.trim()) : context.l10n.callsEmpty,
            textAlign: TextAlign.center,
            style: DsText.callout.copyWith(color: tokens.text3),
          ),
        ),
      );
    }
    for (final entry in sections.entries) {
      children.add(
        _SectionHeader(
          label: switch (entry.key) {
            _DateSection.today => context.l10n.today,
            _DateSection.yesterday => context.l10n.yesterday,
            _DateSection.earlier => context.l10n.callsEarlier,
          },
        ),
      );
      for (var i = 0; i < entry.value.length; i++) {
        final call = entry.value[i];
        final id = call.chatId;
        children.add(
          _CallRow(
            call: call,
            photo: widget.photos[id],
            isLast: i == entry.value.length - 1,
            onTap: widget.onCallBack != null
                ? () => widget.onCallBack!(id, call.video)
                : (widget.onCallTap == null ? null : () => widget.onCallTap!(id)),
            onInfo: widget.onCallTap == null ? null : () => widget.onCallTap!(id),
          ),
        );
      }
    }

    return ColoredBox(
      color: tokens.bg,
      child: Padding(
        padding: EdgeInsets.only(top: mq.padding.top),
        child: Column(
          children: [
            _Header(
              myName: widget.myName,
              myPhoto: widget.myPhoto,
              onProfile: widget.onProfile,
              onSearch: () => setState(() {
                _searching = !_searching;
                if (!_searching) _query.clear();
              }),
              onNewCall: widget.onNewCall,
            ),
            // Slides open under the header with room before the filters,
            // instead of popping in flush against them.
            DsReveal(
              open: _searching,
              child: Padding(
                padding: const EdgeInsets.only(bottom: DsSpace.x2),
                child: DsSearchPill(
                  key: const ValueKey('calls-search'),
                  controller: _query,
                  hint: context.l10n.searchCalls,
                  autofocus: true,
                ),
              ),
            ),
            _Filters(
              active: _filter,
              onSelect: (f) => setState(() => _filter = f),
            ),
            Expanded(
              child: DsAppearScope(
                // A fresh scope when the history arrives, so its rows play
                // the entrance instead of just being there.
                key: ValueKey(widget.loading),
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(0, DsSpace.x1, 0, DsSpace.x3),
                  children: dsStaggered(children),
                ),
              ),
            ),
            DsTabBar(
              active: DsTabId.calls,
              items: [
                DsTabItem(
                  id: DsTabId.chats,
                  label: context.l10n.tabChats,
                  icon: DsIconShape.tabChats,
                  badge: widget.unreadChats,
                ),
                DsTabItem(id: DsTabId.calls, label: context.l10n.tabCalls, icon: DsIconShape.tabCalls),
                DsTabItem(id: DsTabId.contacts, label: context.l10n.tabContacts, icon: DsIconShape.tabContacts),
                DsTabItem(id: DsTabId.settings, label: context.l10n.tabSettings, icon: DsIconShape.tabSettings),
              ],
              safeBottomPadding: EdgeInsets.only(bottom: mq.padding.bottom),
              onSelect: widget.onTabChange,
            ),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Header — avatar + Calls + search + new-call
// ═════════════════════════════════════════════════════════════════════

class _Header extends StatelessWidget {
  final String myName;

  /// The search field under the header on / off; "new call".
  final VoidCallback? onSearch;
  final VoidCallback? onNewCall;
  final Uint8List? myPhoto;
  final VoidCallback? onProfile;
  const _Header({
    required this.myName,
    this.myPhoto,
    this.onSearch,
    this.onNewCall,
    this.onProfile,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x1h5, DsSpace.x3, DsSpace.x3),
      child: Row(
        children: [
          DsMyAvatar(name: myName, image: myPhoto, onTap: onProfile),
          const SizedBox(width: 12),
          Expanded(
            child: Text(context.l10n.tabCalls, style: DsType.headerTitle.copyWith(color: tokens.text)),
          ),
          if (onSearch != null)
            DsIconButton(key: const ValueKey('calls-search-toggle'), shape: DsIconShape.search, onTap: onSearch),
          // "New call" — phone-plus, custom-painted (DsIconShape doesn't
          // have it; use call + on-top + glyph styled via Stack)
          if (onNewCall != null)
            Padding(
              padding: const EdgeInsets.only(left: DsSpace.x1),
              child: GestureDetector(
                key: const ValueKey('calls-new-call'),
                behavior: HitTestBehavior.opaque,
                onTap: onNewCall,
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      // Status 223 — system icons (owner: "the handset looks hand-drawn").
                      child: Icon(CupertinoIcons.phone_badge_plus, size: 22, color: tokens.text),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}


// ═════════════════════════════════════════════════════════════════════
// Filters strip
// ═════════════════════════════════════════════════════════════════════

class _Filters extends StatelessWidget {
  final CallFilter active;
  final ValueChanged<CallFilter> onSelect;
  const _Filters({required this.active, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(DsSpace.x4, 0, DsSpace.x4, DsSpace.x2h5),
      child: Row(
        children: [
          DsFilterPill(
            label: context.l10n.folderAll,
            active: active == CallFilter.all,
            onTap: () => onSelect(CallFilter.all),
          ),
          const SizedBox(width: 6),
          DsFilterPill(
            label: context.l10n.callsMissed,
            active: active == CallFilter.missed,
            // Status 223 (owner: "it still says how many, I saw them long
            // ago") — no running count on the filter, as in Telegram.
            onTap: () => onSelect(CallFilter.missed),
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Section header & call row
// ═════════════════════════════════════════════════════════════════════

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x6, DsSpace.x3, DsSpace.x6, DsSpace.x1h5),
      child: Text(
        label.toUpperCase(),
        style: DsText.caption.copyWith(fontWeight: FontWeight.w700, color: tokens.text3),
      ),
    );
  }
}

class _CallRow extends StatelessWidget {
  final _Call call;
  final bool isLast;
  final VoidCallback? onTap;
  final VoidCallback? onInfo;
  final Uint8List? photo;
  const _CallRow({required this.call, required this.isLast, this.onTap, this.onInfo, this.photo});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final isMissed = call.kind == _CallKind.missed;
    final dirColor = isMissed ? DsPalette.danger : tokens.text3;
    final nameColor = isMissed ? DsPalette.danger : tokens.text;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x2h5, DsSpace.x4, DsSpace.x2h5),
            child: Row(
              children: [
                DsAvatar(name: call.name, size: 42, group: call.isGroup, image: photo),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              call.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: DsText.bodyLarge.copyWith(fontWeight: FontWeight.w600, color: nameColor),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          SizedBox(
                            width: 13,
                            height: 13,
                            child: Icon(
                              call.kind == _CallKind.outgoing ? CupertinoIcons.arrow_up_right : CupertinoIcons.arrow_down_left,
                              size: 13,
                              color: dirColor,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              call.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: DsText.footnote.copyWith(color: tokens.text3),
                            ),
                          ),
                          const SizedBox(width: 6),
                          SizedBox(
                            width: 12,
                            height: 12,
                            child: Icon(
                              call.video ? CupertinoIcons.video_camera : CupertinoIcons.phone,
                              size: 13,
                              color: tokens.text3,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Text(call.time, style: DsText.subhead.copyWith(height: 1.0, color: tokens.text3)),
                const SizedBox(width: 4),
                Semantics(
                  button: onInfo != null,
                  label: onInfo == null ? null : context.l10n.callsOpenChat,
                  child: GestureDetector(
                    key: ValueKey('call-info-${call.chatId}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: onInfo,
                    // A finger-sized target around the small ⓘ.
                    child: SizedBox(
                      width: 36,
                      height: 36,
                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: Icon(CupertinoIcons.info_circle, size: 20, color: tokens.accent),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (!isLast) Positioned(left: 70, right: 0, bottom: 0, height: 0.5, child: ColoredBox(color: tokens.divider)),
        ],
      ),
    );
  }
}




// ═════════════════════════════════════════════════════════════════════
// Rows
// ═════════════════════════════════════════════════════════════════════

enum _CallKind { incoming, outgoing, missed }

enum _DateSection {
  today('Today'),
  yesterday('Yesterday'),
  earlier('Earlier');

  final String label;
  const _DateSection(this.label);
}

class _Call {
  final String chatId;
  final String name;
  final _CallKind kind;
  final bool video;
  final bool isGroup;
  final String subtitle; // "12 min · audio" / "Missed · audio"
  final String time;
  final _DateSection section;

  const _Call({
    required this.chatId,
    required this.name,
    required this.kind,
    required this.video,
    required this.subtitle,
    required this.time,
    required this.section,
    this.isGroup = false,
  });

  /// A row for a real call: an incoming call I didn't take is missed.
  factory _Call.from(BuildContext context, CallEntry c, {DateTime? now}) {
    final l = context.l10n;
    final completed = c.status == 'completed';
    final kind = completed
        ? (c.outgoing ? _CallKind.outgoing : _CallKind.incoming)
        : (c.outgoing ? _CallKind.outgoing : _CallKind.missed);
    final what = c.video ? l.callsVideo : l.callsAudio;
    final how = switch (c.status) {
      'completed' => l.callsMinutes(((c.durationSecs ?? 0) / 60).ceil().clamp(1, 1 << 20)),
      'declined' => l.callsDeclined,
      'busy' => l.callsBusy,
      'cancelled' => l.callsCancelled,
      _ => c.outgoing ? l.callsNoAnswer : l.callsMissedOne,
    };
    final today = now ?? DateTime.now();
    final at = DateTime.fromMillisecondsSinceEpoch(c.startedAtUnix * 1000);
    final day = DateTime(at.year, at.month, at.day);
    final section = day == DateTime(today.year, today.month, today.day)
        ? _DateSection.today
        : (day == DateTime(today.year, today.month, today.day - 1) ? _DateSection.yesterday : _DateSection.earlier);
    return _Call(
      chatId: c.chatId,
      name: c.name,
      kind: kind,
      video: c.video,
      isGroup: c.isGroup,
      subtitle: '$how · $what',
      time: formatChatTime(c.startedAtUnix, now: now),
      section: section,
    );
  }
}
