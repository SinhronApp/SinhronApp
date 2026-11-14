// 1:1 chat view — the main "open conversation" screen. Source: design/app/chat-view.jsx.
//
// Premium-feel pass on top of base port:
//   - Dynamic bubble corner radius based on chain position (Telegram/iMessage
//     pattern: corners adjacent to next/previous same-sender bubble get small
//     4pt radius, tail corner gets 6pt, others 18pt)
//   - Out-bubble subtle gradient (accent → softer accent) instead of flat fill
//   - Reply-quote in out-bubble: 12% white overlay for glass feel
//   - Day separator: larger vertical padding for breathing room
//   - Voice waveform: 1.5pt bars (thinner, more delicate)
//   - Photo bubble: cleaner edge-to-edge + standard caption padding

import 'dart:async';
import 'dart:convert' show jsonDecode;
import 'dart:io' show File;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show LongPressGestureRecognizer, TapGestureRecognizer, kDoubleTapTimeout;
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart' show Clipboard, ClipboardData, TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../app/theme/appearance.dart';
import '../../app/theme/motion.dart';
import '../../app/theme/palette.dart';
import '../../app/adaptive.dart';
import '../../app/theme/tokens.dart';
import '../../core/contact_qr.dart';
import '../../core/haptics.dart';
import '../../core/mentions.dart';
import '../../core/rich_text.dart';
import '../../core/providers/chat_actions.dart';
import '../../core/providers/chat_messages.dart';
import '../../core/providers/chat_providers.dart';
import '../../core/providers/message_actions.dart';
import '../../core/providers/pending_media.dart';
import '../../core/providers/people.dart';
import '../../core/providers/presence.dart';
import '../../core/providers/saved_messages.dart';
import '../../widgets/ds_blur_bar.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/ds_verified_badge.dart';
import '../chat_info/chat_info_screen.dart' show chatMembersLoaderProvider, chatMembersProvider, myIdentityProvider;
import '../../core/services/video_tools.dart';
import '../../core/ui_sounds.dart';
import '../../features/chat_list/chat_data.dart' as chat_data;
import '../../src/rust/api/simple.dart' as core;
import '../../widgets/ds_action_sheet.dart';
import '../../widgets/ds_avatar.dart';
import '../../widgets/ds_empty_state.dart';
import '../../widgets/ds_icon.dart';
import '../../widgets/ds_motion.dart';
import '../../widgets/ds_spinner.dart';
import '../../widgets/ds_pressable.dart';
import '../documents/document_share.dart';
import '../media_viewer/chat_gallery.dart';
import '../media_viewer/gallery_pages.dart' show galleryRectTween;
import '../media_viewer/photo_gallery_screen.dart';
import '../verify/verify_contact.dart';
import '../voice/voice_recorder.dart';
import '../voice/waveform.dart';
import '../calls/call_screen.dart' show CallCameraSwitchGlyph;
import '../video_note/video_note_bubble.dart';
import '../video_note/video_note_recorder.dart';
import '../video_note/video_note_tools.dart';
import '../../widgets/ds_shared_glyphs.dart' show DsProgressRingPainter;
import 'encrypted_media_bubbles.dart';
import 'jumbo_emoji.dart';
import 'encrypted_photo.dart';
import 'encrypted_video.dart';
import 'forward_sheet.dart';
import 'link_preview_card.dart';
import 'message_menu.dart';
import 'select_text_sheet.dart';
import '../report/report_flow.dart';
import 'message_text.dart';
import 'rich_composer.dart';
import 'pending_media_bubble.dart';
import 'swipe_to_reply.dart';
import '../../l10n/l10n.dart';
import '../calls/active_call_provider.dart';
import '../calls/live_call_screen.dart';
import 'emoji_panel.dart';
import '../stickers/sticker_message.dart';
import '../stickers/sticker_pack_sheet.dart';
import '../stickers/sticker_store.dart';
import '../stickers/telegram_import.dart';
import '../../core/app_notice.dart';
import '../../widgets/avoid_keyboard.dart';
import '../../widgets/ds_text_field.dart';

// ═════════════════════════════════════════════════════════════════════
// Data model — sealed item types so we can compute chain positions
// ═════════════════════════════════════════════════════════════════════

enum _Side { incoming, outgoing }

enum _MsgKind { text, photo, voice, document, video, sticker }

class _Reaction {
  final String emoji;
  final int count;

  /// I reacted with this emoji (chip highlighted, tap removes it).
  final bool mine;
  const _Reaction(this.emoji, this.count, {this.mine = false});
}

class _ReplyQuote {
  final String name;
  final String text;

  /// Wire id of the quoted message — tap scrolls to it.
  final String? wireId;
  const _ReplyQuote({required this.name, required this.text, this.wireId});
}

sealed class _Item {
  const _Item();
}

class _Day extends _Item {
  final String label;
  const _Day(this.label);
}

class _Msg extends _Item {
  final _Side side;
  final _MsgKind kind;
  final String? text; // text content for text msg; caption for photo

  /// ADR-070 — [text]'s formatting; null = an older app's message (its
  /// 0.6.0 markers are read).
  final List<TextEntity>? entities;
  final String? time;

  /// Delivery status of my messages ([MsgStatus]); 3 = read.
  final int status;
  final _ReplyQuote? reply;
  final List<_Reaction>? reactions;

  /// ADR-017 — encrypted media envelope JSON (real photo); null for
  /// text and for the demo mock list.
  final String? mediaJson;

  /// Stored message id (live chats) — stable widget key.
  final String? id;

  /// ADR-019 — wire id (replies / reactions / edits address it).
  final String? wireId;
  final bool edited;

  /// Deleted for everyone — rendered as a tombstone.
  final bool deleted;

  /// ADR-018 — sender-built link preview of a text message.
  final String? linkJson;

  /// Photos sent as one album (≥2): their media JSON, ids and wire ids,
  /// oldest first. [mediaJson]/[id]/[wireId] are the first photo's.
  final List<String>? albumJsons;
  final List<String>? albumIds;
  final List<String?>? albumWires;

  /// Disappearing message (⏱ in the meta) — §6 item 51.
  final bool expiring;

  /// Group chats (tech-debt 2.22): author's identity key and the name to
  /// show above their bubbles; null in 1:1 chats and for my messages.
  final String? senderId;
  final String? senderName;

  /// When it was sent (unix s) — edit / delete for everyone only within
  /// [kEditWindow]. Null for demo bubbles.
  final int? sentTs;
  const _Msg({
    required this.side,
    this.kind = _MsgKind.text,
    this.text,
    this.entities,
    this.time,
    this.status = MsgStatus.sent,
    this.reply,
    this.reactions,
    this.mediaJson,
    this.id,
    this.wireId,
    this.edited = false,
    this.deleted = false,
    this.linkJson,
    this.albumJsons,
    this.albumIds,
    this.albumWires,
    this.expiring = false,
    this.senderId,
    this.senderName,
    this.sentTs,
    this.replyJson,
  });

  /// The stored reply quote, sent again with a retry (status 211).
  final String? replyJson;

  /// Status 211 — mine and not sent: "Retry" under it and in its menu
  /// (not an album: its parts went one by one).
  bool get retryable => isOut && !deleted && status == MsgStatus.failed && wireId != null && albumIds == null;

  /// The text with its formatting (markers of an older app's message read).
  FormattedText get formatted =>
      entities == null ? FormattedText.legacy(text ?? '') : FormattedText(text ?? '', entities!).normalized();

  /// Every stored row this bubble stands for (an album is several).
  List<String> get rowIds => albumIds ?? [?id];

  /// A round video message (ADR-048) — drawn as a bare circle.
  bool get round => kind == _MsgKind.video && !deleted && isVideoNoteJson(mediaJson);

  bool get read => status >= MsgStatus.read;
  bool get isOut => side == _Side.outgoing;

  /// Still inside the edit / delete-for-everyone window (tech-debt 2.22).
  bool get changeable {
    final ts = sentTs;
    if (ts == null) return true;
    return DateTime.now().millisecondsSinceEpoch ~/ 1000 - ts <= kEditWindow.inSeconds;
  }
}

/// "Unread messages" divider where the unread part starts.
class _UnreadDivider extends _Item {
  const _UnreadDivider();
}

/// Outgoing media still encrypting/uploading (shown after the history).
class _Pending extends _Item {
  final PendingMedia item;
  const _Pending(this.item);
}

/// Centered system line ("Messages now disappear after 1 day").
class _System extends _Item {
  final String id;
  final String text;
  const _System(this.id, this.text);
}

class _Typing extends _Item {
  const _Typing();
}

// ═════════════════════════════════════════════════════════════════════
// Screen
// ═════════════════════════════════════════════════════════════════════

/// Picks a video (camera or library); faked in tests.
typedef VideoPicker = Future<XFile?> Function(bool camera, Duration maxDuration);

final videoPickerProvider = Provider<VideoPicker>(
  (ref) => (camera, max) => ImagePicker().pickVideo(
    source: camera ? ImageSource.camera : ImageSource.gallery,
    maxDuration: max,
  ),
);

class ChatViewScreen extends ConsumerStatefulWidget {
  /// The persisted chat: messages come from `messagesProvider(chatId)` and
  /// the composer's send button persists outgoing text into SQLite. (Null
  /// shows an empty message area.)
  final String? chatId;
  final String contactName;
  final String status;
  final VoidCallback? onBack;
  final VoidCallback? onCall;
  final VoidCallback? onVideo;
  final VoidCallback? onContactInfo;

  /// "Message" on a shared contact card: start / open a chat with them.
  final ValueChanged<ContactQr>? onOpenContact;

  /// Open scrolled to this message (wire id) and tint it — a search hit.
  final String? openAtWireId;

  const ChatViewScreen({
    super.key,
    this.chatId,
    this.openAtWireId,
    this.contactName = '',
    // Sinhron never shows presence (backlog §6 item 52) — empty unless a
    // demo passes one.
    this.status = '',
    this.onBack,
    this.onCall,
    this.onVideo,
    this.onContactInfo,
    this.onOpenContact,
  });

  @override
  ConsumerState<ChatViewScreen> createState() => _ChatViewScreenState();
}

class _ChatViewScreenState extends ConsumerState<ChatViewScreen> {
  String? _liveName;
  String get _name {
    final n = _liveName;
    return n == null || n.isEmpty ? widget.contactName : n;
  }

  /// ADR-070 — the composer keeps formatting (WYSIWYG, Telegram markers).
  late final RichTextController _draft = RichTextController();
  final ScrollController _scroll = ScrollController();
  bool _stickersOpen = false;

  /// ADR-017 — attach panel (Camera / Photos / Document) above composer.
  bool _attachOpen = false;

  /// Voice recording in progress (composer swaps to the recording bar).
  VoiceRecorder? _recorder;
  Timer? _recTicker;

  /// ADR-048 — the mic button is a camera: holding it records a round
  /// video message. A tap switches (Telegram); remembered while the app runs.
  static bool _lastVideoMode = false;
  bool _videoMode = _lastVideoMode;

  /// A round video message being recorded (the circle overlay is up).
  VideoNoteRecorder? _videoRecorder;

  /// "Hold to record…, tap for…" — shown for a moment after a tap.
  String? _micHint;
  Timer? _micHintTimer;

  /// Last media error shown above the composer (permission denied, file
  /// too large, not an encrypted chat…). Cleared on next action.
  String? _mediaError;

  /// Captured in initState — `ref` is off-limits in dispose().
  late final ChatActions _actions = ref.read(chatActionsProvider);
  late final OpenChat _openChat = ref.read(openChatProvider.notifier);
  late final MessageActions _msgActions = ref.read(messageActionsProvider);
  late final Haptics _haptics = ref.read(hapticsProvider);
  late final UiSounds _sounds = ref.read(uiSoundsProvider);
  String _savedDraft = '';

  final FocusNode _composerFocus = FocusNode();

  /// Composer modes (ADR-019): answering a message / editing my own.
  final ValueNotifier<ReplyTarget?> _reply = ValueNotifier(null);
  final ValueNotifier<_Msg?> _editing = ValueNotifier(null);

  /// Selection mode — selected message ids (empty = off).
  Set<String> _selected = {};

  /// Unread count when the chat was opened → "Unread messages" divider.
  int _unreadAtOpen = 0;

  /// Message briefly tinted after a jump (quote / pinned bar).
  String? _highlight;
  Timer? _highlightTimer;

  /// Jump-to-message: its wire id and the key its row gets once built.
  String? _jumpTarget;
  final GlobalKey _jumpKey = GlobalKey();

  /// Newest-end button: shown when scrolled up; counts arrivals.
  final ValueNotifier<bool> _awayFromBottom = ValueNotifier(false);
  final ValueNotifier<int> _newBelow = ValueNotifier(0);
  String? _newestId;

  /// Floating day pill while scrolling.
  final ValueNotifier<String?> _floatingDay = ValueNotifier(null);
  Timer? _dayHide;
  final Set<_DayProbeState> _dayProbes = {};

  /// Ids present at first load (not animated) / to animate in once.
  Set<String>? _seenIds;
  final Set<String> _animateIds = {};

  @override
  void initState() {
    super.initState();
    _draft.addListener(_onDraftChanged);
    // The emoji panel gives way to the keyboard: a tap on the field closes it.
    _composerFocus.addListener(_onComposerFocus);
    _scroll.addListener(_maybeLoadOlder);
    _scroll.addListener(_onScroll);
    final id = widget.chatId;
    if (id != null) {
      // Restore the unsent draft (UI backlog §2 item 16).
      final chats = ref.read(chatsProvider).value ?? const <chat_data.ChatPreview>[];
      final chat = chats.where((c) => c.id == id).firstOrNull;
      final saved = FormattedText(chat?.draft ?? '', chat?.draftEntities ?? const []);
      _savedDraft = encodeDraft(saved);
      _unreadAtOpen = chat?.unread ?? 0;
      _draft.setFormatted(saved);
      // Opening a chat reads it; while it's open, pushes land read.
      Future.microtask(() {
        _openChat.set(id);
        _quietly(() => _actions.markRead(id));
        _quietly(() => _msgActions.sendReadReceipts(id));
        // Tech-debt 2.22 — the chat learns my name (once per name).
        _quietly(() => ref.read(peopleProvider).ensureShared(id));
      });
    }
  }

  /// Storage calls from lifecycle hooks must never throw into the UI
  /// (widget tests have no Rust library).
  static void _quietly(Future<void> Function() f) {
    try {
      f().catchError((_) {});
    } catch (_) {}
  }

  /// Reversed list: older history sits toward maxScrollExtent. Start the
  /// next page well before the top so scrolling never hits a wall.
  void _maybeLoadOlder() {
    final id = widget.chatId;
    // While _jumpTo walks the list it loads pages itself; scroll-driven
    // loads would keep moving the end it walks towards (review fix).
    if (id == null || !_scroll.hasClients || _jumpTarget != null) return;
    final p = _scroll.position;
    if (p.pixels >= p.maxScrollExtent - 1200) {
      ref.read(chatMessagesProvider(id).notifier).loadMore();
    }
  }

  @override
  void dispose() {
    _tapWindow?.cancel();
    final id = widget.chatId;
    if (id != null) {
      final text = encodeDraft(_draft.formatted);
      final draftChanged = text.trim() != _savedDraft.trim();
      // Deferred: providers can't change while the tree is finalizing.
      Future.microtask(() {
        _openChat.clearIf(id);
        if (draftChanged) _quietly(() => _actions.setDraft(id, text));
        _quietly(() => _msgActions.typing(id, false));
      });
    }
    _recTicker?.cancel();
    _recorder?.dispose();
    _videoRecorder?.dispose();
    _micHintTimer?.cancel();
    _highlightTimer?.cancel();
    _dayHide?.cancel();
    _draft.removeListener(_onDraftChanged);
    _draft.dispose();
    _scroll.dispose();
    _composerFocus.dispose();
    _reply.dispose();
    _editing.dispose();
    _awayFromBottom.dispose();
    _newBelow.dispose();
    _holdDelta.dispose();
    _floatingDay.dispose();
    super.dispose();
  }

  // ── Scrolling: newest-end button, floating day ─────────────────

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final away = _scroll.offset > 320;
    if (_awayFromBottom.value != away) _awayFromBottom.value = away;
    if (!away) _newBelow.value = 0;
    _updateFloatingDay();
  }

  /// Day of the topmost visible bubble, shown in a pill while scrolling.
  void _updateFloatingDay() {
    final list = _listKey.currentContext?.findRenderObject() as RenderBox?;
    if (list == null || !list.attached) return;
    final top = list.localToGlobal(Offset.zero).dy;
    String? day;
    var best = double.infinity;
    for (final p in _dayProbes) {
      final box = p.context.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) continue;
      final y = box.localToGlobal(Offset.zero).dy;
      // Bottom edge below the list top = visible; pick the highest.
      if (y + box.size.height > top && y < best) {
        best = y;
        day = p.widget.day;
      }
    }
    if (day == null) return;
    _floatingDay.value = day;
    _dayHide?.cancel();
    _dayHide = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) _floatingDay.value = null;
    });
  }

  final GlobalKey _listKey = GlobalKey();

  void _jumpToNewest() {
    _newBelow.value = 0;
    if (!_scroll.hasClients) return;
    _scroll.animateTo(0, duration: DsMotion.of(context, DsMotion.slow), curve: DsMotion.emphasized);
  }

  /// Scroll to a message by wire id (loading older pages if needed), then
  /// tint it briefly.
  Future<void> _jumpTo(String wireId, {bool highlight = true, double alignment = 0.5, int maxPages = 20}) async {
    final id = widget.chatId;
    if (id == null) return;
    final notifier = ref.read(chatMessagesProvider(id).notifier);
    final glide = DsMotion.of(context, DsMotion.slow);
    bool loaded() => ref.read(chatMessagesProvider(id)).messages.any((r) => r.wireId == wireId);
    for (var page = 0; page < maxPages && !loaded(); page++) {
      if (!ref.read(chatMessagesProvider(id)).hasMore) break;
      await notifier.loadMore();
      // A scroll-triggered load may already be in flight (loadMore then
      // returns at once) — wait for it instead of spinning through pages.
      for (var i = 0; i < 300 && mounted && ref.read(chatMessagesProvider(id)).loadingMore; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      if (!mounted) return;
    }
    if (!mounted) return;
    if (!loaded()) {
      // Deeper than we're willing to load, or gone — say so, don't walk.
      _haptics.play(Haptic.error);
      return;
    }
    setState(() => _jumpTarget = wireId);
    // Reversed lazy list: the row isn't built until it's near the
    // viewport. Deep targets (search hits) first jump to a proportional
    // estimate, a bit short of the row; then walk older a step at a time
    // until it's built, and let ensureVisible centre it. If the estimate
    // overshot, start the walk again from the newest end.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final rows = ref.read(chatMessagesProvider(id)).messages;
    final idx = rows.indexWhere((r) => r.wireId == wireId);
    if (_jumpKey.currentContext == null && idx >= 0 && _scroll.hasClients && rows.length > 1) {
      final p = _scroll.position;
      final fromNewest = (rows.length - 1 - idx) / rows.length;
      _scroll.jumpTo((fromNewest * p.maxScrollExtent * 0.85 - p.viewportDimension).clamp(0, p.maxScrollExtent));
    }
    var restarted = false;
    for (var i = 0; i < 400 && mounted; i++) {
      await WidgetsBinding.instance.endOfFrame;
      final ctx = _jumpKey.currentContext;
      if (ctx != null && ctx.mounted) {
        await Scrollable.ensureVisible(ctx, alignment: alignment, duration: glide, curve: DsMotion.emphasized);
        break;
      }
      if (!_scroll.hasClients) break;
      final p = _scroll.position;
      if (p.pixels >= p.maxScrollExtent) {
        if (restarted) break;
        restarted = true;
        _scroll.jumpTo(0);
        continue;
      }
      _scroll.jumpTo((p.pixels + p.viewportDimension * 0.8).clamp(0, p.maxScrollExtent));
    }
    if (!mounted) return;
    if (!highlight) {
      setState(() => _jumpTarget = null);
      return;
    }
    _highlightTimer?.cancel();
    setState(() {
      _highlight = wireId;
      _jumpTarget = null;
    });
    _highlightTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _highlight = null);
    });
  }

  /// Bring the newest message into view (reversed list → offset 0).
  /// Post-frame because the new bubble lands on the next build.
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients || _scroll.offset == 0) return;
      _scroll.animateTo(0, duration: DsMotion.base, curve: Curves.easeOut);
    });
  }

  void _onDraftChanged() {
    // "Typing…" for the other side (throttled inside; off in settings
    // means nothing is sent). Not while editing an old message.
    final id = widget.chatId;
    if (id != null && _editing.value == null) {
      final typing = _draft.text.trim().isNotEmpty;
      _quietly(() => _msgActions.typing(id, typing));
    }
    // No screen-wide rebuild per keystroke: the composer button and the
    // mention picker listen to the controller themselves. (The emoji panel
    // used to close on the first character — so a picked emoji closed it.)
  }

  void _onComposerFocus() {
    if (_composerFocus.hasFocus && (_stickersOpen || _attachOpen)) {
      setState(() {
        _stickersOpen = false;
        _attachOpen = false;
      });
    }
  }

  /// Emoji panel ⇄ keyboard (owner, 2026-10-16: the panel's emoji didn't
  /// even tap).
  void _insertEmoji(String e) => _draft.value = insertEmoji(_draft.value, e);

  void _emojiBackspace() => _draft.value = deleteBackward(_draft.value);

  /// ADR-049 — a sticker tapped in the panel goes out at once (a reply
  /// being written stays its quote); the panel stays open.
  Future<void> _sendSticker(Sticker s, StickerPackView pack) async {
    final id = widget.chatId;
    if (id == null) return;
    final reply = _reply.value;
    final Uint8List data;
    try {
      data = await s.bytes();
    } catch (_) {
      if (mounted) setState(() => _mediaError = context.l10n.errCouldNotSend);
      return;
    }
    _reply.value = null;
    if (!mounted) return;
    final lang = stickerLang(context);
    _startSend(
      () => sendSticker(
        ref,
        chatId: id,
        format: s.format,
        data: data,
        emoji: s.emoji,
        packId: pack.id,
        packTitle: pack.title(lang),
        packCount: pack.stickers.length,
        reply: reply,
        preview: s.preview,
      ),
    );
  }

  /// If the caret is inside or just after a `@token`, returns the token
  /// (without `@`). null means "no active mention to autocomplete".
  String? get _activeMentionQuery {
    final text = _draft.text;
    if (text.isEmpty) return null;
    // Find the last `@` not preceded by a word character (any script).
    final match = _mentionTail.firstMatch(text);
    return match?.group(2);
  }

  static final _mentionTail = RegExp(r'(^|\s)@([\p{L}\p{N}_]*)$', unicode: true);

  /// Tech-debt 2.21 — names picked in the composer → identity keys; turned
  /// into `@[key]` tokens on send.
  final Map<String, String> _mentionKeys = {};

  /// How a mentioned person is shown: "you", their shared name, or a short key.
  String _mentionName(String key) {
    if (key == ref.read(myIdentityProvider)()) return context.l10n.you;
    return displayNameOf(key, ref.read(peerNamesProvider).value ?? const {});
  }

  void _pickMention(_ChatMentionCandidate c) {
    final text = _draft.text;
    final m = _mentionTail.firstMatch(text);
    if (m == null) return;
    final next = '${text.substring(0, m.start)}${m.group(1)}@${c.name} ';
    _mentionKeys[c.name] = c.key;
    _draft.value = TextEditingValue(text: next, selection: TextSelection.collapsed(offset: next.length));
  }

  void _toggleStickers() {
    if (_stickersOpen) {
      // Back to the keyboard (focusing closes the panel).
      _composerFocus.requestFocus();
      return;
    }
    _composerFocus.unfocus();
    setState(() {
      _stickersOpen = true;
      _attachOpen = false;
    });
  }

  /// Persist the draft text into SQLite (if `widget.chatId` is set),
  /// clear the field, and let the messages/chats providers re-read.
  /// Failures are logged but non-blocking.
  Future<void> _handleSend() async {
    final draft = _draft.formatted.trimmed();
    if (draft.text.isEmpty) return;
    final id = widget.chatId;
    if (id == null) {
      // No chat — nowhere to persist; clear the draft anyway so
      // the send button visibly responds.
      _draft.clear();
      return;
    }
    final pending = encodeMentionsFormatted(draft, _mentionKeys);
    _mentionKeys.clear();
    final editing = _editing.value;
    if (editing != null) {
      _editing.value = null;
      _draft.setFormatted(_draftBeforeEdit);
      final ok = await _quietEdit(id, editing.wireId!, pending);
      if (!ok && mounted) setState(() => _mediaError = context.l10n.couldNotEdit);
      return;
    }
    // Felt under the finger at the press, not after the network answers.
    _haptics.play(Haptic.success);
    final reply = _reply.value;
    _reply.value = null;
    _draft.clear();
    try {
      await sendMessage(ref, chatId: id, body: pending.text, reply: reply, entities: pending.entities);
      _sounds.play(UiSound.sent);
      if (_mediaError != null && mounted) setState(() => _mediaError = null);
      _scrollToBottom();
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron] sendMessage failed: $e');
      // The message is in the chat (marked not sent) and goes out by itself
      // when the connection is back — no copy back in the composer, which
      // made a second one (2026-10-16 UI audit).
      if (mounted) setState(() => _mediaError = context.l10n.sendQueuedOffline);
      _scrollToBottom();
    }
  }

  Future<bool> _quietEdit(String chatId, String wireId, FormattedText text) async {
    try {
      return await _msgActions.edit(chatId, wireId, text.text, entities: text.entities);
    } catch (_) {
      return false;
    }
  }

  /// Whatever was in the composer before "Edit" took it over.
  FormattedText _draftBeforeEdit = FormattedText.empty;

  void _startReply(_Msg m) {
    if (m.wireId == null || m.deleted) return;
    _editing.value = null;
    _reply.value = ReplyTarget(
      wireId: m.wireId!,
      // The quote is plain words (an older app's markers read away).
      snippet: m.text == null ? (m.round ? context.l10n.videoMessage : _kindLabel(context, m.kind)) : m.formatted.text,
      kind: m.kind.name,
      mine: m.isOut,
    );
    _composerFocus.requestFocus();
  }

  void _startEdit(_Msg m) {
    if (m.wireId == null || m.text == null) return;
    _reply.value = null;
    _draftBeforeEdit = _draft.formatted;
    _editing.value = m;
    final (shown, picked) = decodeForEditingFormatted(m.formatted, _mentionName);
    _mentionKeys
      ..clear()
      ..addAll(picked);
    _draft.setFormatted(shown);
    _composerFocus.requestFocus();
  }

  /// ↑ in the empty composer (hardware keyboard, ADR-076): my last text
  /// message that can still be changed goes into "Edit".
  void _editLastOwn() {
    final id = widget.chatId;
    if (id == null || _editing.value != null) return;
    final rows = ref.read(chatMessagesProvider(id)).messages;
    final last = _storedItems(rows).reversed.whereType<_Msg>().where(
      (m) => m.isOut && !m.deleted && m.wireId != null && m.kind == _MsgKind.text && m.text != null && m.changeable,
    );
    if (last.isNotEmpty) _startEdit(last.first);
  }

  void _cancelComposerMode() {
    if (_editing.value != null) _draft.setFormatted(_draftBeforeEdit);
    _reply.value = null;
    _editing.value = null;
  }

  // ── Message actions (ADR-019) ───────────────────────────────────

  static String? _mine(_Msg m) => m.reactions?.where((r) => r.mine).firstOrNull?.emoji;

  void _react(_Msg m, String? emoji) {
    final id = widget.chatId;
    if (id == null || m.wireId == null || m.deleted) return;
    _haptics.play(Haptic.selection);
    _quietly(() => _msgActions.react(id, m.wireId!, emoji));
  }

  /// Double tap: ❤️ on / off.
  void _toggleHeart(_Msg m) => _react(m, _mine(m) == '❤️' ? null : '❤️');

  // A second tap on the same bubble within the double-tap window is the
  // heart. Counted here, not with onDoubleTap, which would hold every single
  // tap (links, quotes, the link card) back by that window.
  String? _tappedId;
  Timer? _tapWindow;

  void _tapBubble(_Msg m) {
    _tapWindow?.cancel();
    if (m.id != null && _tappedId == m.id) {
      _tappedId = null;
      _toggleHeart(m);
      return;
    }
    _tappedId = m.id;
    // A little over the system window: this one runs to the second finger's lift.
    _tapWindow = Timer(kDoubleTapTimeout + const Duration(milliseconds: 100), () => _tappedId = null);
  }

  /// Tap on a reaction chip: take it / drop it.
  void _toggleReaction(_Msg m, String emoji) => _react(m, _mine(m) == emoji ? null : emoji);

  /// Status 213 — "Message info": when it went, and when each person got
  /// and read it. Older messages (before this) show only the status.
  Future<void> _showInfo(_Msg m) async {
    final wire = m.wireId;
    if (wire == null) return;
    final l = context.l10n;
    List<core.StoredReceipt> got;
    try {
      got = await ref.read(messageStoreProvider).receiptsFor(wire);
    } catch (_) {
      got = const [];
    }
    if (!mounted) return;
    String at(int? ts) => ts == null ? '' : _infoTime(ts.toInt());
    final rows = <(String, String)>[if (m.sentTs != null) (l.msgInfoSent, at(m.sentTs))];
    if (_isGroupChat) {
      final names = ref.read(peerNamesProvider).value ?? const <String, String>{};
      final me = ref.read(myIdentityProvider)();
      final members = (ref.read(chatMembersProvider(widget.chatId!)).value ?? const <String>[]).where((p) => p != me);
      final byPeer = {for (final r in got) r.peer: r};
      for (final p in {...members, ...byPeer.keys}) {
        final r = byPeer[p];
        rows.add((
          displayNameOf(p, names),
          r?.readAt != null
              ? '${l.msgInfoRead} ${at(r!.readAt)}'
              : r?.deliveredAt != null
              ? '${l.msgInfoDelivered} ${at(r!.deliveredAt)}'
              : l.msgInfoNotYet,
        ));
      }
    } else {
      final r = got.firstOrNull;
      rows.add((l.msgInfoDelivered, r?.deliveredAt != null ? at(r!.deliveredAt) : (m.status >= MsgStatus.delivered ? '✓' : '—')));
      rows.add((l.msgInfoRead, r?.readAt != null ? at(r!.readAt) : (m.read ? '✓' : '—')));
    }
    await showDsActionSheet<void>(
      context,
      title: l.msgInfo,
      header: _InfoRows(rows: rows),
      actions: const [],
      cancelLabel: l.done,
    );
  }

  /// "14:05" today, "Yesterday, 14:05" / "Apr 12, 14:05" before.
  static String _infoTime(int ts) {
    final t = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    final now = DateTime.now();
    final today = t.year == now.year && t.month == now.month && t.day == now.day;
    return today ? chat_data.formatMessageTime(ts) : '${chat_data.formatChatTime(ts)}, ${chat_data.formatMessageTime(ts)}';
  }

  /// Status 211 — send a message that didn't go again (same wire id).
  void _retry(_Msg m) {
    final id = widget.chatId;
    final wire = m.wireId;
    if (id == null || wire == null) return;
    _haptics.play(Haptic.selection);
    _quietly(
      () => _msgActions.retrySend(
        id,
        wireId: wire,
        text: m.text ?? '',
        mediaJson: m.kind == _MsgKind.text ? null : m.mediaJson,
        replyJson: m.replyJson,
        entitiesJson: m.kind == _MsgKind.text ? m.formatted.entitiesJson : null,
      ),
    );
  }

  Future<void> _openMenu(_Msg m, BuildContext bubbleContext) async {
    final id = widget.chatId;
    final box = bubbleContext.findRenderObject() as RenderBox?;
    if (id == null || box == null || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    FocusManager.instance.primaryFocus?.unfocus();
    _haptics.play(Haptic.menu);
    final pinned = _pinnedWire;
    // In a message request nothing that tells them I read it: no
    // reactions, replies or pins until it's accepted (review fix).
    final request = (ref.read(chatsProvider).value ?? const [])
        .any((c) => c.id == widget.chatId && c.request);
    final live = m.wireId != null && !m.deleted && !request;
    // Still waiting — no connection, or the server hasn't confirmed it:
    // it can be called back (owner, 2026-10-18).
    final waiting =
        m.isOut &&
        !m.deleted &&
        m.id != null &&
        m.wireId != null &&
        m.albumIds == null &&
        (m.status == MsgStatus.sending || m.status == MsgStatus.failed);
    final choice = await showMessageMenu(
      context,
      origin: rect,
      alignRight: m.isOut,
      bubble: _Bubble(msg: m, isFirstInChain: true, isLastInChain: true, bare: true),
      reactions: live ? kQuickReactions : const [],
      myReaction: _mine(m),
      items: [
        if (m.retryable) MessageMenuItem('retry', context.l10n.retrySend),
        // Status 213 — when it was delivered and read (a group: by whom).
        if (live && m.isOut && m.status >= MsgStatus.sent && !_savedChat) MessageMenuItem('info', context.l10n.msgInfo),
        if (waiting) MessageMenuItem('cancel-send', context.l10n.cancelSending, destructive: true),
        if (live) MessageMenuItem('reply', context.l10n.reply),
        if (!m.deleted && (m.text?.isNotEmpty ?? false)) MessageMenuItem('copy', context.l10n.copy),
        if (!m.deleted && (m.text?.isNotEmpty ?? false)) MessageMenuItem('select-text', context.l10n.selectText),
        if (!m.deleted) MessageMenuItem('forward', context.l10n.forward),
        // ADR-055 — a copy into Saved messages, one tap.
        if (!m.deleted && !_savedChat) MessageMenuItem('save', context.l10n.saveToSaved),
        if (live)
          MessageMenuItem(
            pinned == m.wireId ? 'unpin' : 'pin',
            pinned == m.wireId ? context.l10n.unpin : context.l10n.pin,
          ),
        if (live && m.isOut && m.kind == _MsgKind.text && m.text != null && m.changeable)
          MessageMenuItem('edit', context.l10n.edit),
        MessageMenuItem('select', context.l10n.select),
        // ADR-037 — someone else's message can be reported (also in a request).
        if (!m.isOut && !m.deleted && _authorOf(m) != null) MessageMenuItem('report', context.l10n.reportAction),
        MessageMenuItem('delete', context.l10n.delete, destructive: true),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case MenuReaction(:final emoji):
        _react(m, emoji);
      case MenuAction(id: 'reply'):
        _startReply(m);
      case MenuAction(id: 'copy'):
        // Plain words for other apps; the formatting comes back if it's
        // pasted into a Sinhron composer (ADR-070).
        final shown = _displayed(m);
        RichClipboard.remember(shown);
        await Clipboard.setData(ClipboardData(text: shown.text));
        _haptics.play(Haptic.success);
      case MenuAction(id: 'select-text'):
        await showSelectTextSheet(context, _displayed(m));
      case MenuAction(id: 'forward'):
        await _forward([m]);
      case MenuAction(id: 'save'):
        await _saveToSaved([m]);
      case MenuAction(id: 'pin'):
        _quietly(() => _msgActions.pin(id, m.wireId));
      case MenuAction(id: 'unpin'):
        _quietly(() => _msgActions.pin(id, null, unpinning: m.wireId));
      case MenuAction(id: 'edit'):
        _startEdit(m);
      case MenuAction(id: 'retry'):
        _retry(m);
      case MenuAction(id: 'info'):
        await _showInfo(m);
      case MenuAction(id: 'cancel-send'):
        _haptics.play(Haptic.selection);
        _quietly(() => _msgActions.cancelSend(id, id: m.id!, wireId: m.wireId!, status: m.status));
      case MenuAction(id: 'select'):
        if (m.id != null) setState(() => _selected = {m.id!});
      case MenuAction(id: 'delete'):
        await _confirmDelete([m]);
      case MenuAction(id: 'report'):
        final author = _authorOf(m);
        if (author == null) return;
        await reportPerson(
          context,
          ref,
          peer: author,
          name: displayNameOf(author, ref.read(peerNamesProvider).value ?? const <String, String>{}),
          messageText: m.text == null ? null : _displayed(m).text,
          personalChatId: _isGroupChat ? null : id,
        );
      case MenuAction():
        break;
    }
  }

  /// [m]'s formatted text with mentions as names (copy, report).
  FormattedText _displayed(_Msg m) =>
      m.formatted.replaceAllMapped(mentionToken, (x) => '@${_mentionName(x.group(1)!)}');

  /// Who wrote [m]: the sender in a group, the other person in a personal chat.
  String? _authorOf(_Msg m) {
    if (m.isOut) return null;
    if (m.senderId != null) return m.senderId;
    if (_isGroupChat) return null;
    return (ref.read(chatsProvider).value ?? const []).where((c) => c.id == widget.chatId).firstOrNull?.peerId;
  }

  /// A personal chat with someone I blocked: no composer, no calls — an
  /// "Unblock" bar instead (owner, 2026-10-18: writing and calling them
  /// still worked).
  bool get _blockedPeer {
    final id = widget.chatId;
    if (id == null) return false;
    final peer = ref.watch(
      chatsProvider.select((a) {
        final c = a.value?.where((c) => c.id == id).firstOrNull;
        return c == null || c.group ? null : c.peerId?.toLowerCase();
      }),
    );
    return peer != null && (ref.watch(blockedPeersProvider).value?.contains(peer) ?? false);
  }

  Future<void> _unblock() async {
    final id = widget.chatId;
    final chat = (ref.read(chatsProvider).value ?? const []).where((c) => c.id == id).firstOrNull;
    final peer = chat?.peerId;
    if (id == null || peer == null) return;
    try {
      await ref.read(peopleProvider).setBlocked(peer, false, personalChatId: id);
    } catch (_) {
      if (mounted) setState(() => _mediaError = context.l10n.groupActionFailed);
      return;
    }
    _quietly(() => ref.read(peopleProvider).ensureShared(id));
  }

  /// [_isRequest] as of the last list build — for bubble gestures.
  bool _requestNow = false;

  /// Tech-debt 2.27 — a chat someone else started that I haven't accepted.
  bool get _isRequest {
    final id = widget.chatId;
    if (id == null) return false;
    return ref.watch(chatsProvider.select((a) => a.value?.where((c) => c.id == id).firstOrNull?.request ?? false));
  }

  Future<void> _acceptRequest() async {
    final id = widget.chatId!;
    try {
      await ref.read(chatActionsProvider).acceptRequest(id);
    } catch (_) {
      // It used to do nothing at all (2026-10-16 UI audit).
      if (mounted) appNotice.value = context.l10n.requestAcceptFailed;
      return;
    }
    if (!mounted) return;
    // Now they may see that I read, and learn my name.
    _quietly(() => _msgActions.sendReadReceipts(id));
    _quietly(() => ref.read(peopleProvider).ensureShared(id));
  }

  /// Block the person who wrote (1:1 requests) and drop the chat. If no
  /// one could be identified, nothing is deleted and the user is told —
  /// "blocked" must never be a silent no-op (review fix).
  Future<void> _blockRequest() async {
    final id = widget.chatId!;
    // Asks first, as Block does in Chat info (it acted at once here).
    final ok = await showDsActionSheet<bool>(
      context,
      title: context.l10n.chatInfoBlockConfirm(_name),
      actions: [DsSheetAction(context.l10n.chatInfoBlock, true, destructive: true)],
    );
    if (ok != true || !mounted) return;
    final people = ref.read(peopleProvider);
    final me = ref.read(myIdentityProvider)();
    final peers = <String>{
      // Authors of their messages here are always someone else.
      for (final r in ref.read(chatMessagesProvider(id)).messages)
        if (!r.isMine && r.senderId != null) r.senderId!,
    };
    if (me != null) {
      try {
        peers.addAll(await ref.read(chatMembersLoaderProvider)(id));
      } catch (_) {}
      peers.remove(me);
    }
    var blocked = 0;
    for (final p in peers) {
      try {
        await people.setBlocked(p, true, personalChatId: id);
        blocked++;
      } catch (_) {}
    }
    if (!mounted) return;
    if (blocked == 0) {
      setState(() => _mediaError = context.l10n.requestBlockFailed);
      return;
    }
    await _deleteRequest();
  }

  Future<void> _deleteRequest() async {
    final ok = await showDsActionSheet<bool>(
      context,
      title: context.l10n.deleteChatConfirm(_name),
      actions: [DsSheetAction(context.l10n.deleteChat, true, destructive: true)],
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(chatActionsProvider).delete(widget.chatId!);
    } catch (_) {
      if (mounted) setState(() => _mediaError = context.l10n.groupActionFailed);
      return;
    }
    if (mounted) widget.onBack?.call();
  }

  /// Delete for me, or — for my own messages — for everyone.
  Future<void> _confirmDelete(List<_Msg> ms) async {
    final id = widget.chatId;
    if (id == null || ms.isEmpty) return;
    final forAll = ms.every((m) => m.isOut && m.wireId != null && !m.deleted && m.changeable);
    final wires = [
      for (final m in ms) ...(m.albumWires ?? [m.wireId]).whereType<String>(),
    ];
    final n = ms.length;
    final picked = await showDsActionSheet<String>(
      context,
      title: context.l10n.deleteMessagesConfirm(n),
      actions: [
        if (forAll) DsSheetAction(context.l10n.deleteForEveryone, 'all', destructive: true),
        DsSheetAction(context.l10n.deleteForMe, 'me', destructive: true),
      ],
    );
    if (picked == null) return;
    if (picked == 'all') {
      for (final w in wires) {
        _quietly(() => _msgActions.deleteForEveryone(id, w));
      }
    } else {
      final ids = [for (final m in ms) ...m.rowIds];
      _quietly(() => _msgActions.deleteForMe(id, ids));
    }
    if (mounted) setState(() => _selected = {});
  }

  /// ADR-055 — is this chat my Saved messages?
  bool get _savedChat => widget.chatId != null && ref.read(savedChatIdProvider).value == widget.chatId;

  Future<void> _forward(List<_Msg> ms) async {
    final all = ref.read(chatsProvider).value ?? const <chat_data.ChatPreview>[];
    final chats = [
      // ADR-055 — Saved messages first (made on first use).
      if (!_savedChat) savedChatEntry(all),
      ...all.where((c) => c.id != null && c.id != widget.chatId && !c.archived && !c.saved),
    ];
    final picked = await showForwardSheet(context, withPhotos(chats, ref.read(peerAvatarsProvider).value ?? const {}));
    if (picked == null || !mounted) return;
    final String toId;
    try {
      toId = await ref.read(savedMessagesProvider).resolve(picked.id!);
    } catch (e) {
      if (mounted) setState(() => _mediaError = context.l10n.savedMessagesFailed);
      return;
    }
    if (!mounted) return;
    await _sendCopies(ms, toId);
  }

  /// ADR-055 — "Save": a copy of [ms] in Saved messages (made if needed).
  Future<void> _saveToSaved(List<_Msg> ms) async {
    final String toId;
    try {
      toId = await ref.read(savedMessagesProvider).ensure();
    } catch (e) {
      if (mounted) setState(() => _mediaError = context.l10n.savedMessagesFailed);
      return;
    }
    if (!mounted) return;
    if (await _sendCopies(ms, toId) && mounted) showDone(context.l10n.savedToSaved);
  }

  /// Forward copies of [ms] to [toId]; false if one failed (shown above the
  /// composer).
  Future<bool> _sendCopies(List<_Msg> ms, String toId) async {
    var ok = true;
    for (final m in ms.where((m) => !m.deleted)) {
      try {
        final jsons = m.albumJsons ?? <String?>[m.mediaJson];
        for (var i = 0; i < jsons.length; i++) {
          await forwardMessage(
            ref,
            toChatId: toId,
            kind: m.kind.name,
            // ADR-070 — forwarded with its formatting.
            text: i == 0 ? m.formatted.text : '',
            entities: i == 0 ? m.formatted.entities : null,
            mediaJson: jsons[i],
          );
        }
      } catch (e) {
        if (mounted) setState(() => _mediaError = _friendlyError(context, e));
        ok = false;
        break;
      }
    }
    if (!mounted) return ok;
    setState(() => _selected = {});
    _haptics.play(Haptic.success);
    return ok;
  }

  /// ADR-070 — words that lead to another address: the same question, the
  /// real address shown with a warning.
  void _openHiddenLink(String target, String shown) => _openLink(target, hiddenBehind: shown);

  /// Links / phone numbers in messages: ask before leaving the app.
  Future<void> _openLink(String target, {String? hiddenBehind}) async {
    final isTel = target.startsWith('tel:');
    // ADR-062 — a Telegram sticker pack link: add it here instead.
    final telegram = isTel ? null : telegramPackName(target);
    final shownTarget = isTel ? target.substring(4) : (target.startsWith('mailto:') ? target.substring(7) : target);
    final picked = await showDsActionSheet<String>(
      context,
      title: hiddenBehind == null ? shownTarget : '$shownTarget\n${context.l10n.linkHiddenWarning}',
      actions: [
        if (telegram != null) DsSheetAction(context.l10n.tgPackAddToSinhron, 'stickers'),
        DsSheetAction(isTel ? context.l10n.call : context.l10n.openLink, 'open'),
        DsSheetAction(context.l10n.copy, 'copy'),
      ],
    );
    if (picked == 'stickers' && telegram != null && mounted) {
      await openTelegramPack(context, ref, telegram);
    } else if (picked == 'copy') {
      await Clipboard.setData(ClipboardData(text: shownTarget));
    } else if (picked == 'open') {
      final uri = Uri.tryParse(target);
      if (uri != null) {
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {
          if (mounted) setState(() => _mediaError = context.l10n.linkCouldNotOpen);
        }
      }
    }
  }

  void _toggleSelected(_Msg m) {
    final id = m.id;
    if (id == null) return;
    _haptics.play(Haptic.selection);
    setState(() {
      final next = {..._selected};
      if (!next.remove(id)) next.add(id);
      _selected = next;
    });
  }

  /// Full-screen gallery over every photo and video of the chat, opened
  /// at [mediaJson] (Hero from its bubble). Opens at once with the loaded
  /// history; the whole chat's list is merged in once it's read.
  void _openGallery(String mediaJson) {
    final id = widget.chatId;
    if (id == null) return;
    final group = _isGroupChat;
    final names = ref.read(peerNamesProvider).value ?? const <String, String>{};
    // Read now: the full list is named after the gallery is already open.
    final you = context.l10n.you;
    final name = _name;
    String senderOf(core.StoredMessageSummary r) => r.isMine
        ? you
        : group
        ? (r.senderId == null || r.senderId!.isEmpty ? name : displayNameOf(r.senderId!, names))
        : name;
    final items = galleryItemsOf(ref.read(chatMessagesProvider(id)).messages, senderOf: senderOf);
    final index = items.indexWhere((g) => g.mediaJson == mediaJson);
    if (index < 0) return;
    FocusManager.instance.primaryFocus?.unfocus();
    openPhotoGallery(
      context,
      items,
      index,
      actions: chatGalleryActions(
        context,
        ref,
        chatId: id,
        showInChat: (item) {
          final wire = item.wireId;
          if (wire != null) _jumpTo(wire);
        },
      ),
      allItems: () async {
        try {
          return galleryItemsOf(await ref.read(messagesProvider(id).future), senderOf: senderOf);
        } catch (_) {
          return const <GalleryItem>[]; // no storage (tests): the loaded part stays
        }
      }(),
    );
  }

  /// Disappearing messages for this chat (§6 item 51).
  Future<void> _chooseTimer() async {
    final id = widget.chatId;
    if (id == null) return;
    _haptics.play(Haptic.menu);
    final current = _msgActions.chatTimer(id);
    final picked = await showDsActionSheet<int>(
      context,
      title: context.l10n.timerSheetTitle,
      actions: [
        for (final e in kTimerChoices.keys)
          DsSheetAction(timerChoiceLabel(context.l10n, e), e, checked: e == current),
      ],
    );
    if (picked == null || picked == current) return;
    _quietly(() => _msgActions.setTimer(id, picked));
  }

  /// Wire id pinned in this chat (local, ADR-019).
  String? get _pinnedWire {
    final id = widget.chatId;
    if (id == null) return null;
    return (ref.read(chatsProvider).value ?? const <chat_data.ChatPreview>[])
        .where((c) => c.id == id)
        .firstOrNull
        ?.pinnedMsg;
  }

  /// Currently loaded messages in display order, by id.
  List<_Msg> _selectedMsgs() {
    final id = widget.chatId;
    if (id == null) return const [];
    final rows = ref.read(chatMessagesProvider(id)).messages;
    return [
      for (final it in _storedItems(rows))
        if (it is _Msg && _selected.contains(it.id)) it,
    ];
  }

  // ── Media (ADR-017) ─────────────────────────────────────────────

  /// The draft text becomes the caption of the media being sent (first
  /// item only) and is cleared.
  FormattedText _takeCaption() {
    final c = _draft.formatted.trimmed();
    if (c.text.isNotEmpty) _draft.clear();
    return c;
  }

  /// Run a media send, turning synchronous preflight errors (no MLS chat,
  /// too large, offline) into the inline error line.
  void _startSend(Future<void> Function() send) {
    try {
      unawaited(
        send().then((_) {
          if (mounted) _scrollToBottom();
        }),
      );
    } catch (e) {
      setState(() => _mediaError = _friendlyError(context, e));
    }
  }

  static String _friendlyError(BuildContext context, Object e) {
    if (e is UnsupportedError) return context.l10n.errNotEncrypted;
    if (e is ArgumentError) return context.l10n.errTooLarge;
    if (e is StateError) return context.l10n.errOffline;
    // ignore: avoid_print
    print('[sinhron] send failed: $e');
    return context.l10n.errCouldNotSend;
  }

  /// The attach panel takes the keyboard's place, like Telegram; "+" turns
  /// into "×" (owner, 2026-10-18: it opened on top of the keyboard as a
  /// floating card and the chat shrank to a strip).
  void _toggleAttach() {
    final open = !_attachOpen;
    if (open) _composerFocus.unfocus();
    setState(() {
      _attachOpen = open;
      _stickersOpen = false;
      _mediaError = null;
    });
  }

  /// Photos from the library (up to 10) or one from the camera.
  /// image_picker hands back temp files — read each and delete it right
  /// away so no plaintext copy lingers on disk (spec §11.1).
  Future<void> _attachPhotos({required bool camera}) async {
    final id = widget.chatId;
    if (id == null) return;
    setState(() {
      _attachOpen = false;
      _mediaError = null;
    });
    final picker = ImagePicker();
    // JPEG output (HEIC → JPEG) for the Rust decoder; Rust re-encodes
    // and strips EXIF/GPS anyway.
    final List<XFile> picked;
    try {
      if (camera) {
        final one = await picker.pickImage(
          source: ImageSource.camera,
          imageQuality: 95,
          maxWidth: 4096,
          maxHeight: 4096,
          requestFullMetadata: false,
        );
        picked = one == null ? const [] : [one];
      } else {
        picked = await picker.pickMultiImage(
          limit: 10,
          imageQuality: 95,
          maxWidth: 4096,
          maxHeight: 4096,
          requestFullMetadata: false,
        );
      }
    } catch (e) {
      setState(() => _mediaError = camera ? context.l10n.errCamera : context.l10n.errLibrary);
      return;
    }
    var caption = picked.isEmpty ? FormattedText.empty : _takeCaption();
    // Several photos at once travel as one album (one grid bubble).
    final albumId = picked.length > 1 ? newWireId() : '';
    final reply = _reply.value;
    _reply.value = null;
    for (final x in picked) {
      final bytes = await x.readAsBytes();
      try {
        await File(x.path).delete();
      } catch (_) {}
      final c = caption;
      caption = FormattedText.empty;
      final r = x == picked.first ? reply : null;
      _startSend(
        () => sendPhoto(ref, chatId: id, bytes: bytes, caption: c.text, captionEntities: c.entities, reply: r, albumId: albumId),
      );
    }
  }

  /// Video tile: record one with the camera or pick from the library
  /// (tech-debt 2.24).
  Future<void> _chooseVideo() async {
    final camera = await showDsActionSheet<bool>(
      context,
      actions: [
        DsSheetAction(context.l10n.recordVideo, true),
        DsSheetAction(context.l10n.videoFromLibrary, false),
      ],
    );
    if (camera == null || !mounted) return;
    await _attachVideo(camera: camera);
  }

  /// Camera recordings stop here. Clips over 16 MB are compressed to 720p
  /// before sending (~5 MB a minute), well under [kMaxMediaBytes].
  static const _kCameraVideoMax = Duration(minutes: 3);

  /// A video from the camera or the library. Metadata (duration, size)
  /// comes from the platform player; then the temp file image_picker made
  /// is deleted.
  /// One video is prepared at a time (the plugin compresses one clip at a
  /// time, and its cache is shared).
  bool _preparingVideo = false;

  Future<void> _attachVideo({required bool camera}) async {
    final id = widget.chatId;
    if (id == null || _preparingVideo) return;
    // Read providers before any await: the screen may close meanwhile.
    final picker = ref.read(videoPickerProvider);
    final tools = ref.read(videoToolsProvider);
    setState(() {
      _attachOpen = false;
      _mediaError = null;
    });
    XFile? x;
    try {
      x = await picker(camera, camera ? _kCameraVideoMax : const Duration(minutes: 10));
    } catch (_) {
      if (!mounted) return;
      setState(() => _mediaError = camera ? context.l10n.errCamera : context.l10n.errLibrary);
      return;
    }
    if (x == null) return;
    _preparingVideo = true;
    var durationMs = 0, width = 0, height = 0;
    final PreparedVideo v;
    try {
      final probe = VideoPlayerController.file(File(x.path));
      try {
        await probe.initialize();
        durationMs = probe.value.duration.inMilliseconds;
        width = probe.value.size.width.round();
        height = probe.value.size.height.round();
      } catch (_) {
        // Unknown metadata is fine — the bubble just shows less.
      } finally {
        await probe.dispose();
      }
      // Compress if large, grab a poster frame; every plaintext file is
      // deleted once the clip is in memory (tech-debt 2.24) — also when
      // the screen has closed meanwhile.
      v = await prepareVideoForSending(tools, x.path);
    } on VideoTooLarge {
      if (mounted) setState(() => _mediaError = context.l10n.errVideoTooLarge);
      return;
    } catch (_) {
      try {
        await File(x.path).delete(); // never leave the plaintext pick behind
      } catch (_) {}
      if (mounted) setState(() => _mediaError = context.l10n.errLibrary);
      return;
    } finally {
      _preparingVideo = false;
    }
    if (!mounted) return;
    final caption = _takeCaption();
    final reply = _reply.value;
    _reply.value = null;
    _startSend(
      () => sendVideo(
        ref,
        chatId: id,
        bytes: v.bytes,
        mimeType: v.mimeType,
        durationMs: durationMs,
        width: width,
        height: height,
        poster: v.poster,
        caption: caption.text,
        captionEntities: caption.entities,
        reply: reply,
      ),
    );
  }

  /// Any file from Files. file_picker copies the pick into a temp cache;
  /// clear it right after reading.
  Future<void> _attachDocument() async {
    final id = widget.chatId;
    if (id == null) return;
    setState(() {
      _attachOpen = false;
      _mediaError = null;
    });
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(withData: true);
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron] file picker failed: $e');
      setState(() => _mediaError = context.l10n.errFiles);
      return;
    } finally {
      unawaited(FilePicker.clearTemporaryFiles());
    }
    final f = result?.files.single;
    final bytes = f?.bytes;
    if (f == null || bytes == null) return;
    final caption = _takeCaption();
    _startSend(
      () => sendDocument(
        ref,
        chatId: id,
        bytes: bytes,
        fileName: f.name,
        mimeType: mimeTypeForFileName(f.name),
        caption: caption.text,
        captionEntities: caption.entities,
      ),
    );
  }

  // ── Hold-to-record (Telegram) ───────────────────────────────────

  /// Where the finger went down on the mic; null = not holding.
  Offset? _holdOrigin;
  final ValueNotifier<Offset> _holdDelta = ValueNotifier(Offset.zero);

  /// Finger lifted before the recorder finished starting.
  bool _holdReleasedEarly = false;

  /// The pointer that went down last, and the one holding the mic.
  int? _lastDownPointer;
  int? _holdPointer;

  static const _cancelDx = -120.0;
  static const _lockDy = -90.0;

  void _startHold(Offset global) {
    if (_recorder != null || _videoRecorder != null || _voiceStarting || _videoStarting != null) return;
    _holdPointer = _lastDownPointer;
    // Felt at once — the mic or camera may still take a moment.
    _haptics.play(Haptic.record);
    setState(() {
      _holdOrigin = global;
      _holdReleasedEarly = false;
      _micHint = null;
    });
    _holdDelta.value = Offset.zero;
    if (_videoMode) {
      _startVideoNote();
    } else {
      _startVoice(fromHold: true);
    }
  }

  /// Tap on the mic: voice ⇄ round video (ADR-048), with a short hint.
  void _toggleRecordMode() {
    _haptics.play(Haptic.selection);
    _micHintTimer?.cancel();
    final video = !_videoMode;
    _lastVideoMode = video;
    if (video) unawaited(CameraVideoNoteRecorder.warmUp());
    setState(() {
      _videoMode = video;
      _mediaError = null;
      _micHint = video ? context.l10n.holdToRecordVideo : context.l10n.holdToRecordVoice;
    });
    _micHintTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _micHint = null);
    });
  }

  void _onHoldMove(PointerMoveEvent e) {
    final o = _holdOrigin;
    if (o == null) return;
    final d = e.position - o;
    _holdDelta.value = d;
    if (d.dx < _cancelDx) {
      _haptics.play(Haptic.threshold);
      _endHold(cancel: true);
    } else if (d.dy < _lockDy) {
      // Locked: keeps recording hands-free; the bar shows Cancel / Send.
      _haptics.play(Haptic.record);
      setState(() => _holdOrigin = null);
    }
  }

  void _endHold({bool cancel = false}) {
    if (_holdOrigin == null) return;
    setState(() => _holdOrigin = null);
    if (_videoMode) {
      if (_videoRecorder == null) {
        _abortStarting();
        return;
      }
      _finishVideoNote(send: !cancel);
      return;
    }
    if (_recorder == null) {
      _abortStarting();
      return;
    }
    _finishVoice(send: !cancel);
  }

  /// Let go (or cancelled) while the mic / camera was still starting: the
  /// bar goes away now; the recorder is dropped once it has started.
  void _abortStarting() {
    _holdReleasedEarly = true;
    if (_voiceStarting || _videoStarting != null) {
      setState(() {
        _voiceStarting = false;
        _videoStarting = null;
        _holdOrigin = null;
      });
    }
  }

  /// The recording bar (and the circle) show from the moment the hold
  /// starts, ticking from 0:00 until the mic / camera is really on.
  bool _voiceStarting = false;
  VideoNoteRecorder? _videoStarting;

  /// A second tap while the mic is still starting started a second
  /// recorder that kept the mic (2026-10-16 UI audit).
  bool _startingVoice = false;

  Future<void> _startVoice({bool fromHold = false}) async {
    if (widget.chatId == null || _recorder != null || _startingVoice) return;
    _startingVoice = true;
    try {
      await _startVoiceOnce(fromHold: fromHold);
    } finally {
      _startingVoice = false;
    }
  }

  Future<void> _startVoiceOnce({required bool fromHold}) async {
    final rec = VoiceRecorder();
    setState(() {
      _attachOpen = false;
      _stickersOpen = false;
      _mediaError = null;
      _voiceStarting = true;
    });
    final ok = await rec.start();
    if (!ok) {
      await rec.dispose();
      if (mounted) {
        setState(() {
          _voiceStarting = false;
          _holdOrigin = null;
          _mediaError = context.l10n.errMic;
        });
      }
      return;
    }
    if (!mounted) {
      await rec.dispose();
      return;
    }
    if ((fromHold && _holdReleasedEarly) || !_voiceStarting) {
      // Let go while the mic was still starting — a tap, not a message.
      await rec.dispose();
      return;
    }
    if (!fromHold) _haptics.play(Haptic.record);
    setState(() {
      _voiceStarting = false;
      _recorder = rec;
    });
    // Only enforces the length cap — the recording bar ticks itself, so
    // the chat doesn't rebuild 5×/s while recording.
    _recTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted && rec.elapsed >= kMaxVoiceDuration) _finishVoice(send: true);
    });
  }

  Future<void> _finishVoice({required bool send}) async {
    final rec = _recorder;
    final id = widget.chatId;
    if (rec == null) return;
    _recTicker?.cancel();
    _recTicker = null;
    setState(() => _recorder = null);
    if (!send) {
      await rec.dispose();
      return;
    }
    final held = rec.elapsed;
    RecordedVoice? voice;
    try {
      voice = await rec.stop();
    } catch (_) {
      voice = null;
    } finally {
      await rec.dispose();
    }
    // A real recording that came back empty: say so — it used to vanish.
    if (voice == null && held.inMilliseconds >= 700 && mounted) {
      setState(() => _mediaError = context.l10n.errRecordingFailed);
      return;
    }
    // Sub-second taps are accidental — don't send them.
    if (voice == null || id == null || voice.durationMs < 700) return;
    final v = voice;
    _startSend(() => sendVoice(ref, chatId: id, bytes: v.bytes, durationMs: v.durationMs, waveform: v.waveform));
  }

  // ── Round video messages (ADR-048) ──────────────────────────────

  bool _startingVideo = false;

  Future<void> _startVideoNote() async {
    if (widget.chatId == null || _videoRecorder != null || _startingVideo || _preparingVideo) return;
    _startingVideo = true;
    final rec = ref.read(videoNoteRecorderProvider)();
    try {
      setState(() {
        _attachOpen = false;
        _stickersOpen = false;
        _mediaError = null;
        _videoStarting = rec;
      });
      _composerFocus.unfocus();
      final result = await rec.start();
      if (result != VideoNoteStart.started) {
        await rec.dispose();
        if (mounted) {
          setState(() {
            _videoStarting = null;
            _holdOrigin = null;
            _mediaError = result == VideoNoteStart.denied ? context.l10n.errCameraMic : context.l10n.errCamera;
          });
        }
        return;
      }
      if (!mounted || _holdReleasedEarly || _videoStarting != rec) {
        // Let go while the camera was still opening — a tap, not a message.
        await rec.dispose();
        return;
      }
      setState(() {
        _videoStarting = null;
        _videoRecorder = rec;
      });
      _recTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (mounted && rec.elapsed >= kMaxVideoNoteDuration) _finishVideoNote(send: true);
      });
    } finally {
      _startingVideo = false;
    }
  }

  Future<void> _finishVideoNote({required bool send}) async {
    final rec = _videoRecorder;
    final id = widget.chatId;
    if (rec == null) return;
    _recTicker?.cancel();
    _recTicker = null;
    setState(() {
      _videoRecorder = null;
      _holdOrigin = null;
    });
    if (!send || id == null) {
      await rec.dispose();
      return;
    }
    final held = rec.elapsed;
    RecordedVideoNote? note;
    try {
      note = await rec.stop();
    } catch (_) {
      note = null;
    } finally {
      await rec.dispose();
    }
    if (note == null) {
      // A real recording that came back empty: say so — it used to vanish.
      if (held >= kMinVideoNoteDuration && mounted) setState(() => _mediaError = context.l10n.errRecordingFailed);
      return;
    }
    if (note.durationMs < kMinVideoNoteDuration.inMilliseconds) {
      try {
        await File(note.path).delete();
      } catch (_) {}
      return;
    }
    // Read before awaiting: the screen may close while it's prepared.
    final crop = ref.read(videoNoteToolsProvider);
    final tools = ref.read(videoToolsProvider);
    final reply = _reply.value;
    _reply.value = null;
    _preparingVideo = true;
    final PreparedVideoNote p;
    try {
      p = await prepareVideoNote(crop, tools, note.path);
    } on VideoNoteCropFailed {
      // Never the uncropped camera frame (ADR-048, owner 2026-10-19).
      if (mounted) setState(() => _mediaError = context.l10n.videoNoteCropFailed);
      return;
    } catch (_) {
      if (mounted) setState(() => _mediaError = context.l10n.errCamera);
      return;
    } finally {
      _preparingVideo = false;
    }
    if (!mounted) return;
    final durationMs = note.durationMs;
    _startSend(
      () => sendVideo(
        ref,
        chatId: id,
        bytes: p.video.bytes,
        mimeType: p.video.mimeType,
        durationMs: durationMs,
        width: p.width,
        height: p.height,
        poster: p.video.poster,
        reply: reply,
        round: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The chat's current name: a renamed group, or the name a contact
    // shared after the chat opened, shows at once (it kept the name the
    // chat was opened with — 2026-10-16 UI audit).
    _liveName = ref.watch(
      chatsProvider.select(
        (v) => (v.value ?? const <chat_data.ChatPreview>[]).where((c) => c.id == widget.chatId).firstOrNull?.name,
      ),
    );
    final tokens = DsTheme.of(context);
    // Only the padding (notch / home indicator). Keyboard insets are read
    // by _KeyboardInset below so its animation doesn't rebuild the list.
    final pad = MediaQuery.paddingOf(context);

    // Esc (hardware keyboard, ADR-076): a reply / edit / selection / panel
    // goes first, then the chat closes.
    return Actions(
      actions: {DismissIntent: CallbackAction<DismissIntent>(onInvoke: (_) => _escape())},
      child: _chatBody(context, tokens, pad),
    );
  }

  void _escape() {
    if (_reply.value != null || _editing.value != null) {
      _cancelComposerMode();
    } else if (_selected.isNotEmpty) {
      setState(() => _selected = {});
    } else if (_stickersOpen || _attachOpen) {
      setState(() {
        _stickersOpen = false;
        _attachOpen = false;
      });
    } else {
      widget.onBack?.call();
    }
  }

  Widget _chatBody(BuildContext context, DsTokens tokens, EdgeInsets pad) {
    return ColoredBox(
      color: tokens.bg,
      // Edge to edge, like WhatsApp / Telegram / Signal (owner, 2026-10-18):
      // the wallpaper runs under the header and the composer, which are
      // frosted glass over it; messages scroll under both. The list is
      // padded by their measured heights.
      child: ChatWallpaper(
        chatId: widget.chatId,
        // Tap-anywhere-to-dismiss: covers the whole chat area so user can
        // close the iOS keyboard by tapping any non-input region. Bare
        // WidgetsApp doesn't provide ScaffoldMessenger / auto-dismiss.
        child: Listener(
          // Hold-to-record keeps tracking the finger after the mic button
          // is swapped for the recording bar.
          // Only the finger that holds the mic counts — a second one
          // (flip camera while recording a round video) doesn't end it.
          onPointerDown: (e) {
            if (_holdOrigin == null) _lastDownPointer = e.pointer;
          },
          onPointerMove: (e) {
            if (e.pointer == _holdPointer) _onHoldMove(e);
          },
          onPointerUp: (e) {
            if (e.pointer == _holdPointer) _endHold();
          },
          onPointerCancel: (e) {
            if (e.pointer == _holdPointer) _endHold(cancel: true);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
            child: Stack(
              children: [
                Positioned.fill(
                  child: Stack(
                      children: [
                        Positioned.fill(
                          child: MentionNames(
                            nameOf: _mentionName,
                            myKey: widget.chatId == null ? null : ref.read(myIdentityProvider)(),
                            child: HiddenLinkOpener(open: _openHiddenLink, child: _buildMessageList()),
                          ),
                        ),
                        Positioned(
                          top: _topInset + 8,
                          left: 0,
                          right: 0,
                          child: IgnorePointer(
                            child: ValueListenableBuilder<String?>(
                              valueListenable: _floatingDay,
                              builder: (_, day, _) => AnimatedOpacity(
                                opacity: day == null ? 0 : 1,
                                duration: DsMotion.of(context, DsMotion.base),
                                child: day == null ? const SizedBox.shrink() : _DaySepPill(label: day, compact: true),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 12,
                          bottom: _bottomInset + 12,
                          child: ValueListenableBuilder<bool>(
                            valueListenable: _awayFromBottom,
                            builder: (_, away, _) =>
                                _DownButton(visible: away, newCount: _newBelow, onTap: _jumpToNewest),
                          ),
                        ),
                      ],
                    ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: _MeasuredHeight(
                    onHeight: (h) => _setInsets(top: h),
                    child: DsBlurBar(
                      bottom: true,
                      child: Padding(
                        padding: EdgeInsets.only(top: pad.top),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                AnimatedSwitcher(
                  duration: DsMotion.of(context, DsMotion.fast),
                  child: _selected.isNotEmpty
                      ? _SelectionHeader(
                          key: const ValueKey('selection-header'),
                          count: _selected.length,
                          onCancel: () => setState(() => _selected = {}),
                          onCopy: () async {
                            final text = _selectedMsgs()
                                .where((m) => m.text != null)
                                .map((m) => _displayed(m).text)
                                .where((t) => t.isNotEmpty)
                                .join('\n\n');
                            await Clipboard.setData(ClipboardData(text: text));
                            if (mounted) setState(() => _selected = {});
                          },
                        )
                      : _ChatHeader(
                          key: const ValueKey('chat-header'),
                          name: _name,
                          saved: widget.chatId != null && ref.watch(savedChatIdProvider).value == widget.chatId,
                          avatar: () {
                            final peer = widget.chatId == null
                                ? null
                                : ref.watch(
                                    chatsProvider.select(
                                      (a) => a.value?.where((c) => c.id == widget.chatId).firstOrNull?.peerId,
                                    ),
                                  );
                            return peer == null ? null : ref.watch(peerAvatarsProvider).value?[peer];
                          }(),
                          // ADR-031 — a contact's "online" / "last seen", if they share it.
                          status: () {
                            final chat = widget.chatId == null
                                ? null
                                : ref.watch(
                                    chatsProvider.select((a) => a.value?.where((c) => c.id == widget.chatId).firstOrNull),
                                  );
                            final peer = chat?.peerId;
                            if (chat == null || chat.group || chat.request || peer == null) return widget.status;
                            // A value, so it redraws when "online" runs out.
                            final shown = ref.watch(
                              peerPresenceProvider.select((m) => presenceShown(context.l10n, m[peer])),
                            );
                            if (!shown.known) return widget.status;
                            return shown.online ? 'online' : shown.label;
                          }(),
                          verify: widget.chatId == null
                              ? VerifyState.unverified
                              : ref.watch(verifyStateProvider(widget.chatId!)).value ?? VerifyState.unverified,
                          timer: () {
                            final secs = widget.chatId == null
                                ? 0
                                : ref.watch(
                                    chatsProvider.select(
                                      (a) =>
                                          a.value?.where((c) => c.id == widget.chatId).firstOrNull?.disappearSecs ?? 0,
                                    ),
                                  );
                            return secs == 0 ? null : timerChoiceLabel(context.l10n, secs);
                          }(),
                          onLongPress: widget.chatId == null ? null : _chooseTimer,
                          typing:
                              widget.chatId != null &&
                              ref.watch(typingChatsProvider.select((m) => m.containsKey(widget.chatId))),
                          typingText: () {
                            final id = widget.chatId;
                            if (id == null) return null;
                            // A string, not a list: equal values don't rebuild the screen on every ping.
                            final who = ref.watch(typingPeopleProvider.select((m) => m[id]?.keys.join(' ')))?.split(' ');
                            final names = ref.watch(peerNamesProvider).value ?? const <String, String>{};
                            return typingLine(
                              context.l10n,
                              [for (final k in who ?? const <String>[]) displayNameOf(k, names)],
                              group: _isGroupChat,
                            );
                          }(),
                          onBack: widget.onBack,
                          // ADR-055 — nobody to call in Saved messages.
                          calls: !_blockedPeer && !(widget.chatId != null && ref.watch(savedChatIdProvider).value == widget.chatId),
                          onCall: widget.onCall,
                          onVideo: widget.onVideo,
                          onContactInfo: widget.onContactInfo,
                        ),
                ),
                if (widget.chatId != null) _buildPinnedBar(),
                if (widget.chatId != null) _buildOngoingCallBar(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // ADR-048 — the round video being recorded, over the chat.
                if (_videoRecorder != null || _videoStarting != null)
                  Positioned.fill(
                    child: _VideoNoteOverlay(
                      recorder: _videoRecorder ?? _videoStarting!,
                      bottomInset: _bottomInset,
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _MeasuredHeight(
                    onHeight: (h) => _setInsets(bottom: h),
                    child: DsBlurBar(
                      top: true,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                // Mention picker floats above the composer (closes the keyboard
                // would normally; we just render it on top for the demo).
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _draft,
                  builder: (_, _, _) {
                    final q = _activeMentionQuery;
                    final id = widget.chatId;
                    if (q == null || id == null || !_isGroupChat) return const SizedBox.shrink();
                    final me = ref.read(myIdentityProvider)();
                    final names = ref.read(peerNamesProvider).value ?? const <String, String>{};
                    final candidates = [
                      for (final key in ref.watch(chatMembersProvider(id)).value ?? const <String>[])
                        if (key != me) _ChatMentionCandidate(name: displayNameOf(key, names), key: key),
                    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
                    return _ChatMentionPicker(query: q, candidates: candidates, onPick: _pickMention);
                  },
                ),
                if (_mediaError != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(DsSpace.x4, 0, DsSpace.x4, DsSpace.x1h5),
                    child: Text(
                      _mediaError!,
                      key: const ValueKey('media-error'),
                      style: DsText.subhead.copyWith(color: DsPalette.alert),
                    ),
                  )
                else if (_micHint != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(DsSpace.x4, 0, DsSpace.x4, DsSpace.x1h5),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        _micHint!,
                        key: const ValueKey('mic-hint'),
                        style: DsText.subhead.copyWith(color: DsTheme.of(context).text3),
                      ),
                    ),
                  ),
                _ComposerModeBar(
                  reply: _reply,
                  editing: _editing,
                  contactName: _name,
                  onCancel: _cancelComposerMode,
                ),
                // Composer pushed above the on-screen keyboard via
                // `viewInsets.bottom`. Without this, the input is hidden under
                // the keyboard on bare WidgetsApp (no Scaffold + no
                // resizeToAvoidBottomInset).
                if (_blockedPeer && !_isRequest)
                  _BlockedBar(name: _name, onUnblock: _unblock)
                else if (_isRequest)
                  _RequestBar(
                    name: _name,
                    canBlock: !_isGroupChat,
                    onAccept: _acceptRequest,
                    onBlock: _blockRequest,
                    onDelete: _deleteRequest,
                  )
                else if (_notMember)
                  _NotMemberBar(onDelete: _deleteRequest)
                else if (_selected.isNotEmpty)
                  _SelectionBar(
                    onDelete: () => _confirmDelete(_selectedMsgs()),
                    onForward: () => _forward(_selectedMsgs()),
                  )
                else
                  _KeyboardInset(
                    stickersOpen: _stickersOpen || _attachOpen,
                    child: _recorder != null || _voiceStarting
                        ? _RecordingBar(
                            elapsed: () => _recorder?.elapsed ?? Duration.zero,
                            levels: () => _recorder?.recentLevels(24) ?? const <int>[],
                            hold: _holdOrigin == null ? null : _holdDelta,
                            glyph: DsGlyph.mic,
                            onCancel: () => _recorder == null ? _abortStarting() : _finishVoice(send: false),
                            onSend: () => _recorder == null ? _abortStarting() : _finishVoice(send: true),
                          )
                        : _videoRecorder != null || _videoStarting != null
                        ? _RecordingBar(
                            key: const ValueKey('video-note-recording-bar'),
                            elapsed: () => (_videoRecorder ?? _videoStarting)?.elapsed ?? Duration.zero,
                            hold: _holdOrigin == null ? null : _holdDelta,
                            glyph: DsGlyph.video,
                            onCancel: () => _videoRecorder == null ? _abortStarting() : _finishVideoNote(send: false),
                            onSend: () => _videoRecorder == null ? _abortStarting() : _finishVideoNote(send: true),
                          )
                        : _Composer(
                            controller: _draft,
                            focusNode: _composerFocus,
                            stickersOpen: _stickersOpen,
                            attachOpen: _attachOpen,
                            onSmilePressed: _toggleStickers,
                            onSend: _handleSend,
                            onEditLast: _editLastOwn,
                            onAttach: widget.chatId == null ? null : _toggleAttach,
                            videoMode: _videoMode,
                            onMic: widget.chatId == null ? null : _toggleRecordMode,
                            onMicHold: widget.chatId == null ? null : _startHold,
                          ),
                  ),
                // Slides up in the keyboard's place, slides away for it.
                AnimatedSize(
                  duration: DsMotion.of(context, DsMotion.base),
                  curve: DsMotion.emphasized,
                  alignment: Alignment.topCenter,
                  child: _stickersOpen
                      ? EmojiPanel(
                          bottomPad: pad.bottom > 0 ? pad.bottom : 0,
                          height: _KeyboardInset.lastKeyboard > 200
                              ? _KeyboardInset.lastKeyboard - (pad.bottom > 0 ? pad.bottom : 0)
                              : EmojiPanel.defaultHeight,
                          onPick: _insertEmoji,
                          onBackspace: _emojiBackspace,
                          onSticker: widget.chatId == null ? null : _sendSticker,
                        )
                      : _attachOpen
                      ? _AttachPanel(
                          bottomPad: pad.bottom > 0 ? pad.bottom : 0,
                          onCamera: () => _attachPhotos(camera: true),
                          onPhotos: () => _attachPhotos(camera: false),
                          onVideo: _chooseVideo,
                          onDocument: _attachDocument,
                        )
                      : const SizedBox(width: double.infinity),
                ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Heights of the glass header and bottom bar — the list's padding.
  double _topInset = 0;
  double _bottomInset = 0;

  void _setInsets({double? top, double? bottom}) {
    final t = top ?? _topInset;
    final b = bottom ?? _bottomInset;
    if ((t - _topInset).abs() < 0.5 && (b - _bottomInset).abs() < 0.5) return;
    if (mounted) {
      setState(() {
        _topInset = t;
        _bottomInset = b;
      });
    }
  }

  /// The message area: a lazy, reversed list (newest at the bottom,
  /// opens there; only visible bubbles are built).
  Widget _buildMessageList() {
    _requestNow = false;
    final chatId = widget.chatId;
    if (chatId == null) return const SizedBox.shrink();
    final st = ref.watch(chatMessagesProvider(chatId));
    final pending = ref.watch(pendingMediaProvider).where((p) => p.chatId == chatId).toList();
    if (st.loading) return const SizedBox.shrink();
    if (st.error != null && st.messages.isEmpty) {
      return const Center(child: _ChatErrorState());
    }
    final typing = ref.watch(typingChatsProvider.select((m) => m.containsKey(chatId)));
    if (st.messages.isEmpty && pending.isEmpty) {
      return const Center(child: _ChatEmptyState());
    }
    _trackArrivals(st.messages);
    ref.watch(peerNamesProvider); // names in group chats (tech-debt 2.22)
    _requestNow = _isRequest;
    final flat = [..._storedItems(st.messages), for (final p in pending) _Pending(p), if (typing) const _Typing()];
    final loadingMore = st.loadingMore;
    final count = flat.length;
    return KeyedSubtree(
      key: _listKey,
      child: ListView.builder(
        key: const ValueKey('message-list'),
        controller: _scroll,
        reverse: true,
        physics: const BouncingScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.only(top: DsSpace.x1 + _topInset, bottom: DsSpace.x2 + _bottomInset),
        itemCount: count + (loadingMore ? 1 : 0),
        findChildIndexCallback: (key) {
          if (key is! ValueKey<String>) return null;
          for (var i = 0; i < count; i++) {
            if (_itemKey(flat[i]) == key.value) return count - 1 - i;
          }
          return null;
        },
        itemBuilder: (context, i) {
          if (i == count) return const _LoadingOlder();
          return _itemWidget(flat, count - 1 - i);
        },
      ),
    );
  }

  /// Stable identity for an item (message id, day label, pending id).
  static String _itemKey(_Item item) => switch (item) {
    _Msg(:final id) => 'm:${id ?? identityHashCode(item)}',
    _Day(:final label) => 'd:$label',
    _System(:final id) => 's:$id',
    _Typing() => 'typing',
    _UnreadDivider() => 'unread',
    _Pending(:final item) => 'p:${item.id}',
  };

  /// One row, with chain position from its oldest-first neighbours.
  Widget _itemWidget(List<_Item> flat, int i) {
    final item = flat[i];
    final key = ValueKey<String>(_itemKey(item));
    switch (item) {
      case _Day():
        return KeyedSubtree(
          key: key,
          child: _DaySepPill(label: item.label),
        );
      case _Typing():
        return KeyedSubtree(
          key: key,
          child: const _AppearIn(child: _TypingDots()),
        );
      case _System(:final text):
        return KeyedSubtree(
          key: key,
          child: _DaySepPill(label: text, system: true),
        );
      case _UnreadDivider():
        return KeyedSubtree(key: key, child: const _UnreadDividerRow());
      case _Pending(:final item):
        final notifier = ref.read(pendingMediaProvider.notifier);
        return KeyedSubtree(
          key: key,
          child: PendingMediaBubble(
            item: item,
            onRetry: () => notifier.retry(item.id),
            onDismiss: () => notifier.dismiss(item.id),
            onCancel: () => notifier.cancel(item.id),
          ),
        );
      case _Msg():
        final prev = i > 0 ? flat[i - 1] : null;
        final next = i < flat.length - 1 ? flat[i + 1] : null;
        final selecting = _selected.isNotEmpty;
        final canAct = !selecting && !_requestNow && item.wireId != null && !item.deleted;
        // Gradient + shadow bubbles repaint on their own layer, so
        // scrolling and new messages don't repaint their neighbours.
        Widget row = RepaintBoundary(
          child: _Bubble(
            msg: item,
            isFirstInChain: !(prev is _Msg && prev.side == item.side && prev.senderId == item.senderId),
            isLastInChain: !(next is _Msg && next.side == item.side && next.senderId == item.senderId),
            onLongPress: selecting ? null : (ctx) => _openMenu(item, ctx),
            // The a11y "react" action; by touch the heart is two quick taps
            // counted in [_tapBubble], so a single tap never waits.
            onDoubleTap: canAct && item.kind == _MsgKind.text ? () => _toggleHeart(item) : null,
            onTap: selecting
                ? () => _toggleSelected(item)
                : canAct && item.kind == _MsgKind.text
                ? () => _tapBubble(item)
                : null,
            selected: selecting ? _selected.contains(item.id) : null,
            onReactionTap: canAct ? (e) => _toggleReaction(item, e) : null,
            onQuoteTap: _jumpTo,
            onOpenLink: _openLink,
            onOpenContact: selecting ? null : widget.onOpenContact,
            onOpenPhoto: _openGallery,
            highlighted: _highlight != null && (item.albumWires ?? [item.wireId]).contains(_highlight),
            voiceFollowing: item.kind == _MsgKind.voice ? _voicesAfter(flat, i) : const [],
            onOpenVideo: _openGallery,
            onOpenSticker: (json) => openPackOfSticker(context, ref, json),
            a11yName: item.isOut ? context.l10n.you : (item.senderName ?? _name),
          ),
        );
        if (canAct) {
          row = SwipeToReply(
            onReply: () => _startReply(item),
            onThreshold: () => _haptics.play(Haptic.threshold),
            child: row,
          );
        }
        // Status 211 — a message that didn't go says so, under it, in red;
        // a tap sends it again (it used to be a pale "!" in the corner).
        if (!selecting && item.retryable) {
          row = Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              row,
              GestureDetector(
                key: ValueKey('retry-${item.wireId}'),
                behavior: HitTestBehavior.opaque,
                onTap: () => _retry(item),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(DsSpace.x3, 0, DsSpace.x3, DsSpace.x2),
                  child: Text(context.l10n.messageNotSent, style: DsText.footnote.copyWith(color: DsPalette.alert)),
                ),
              ),
            ],
          );
        }
        final day = _dayOf[item.id];
        if (day != null) row = _DayProbe(day: day, registry: _dayProbes, child: row);
        if (item.id != null && _animateIds.remove(item.id)) {
          row = _AppearIn(fromSide: item.isOut ? 1 : -1, child: row);
        }
        if (_jumpTarget != null && (item.albumWires ?? [item.wireId]).contains(_jumpTarget)) {
          row = KeyedSubtree(key: _jumpKey, child: row);
        }
        return KeyedSubtree(key: key, child: row);
    }
  }

  /// Pinned message strip under the header (tap → jump, × → unpin).
  Widget _buildPinnedBar() {
    final id = widget.chatId!;
    final wire = ref.watch(chatsProvider.select((a) => a.value?.where((c) => c.id == id).firstOrNull?.pinnedMsg));
    if (wire == null) return const SizedBox.shrink();
    final row = ref.watch(chatMessagesProvider(id)).messages.where((r) => r.wireId == wire).firstOrNull;
    final text = row == null
        ? context.l10n.pinnedMessage
        : row.body.isNotEmpty
        ? row.body
        : isVideoNoteJson(row.mediaJson)
        ? context.l10n.videoMessage
        : _kindLabel(context, _kindFromString(row.kind));
    return _PinnedBar(text: text, onTap: () => _jumpTo(wire), onUnpin: () => _quietly(() => _msgActions.pin(id, null, unpinning: wire)));
  }

  /// A group call going on here that I'm not in (declined, missed, stepped
  /// out): "Call in progress · Join" (owner, 2026-10-15).
  Widget _buildOngoingCallBar() {
    final id = widget.chatId!;
    if (!_isGroupChat) return const SizedBox.shrink();
    ref.watch(ongoingGroupCallsProvider);
    final call = ref.read(ongoingGroupCallsProvider.notifier).inChat(id);
    final active = ref.watch(activeCallProvider);
    if (call == null || (active.isActive && active.callId == call.callId)) return const SizedBox.shrink();
    // Still going? (A sleeping phone misses the CallEnd.)
    unawaited(ref.read(ongoingGroupCallsProvider.notifier).verify(id));
    return _OngoingCallBar(
      video: call.kind == CallKind.video,
      onJoin: () {
        final nav = Navigator.of(context, rootNavigator: true);
        final route = callScreenRoute((_) => LiveCallScreen(contactName: _name));
        nav.push(route);
        ref.read(activeCallProvider.notifier).join(call).catchError((Object e) {
          if (route.isActive) nav.removeRoute(route);
          if (mounted) setState(() => _mediaError = context.l10n.callJoinFailed);
        });
      },
    );
  }

  /// Telegram-style: a chat with unread messages opens at the first
  /// unread one (near the top), not at the very bottom.
  void _openAtFirstUnread(List<core.StoredMessageSummary> rows) {
    final found = widget.openAtWireId;
    if (found != null) {
      // From search: the found message wins over the first unread one.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jumpTo(found, maxPages: 100);
      });
      return;
    }
    if (_unreadAtOpen <= 0) return;
    var n = 0;
    String? first;
    for (var i = rows.length - 1; i >= 0; i--) {
      if (rows[i].isMine) continue;
      if (++n == _unreadAtOpen) {
        first = rows[i].wireId;
        break;
      }
    }
    if (first == null) return;
    final target = first;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _jumpTo(target, highlight: false, alignment: 0.9);
    });
  }

  /// Consecutive voice messages after [i] (day separators skipped) —
  /// they play one after another, like in Telegram.
  static List<String> _voicesAfter(List<_Item> flat, int i) {
    final out = <String>[];
    for (var k = i + 1; k < flat.length; k++) {
      final it = flat[k];
      if (it is _Day || it is _UnreadDivider) continue;
      if (it is _Msg && it.kind == _MsgKind.voice && it.mediaJson != null && !it.deleted) {
        out.add(it.mediaJson!);
        continue;
      }
      break;
    }
    return out;
  }

  /// Message id → its day label (for the floating day pill).
  final Map<String?, String> _dayOf = {};

  /// New rows at the newest end (not older pages) animate in; incoming
  /// ones while scrolled up bump the "new below" badge.
  void _trackArrivals(List<core.StoredMessageSummary> rows) {
    if (rows.isEmpty) return;
    final seen = _seenIds;
    if (seen == null) {
      _seenIds = {for (final r in rows) r.id};
      _newestId = rows.last.id;
      _openAtFirstUnread(rows);
      return;
    }
    final lastIdx = rows.indexWhere((r) => r.id == _newestId);
    var arrivedIncoming = 0;
    for (var i = lastIdx + 1; i < rows.length; i++) {
      final r = rows[i];
      if (seen.add(r.id)) {
        if (!DsMotion.reduced(context)) _animateIds.add(r.id);
        if (!r.isMine) arrivedIncoming++;
      }
    }
    for (final r in rows) {
      seen.add(r.id);
    }
    _newestId = rows.last.id;
    if (arrivedIncoming > 0 && _awayFromBottom.value) {
      // Not during build: listeners rebuild.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _newBelow.value += arrivedIncoming;
      });
    }
  }

  /// Stored rows (oldest-first) → bubbles with day separators.
  /// Whether this chat is a group (names above incoming bubbles).
  /// ADR-035 — a group that removed me: read-only, no composer.
  bool get _notMember {
    final id = widget.chatId;
    final group = ref.watch(chatsProvider.select((a) => a.value?.where((c) => c.id == id).firstOrNull?.group ?? false));
    if (id == null || !group) return false;
    return ref.watch(groupRoleProvider(id).select((r) => r.value?.active == false));
  }

  bool get _isGroupChat =>
      (ref.read(chatsProvider).value ?? const []).where((c) => c.id == widget.chatId).firstOrNull?.group ?? false;

  List<_Item> _storedItems(List<core.StoredMessageSummary> rows) {
    final flat = <_Item>[];
    final group = _isGroupChat;
    final names = group ? (ref.read(peerNamesProvider).value ?? const <String, String>{}) : const <String, String>{};
    String nameOf(String? id) => id == null || id.isEmpty ? context.l10n.quoteFallback : displayNameOf(id, names);
    int? lastDayBucket;
    final byWire = {
      for (final r in rows)
        if (r.wireId != null) r.wireId!: r,
    };
    // Where the unread part (as of opening the chat) starts.
    int? dividerAt;
    if (_unreadAtOpen > 0) {
      var n = 0;
      for (var i = rows.length - 1; i >= 0; i--) {
        if (rows[i].isMine) continue;
        if (++n == _unreadAtOpen) {
          dividerAt = i;
          break;
        }
      }
    }
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      final ts = DateTime.fromMillisecondsSinceEpoch(r.tsUnix.toInt() * 1000);
      final bucket = DateTime(ts.year, ts.month, ts.day).millisecondsSinceEpoch;
      final day = chat_data.formatDaySeparator(r.tsUnix.toInt());
      if (bucket != lastDayBucket) {
        flat.add(_Day(day));
        lastDayBucket = bucket;
      }
      if (i == dividerAt) flat.add(const _UnreadDivider());
      _dayOf[r.id] = day;
      if (r.kind == 'system') {
        flat.add(_System(r.id, systemLineText(context.l10n, r.body)));
        continue;
      }
      final kind = _kindFromString(r.kind);
      // Photos of one album collapse into the album's first bubble.
      final album = kind == _MsgKind.photo && !r.deleted ? _albumIdOf(r.mediaJson) : null;
      if (album != null && flat.isNotEmpty) {
        final last = flat.last;
        if (last is _Msg &&
            last.kind == _MsgKind.photo &&
            last.isOut == r.isMine &&
            last.senderId == (group && !r.isMine ? r.senderId : null) &&
            _albumIdOf(last.mediaJson) == album &&
            (last.albumJsons?.length ?? 1) < 10) {
          flat[flat.length - 1] = _Msg(
            id: last.id,
            wireId: last.wireId,
            side: last.side,
            kind: last.kind,
            text: last.text ?? (r.body.isEmpty ? null : r.body),
            entities: last.text != null ? last.entities : _entitiesOf(r.entitiesJson),
            time: last.time,
            status: r.isMine ? (last.status < r.status.toInt() ? last.status : r.status.toInt()) : last.status,
            mediaJson: last.mediaJson,
            reply: last.reply,
            reactions: last.reactions,
            albumJsons: [
              ...(last.albumJsons ?? [last.mediaJson!]),
              r.mediaJson!,
            ],
            albumIds: [
              ...(last.albumIds ?? [?last.id]),
              r.id,
            ],
            albumWires: [
              ...(last.albumWires ?? [last.wireId]),
              r.wireId,
            ],
            senderId: last.senderId,
            senderName: last.senderName,
            sentTs: last.sentTs,
          );
          _dayOf[r.id] = day;
          continue;
        }
      }
      final rt = ReplyTarget.fromJson(r.replyJson);
      final quoted = rt == null ? null : byWire[rt.wireId];
      final reactions = parseReactions(r.reactionsJson);
      flat.add(
        _Msg(
          id: r.id,
          wireId: r.wireId,
          side: r.isMine ? _Side.outgoing : _Side.incoming,
          kind: r.deleted ? _MsgKind.text : kind,
          // Media captions may be empty — no empty caption line.
          text: r.deleted || (r.mediaJson != null && r.body.isEmpty && kind != _MsgKind.text) ? null : r.body,
          entities: _entitiesOf(r.entitiesJson),
          time: chat_data.formatMessageTime(r.tsUnix.toInt()),
          status: r.isMine ? r.status.toInt() : MsgStatus.sent,
          // A link preview JSON on a text row isn't media.
          mediaJson: kind == _MsgKind.text ? null : r.mediaJson,
          linkJson: kind == _MsgKind.text && !r.deleted ? r.mediaJson : null,
          expiring: r.expireAt != null,
          edited: r.editedTs != null,
          deleted: r.deleted,
          reply: rt == null
              ? null
              : _ReplyQuote(
                  name: quoted == null
                      ? context.l10n.quoteFallback
                      : (quoted.isMine ? context.l10n.you : (group ? nameOf(quoted.senderId) : _name)),
                  text: rt.snippet.isEmpty
                      ? _kindLabel(context, _kindFromString(rt.kind))
                      : chat_data.contactCardLabel(context.l10n, rt.snippet) ??
                            mentionsToDisplay(rt.snippet, _mentionName),
                  wireId: rt.wireId,
                ),
          reactions: reactions.isEmpty
              ? null
              : [for (final e in reactions.entries) _Reaction(e.key, e.value.length, mine: e.value.contains(kMe))],
          senderId: group && !r.isMine ? r.senderId : null,
          senderName: group && !r.isMine ? nameOf(r.senderId) : null,
          sentTs: r.tsUnix.toInt(),
          replyJson: r.replyJson,
        ),
      );
    }
    return flat;
  }
}

/// Spinner row at the top while an older page loads.
class _LoadingOlder extends StatelessWidget {
  const _LoadingOlder();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: DsSpace.x3),
    child: Center(child: _TypingDots()),
  );
}

/// ADR-070 — a stored row's ranges (null: an older app's message).
List<TextEntity>? _entitiesOf(String? json) => json == null ? null : FormattedText.parseEntities(json);

/// Album id from a stored media JSON (empty / absent → none).
String? _albumIdOf(String? mediaJson) {
  if (mediaJson == null || !mediaJson.contains('album_id')) return null;
  try {
    final id = (jsonDecode(mediaJson) as Map<String, Object?>)['album_id'];
    return id is String && id.isNotEmpty ? id : null;
  } catch (_) {
    return null;
  }
}

/// "Photo" / "Voice message"… for quotes and copies of media.
String _kindLabel(BuildContext context, _MsgKind k) => switch (k) {
  _MsgKind.photo => context.l10n.kindPhoto,
  _MsgKind.voice => context.l10n.kindVoice,
  _MsgKind.document => context.l10n.document,
  _MsgKind.video => context.l10n.video,
  _MsgKind.sticker => context.l10n.kindSticker,
  _MsgKind.text => context.l10n.messagePlaceholder,
};

_MsgKind _kindFromString(String s) {
  switch (s) {
    case 'voice':
      return _MsgKind.voice;
    case 'photo':
      return _MsgKind.photo;
    case 'document':
      return _MsgKind.document;
    case 'video':
      return _MsgKind.video;
    case 'sticker':
      return _MsgKind.sticker;
    default:
      return _MsgKind.text;
  }
}

// ═════════════════════════════════════════════════════════════════════
// Empty / error states for the DB-backed message list
// ═════════════════════════════════════════════════════════════════════

class _ChatEmptyState extends StatelessWidget {
  const _ChatEmptyState();

  @override
  Widget build(BuildContext context) => DsEmptyState(
    illustration: DsIllustration.chats,
    title: context.l10n.noMessagesYet,
    body: context.l10n.chatEmptyHint,
  );
}

class _ChatErrorState extends StatelessWidget {
  const _ChatErrorState();

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x6, DsSpace.x6, DsSpace.x6, DsSpace.x6),
      child: Text(context.l10n.errLoadMessages, style: DsText.subhead.copyWith(color: tokens.danger)),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Header
// ═════════════════════════════════════════════════════════════════════

class _ChatHeader extends StatelessWidget {
  final String name;
  final String status;

  /// The other side is typing (ADR-019) — replaces the status line.
  final bool typing;

  /// What to say while [typing] — "Аня и Борис печатают…" in a group.
  final String? typingText;

  /// Safety-number state (backlog §6 item 49): ✓ next to the name when
  /// verified, a warning line when their key changed.
  final VerifyState verify;

  /// Disappearing timer label ("1 day"), null when off.
  final String? timer;

  /// The other person's photo (personal chats, tech-debt 2.21).
  final Uint8List? avatar;

  /// Press and hold the name: chat options (disappearing messages).
  final VoidCallback? onLongPress;
  final VoidCallback? onBack;
  final VoidCallback? onCall;
  final VoidCallback? onVideo;
  final VoidCallback? onContactInfo;

  /// Call buttons — hidden in a chat with someone I blocked.
  final bool calls;

  /// ADR-055 — my Saved messages: the bookmark avatar.
  final bool saved;

  const _ChatHeader({
    super.key,
    required this.name,
    required this.status,
    this.calls = true,
    this.saved = false,
    this.typing = false,
    this.typingText,
    this.verify = VerifyState.unverified,
    this.timer,
    this.avatar,
    this.onLongPress,
    this.onBack,
    this.onCall,
    this.onVideo,
    this.onContactInfo,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final online = status == 'online';
    final presence = online ? context.l10n.online : status;
    final subtitle = typing
        ? (typingText ?? context.l10n.typing)
        : verify == VerifyState.changed
        ? context.l10n.safetyChanged
        : presence;
    // Disappearing messages: a timer icon and the time after the presence.
    final timerOn = !typing && verify != VerifyState.changed && timer != null;
    // No fill of its own: it sits on the glass bar (DsBlurBar).
    return DecoratedBox(
      decoration: const BoxDecoration(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(DsSpace.x2, DsSpace.x2, DsSpace.x3h5, DsSpace.x2h5),
        child: Row(
          children: [
            _HeaderTapTarget(
              size: 32,
              label: context.l10n.a11yBack,
              onTap: onBack,
              child: SizedBox(
                width: 22,
                height: 22,
                child: CustomPaint(painter: DsGlyphPainter(DsGlyph.back, color: tokens.text)),
              ),
            ),
            const SizedBox(width: 6),
            // Avatar + name area is one tap-target → opens contact info
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onContactInfo,
                onLongPress: onLongPress,
                child: Row(
                  children: [
                    DsAvatar(name: name, size: 36, online: online, image: avatar, saved: saved),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: DsText.body.copyWith(
                                    fontWeight: FontWeight.w600,
                                    height: 1.1,
                                    color: tokens.text,
                                  ),
                                ),
                              ),
                              if (verify == VerifyState.verified) ...[
                                const SizedBox(width: 5),
                                DsVerifiedBadge(
                                  key: const ValueKey('header-verified'),
                                  size: 14,
                                  semanticLabel: context.l10n.verifiedTitle,
                                ),
                              ],
                            ],
                          ),
                          if (subtitle.isNotEmpty || timerOn) const SizedBox(height: 1),
                          if (subtitle.isNotEmpty || timerOn)
                            AnimatedSwitcher(
                              duration: DsMotion.of(context, DsMotion.fast),
                              child: Text.rich(
                                TextSpan(
                                  text: subtitle,
                                  children: [
                                    if (timerOn) ...[
                                      if (subtitle.isNotEmpty) const TextSpan(text: ' · '),
                                      WidgetSpan(
                                        alignment: PlaceholderAlignment.middle,
                                        child: Icon(
                                          CupertinoIcons.timer,
                                          key: const ValueKey('header-timer'),
                                          size: 12,
                                          color: online ? tokens.success : tokens.text3,
                                        ),
                                      ),
                                      TextSpan(text: ' $timer'),
                                    ],
                                  ],
                                ),
                                key: ValueKey(typing),
                                style: DsText.footnote.copyWith(
                                  height: 1.0,
                                  color: typing
                                      ? tokens.accent
                                      : verify == VerifyState.changed
                                      ? tokens.danger
                                      : (online ? tokens.success : tokens.text3),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (calls)
            _HeaderTapTarget(
              size: 36,
              label: context.l10n.a11yVideoCall,
              onTap: onVideo,
              child: SizedBox(
                width: 22,
                height: 22,
                child: CustomPaint(painter: _VideoPainter(color: tokens.text)),
              ),
            ),
            if (calls)
            _HeaderTapTarget(
              size: 36,
              label: context.l10n.call,
              onTap: onCall,
              child: SizedBox(
                width: 20,
                height: 20,
                child: CustomPaint(painter: _PhonePainter(color: tokens.text)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderTapTarget extends StatelessWidget {
  final double size;
  final Widget child;
  final VoidCallback? onTap;

  /// VoiceOver label (§7 item 55).
  final String? label;
  const _HeaderTapTarget({required this.size, required this.child, this.onTap, this.label});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: label != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Center(child: child),
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Day separator pill — more breathing room than before
// ═════════════════════════════════════════════════════════════════════

class _DaySepPill extends StatelessWidget {
  final String label;

  /// Floating variant (no separator spacing).
  final bool compact;

  /// A system line: sentence case, may wrap.
  final bool system;
  const _DaySepPill({required this.label, this.compact = false, this.system = false});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: compact ? EdgeInsets.zero : const EdgeInsets.fromLTRB(0, DsSpace.x5h5, 0, DsSpace.x3h5),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3, vertical: DsSpace.x1),
          decoration: BoxDecoration(color: tokens.bgSoft, borderRadius: BorderRadius.circular(999)),
          child: Text(
            system ? label : label.toUpperCase(),
            key: system ? const ValueKey('system-line') : null,
            textAlign: TextAlign.center,
            style: DsText.caption.copyWith(
              fontWeight: FontWeight.w600,
              height: system ? null : 1.0,
              color: tokens.text3,
            ),
          ),
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Bubble
// ═════════════════════════════════════════════════════════════════════

/// [child] flies into the gallery (and back) when it has a [tag].
Widget _maybeHero(Object? tag, Widget child) =>
    tag == null ? child : Hero(tag: tag, createRectTween: galleryRectTween, child: child);

class _Bubble extends StatelessWidget {
  final _Msg msg;
  final bool isFirstInChain;
  final bool isLastInChain;

  /// Long-press with the bubble's own context (for its on-screen rect).
  final void Function(BuildContext bubbleContext)? onLongPress;
  final VoidCallback? onDoubleTap;

  /// Selection mode: tap toggles; [selected] non-null shows the check.
  final VoidCallback? onTap;
  final bool? selected;
  final ValueChanged<String>? onReactionTap;
  final ValueChanged<String>? onQuoteTap;
  final ValueChanged<String>? onOpenLink;
  final ValueChanged<ContactQr>? onOpenContact;
  final ValueChanged<String>? onOpenPhoto;

  /// Briefly tinted after jumping to it (quote tap, pinned bar).
  final bool highlighted;

  /// Just the bubble (no row padding / reactions) — the lifted copy in
  /// the context menu.
  final bool bare;

  /// Voice: the voice messages right after this one (autoplay queue).
  final List<String> voiceFollowing;

  /// Open a video message full screen.
  final ValueChanged<String>? onOpenVideo;

  /// A sticker was tapped: its pack (ADR-049).
  final ValueChanged<String>? onOpenSticker;

  /// Who wrote it, for VoiceOver ("You" / contact name) — §7 item 55.
  final String? a11yName;

  const _Bubble({
    required this.msg,
    required this.isFirstInChain,
    required this.isLastInChain,
    this.onLongPress,
    this.onDoubleTap,
    this.onTap,
    this.selected,
    this.onReactionTap,
    this.onQuoteTap,
    this.onOpenLink,
    this.onOpenContact,
    this.onOpenPhoto,
    this.highlighted = false,
    this.bare = false,
    this.voiceFollowing = const [],
    this.onOpenVideo,
    this.onOpenSticker,
    this.a11yName,
  });

  bool get _isOut => msg.side == _Side.outgoing;

  /// 1–3 emoji and nothing else: big, no bubble.
  int get _jumbo => msg.kind == _MsgKind.text && !msg.deleted && msg.reply == null && msg.linkJson == null
      ? jumboEmojiCount(msg.text ?? '')
      : 0;

  /// A sticker: big, no bubble (ADR-049).
  bool get _isSticker => msg.kind == _MsgKind.sticker && !msg.deleted && msg.mediaJson != null;

  /// A group's sender name as the bubble's first line (owner, 2026-10-18:
  /// it floated above the bubble, indented, like a prototype).
  bool get _nameInside =>
      !_isOut &&
      isFirstInChain &&
      msg.senderName != null &&
      _jumbo == 0 &&
      (msg.deleted || msg.kind == _MsgKind.text || msg.kind == _MsgKind.voice || msg.kind == _MsgKind.document);

  /// What the sender's colour is picked by: their name, like their avatar,
  /// so a name in a group has the colour of that person's circle. Members
  /// without a name differ by key.
  String _hueSeed(BuildContext context) =>
      msg.senderId == null || msg.senderName != context.l10n.memberUnnamed ? msg.senderName! : msg.senderId!;

  Widget _senderName(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: DsSpace.x0h5),
    child: ExcludeSemantics(
      child: Text(
        msg.senderName!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: DsText.subhead.copyWith(
          fontWeight: FontWeight.w600,
          height: 1.15,
          color: dsAvatarAccent(_hueSeed(context), dark: DsTheme.isDarkOf(context)),
        ),
      ),
    ),
  );

  bool get _hasReactions => !msg.deleted && msg.reactions != null && msg.reactions!.isNotEmpty;

  /// Status 213 — a photo / video with nothing else (no caption, no quote):
  /// the picture is the bubble — no coloured frame, the time on the photo
  /// (as in Telegram, WhatsApp, iMessage).
  bool get _bareMedia =>
      !msg.deleted &&
      (msg.kind == _MsgKind.photo || msg.kind == _MsgKind.video) &&
      msg.mediaJson != null &&
      (msg.text == null || msg.text!.isEmpty) &&
      msg.reply == null;

  /// Chain radius logic: 20 everywhere; on my / their side the corners
  /// between bubbles of one run are 6 (they read as one block).
  BorderRadius _radius(DsTokens tokens) {
    final big = Radius.circular(tokens.radiusBubble);
    final tail = big;
    const link = Radius.circular(6);
    if (_isOut) {
      return BorderRadius.only(
        topLeft: big,
        topRight: isFirstInChain ? big : link,
        bottomLeft: big,
        bottomRight: isLastInChain ? tail : link,
      );
    }
    return BorderRadius.only(
      topLeft: isFirstInChain ? big : link,
      topRight: big,
      bottomLeft: isLastInChain ? tail : link,
      bottomRight: big,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);

    final fg = _isOut ? tokens.bubbleOutText : tokens.text;
    final metaFg = _isOut ? tokens.bubbleOutMeta : tokens.text3;

    // Over a wallpaper an incoming bubble is white (the card colour on
    // dark) with a hairline, so it stays visible on any picture.
    final onWallpaper = !_isOut && OnWallpaper.of(context);
    final decoration = BoxDecoration(
      color: _isOut ? tokens.bubbleOut : (onWallpaper ? tokens.surface : tokens.bubbleIn),
      border: onWallpaper ? Border.all(color: tokens.dividerStrong, width: 0.5) : null,
      borderRadius: _radius(tokens),
    );

    final jumbo = _jumbo;
    Widget bubble = jumbo > 0
        ? _jumboEmoji(context, tokens, jumbo)
        : msg.round
        ? _videoNote(context, decoration)
        : _isSticker
        ? _sticker(context, tokens)
        : ConstrainedBox(
            constraints: BoxConstraints(maxWidth: bubbleMaxWidth(MediaQuery.sizeOf(context).width), minWidth: 60),
            child: Container(
              padding: _bubbleContentPadding(),
              clipBehavior: (msg.kind == _MsgKind.photo || msg.kind == _MsgKind.video) && !msg.deleted
                  ? Clip.antiAlias
                  : Clip.none,
              decoration: _bareMedia ? BoxDecoration(borderRadius: _radius(tokens)) : decoration,
              child: () {
                final body = msg.deleted ? _tombstone(context, tokens, metaFg) : _content(context, tokens, fg, metaFg);
                if (!_nameInside) return body;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [_senderName(context), body],
                );
              }(),
            ),
          );
    // Status 213 — on a bare photo / video the time and ticks sit on the
    // picture, in a dark pill (Telegram, WhatsApp).
    if (_bareMedia && msg.time != null && jumbo == 0 && !msg.round) {
      bubble = Stack(
        children: [
          bubble,
          Positioned(
            right: DsSpace.x2,
            bottom: DsSpace.x2,
            child: IgnorePointer(
              child: Container(
                key: const ValueKey('media-time-pill'),
                padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1h5, vertical: DsSpace.x0h5),
                decoration: BoxDecoration(color: DsPalette.black40, borderRadius: BorderRadius.circular(10)),
                child: _Meta(
                  time: msg.time!,
                  status: msg.status,
                  edited: msg.edited,
                  expiring: msg.expiring,
                  isOut: _isOut,
                  color: DsPalette.white,
                ),
              ),
            ),
          ),
        ],
      );
    }
    if (bare) return bubble;
    if (onLongPress != null || onDoubleTap != null || onTap != null) {
      final inner = bubble;
      bubble = Builder(
        builder: (bubbleContext) => Semantics(
          // One VoiceOver stop per message: author, then the text and the
          // time/status line read by the children; hold for the menu.
          container: true,
          label: a11yName,
          hint: onLongPress == null ? null : context.l10n.a11yMessageHint,
          onLongPress: onLongPress == null ? null : () => onLongPress!(bubbleContext),
          customSemanticsActions: onDoubleTap == null
              ? null
              : {CustomSemanticsAction(label: context.l10n.a11yReact): onDoubleTap!},
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            onLongPress: onLongPress == null ? null : () => onLongPress!(bubbleContext),
            child: inner,
          ),
        ),
      );
    }

    // Vertical rhythm: large gap between chain breaks, tight within a chain.
    final topGap = isFirstInChain ? 8.0 : 2.0;
    final bottomGap = _hasReactions ? 0.0 : 1.5;

    // Reactions sit under the bubble, overlapping its edge a little. A
    // Column (not a Positioned outside a Stack) keeps them tappable.
    Widget row = Column(
      crossAxisAlignment: _isOut ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Photos, video and big emoji: the name over them, in line with the
        // bubble's edge; text, voice and files carry it inside (Telegram).
        if (!_isOut && isFirstInChain && msg.senderName != null && !_nameInside)
          Padding(
            padding: const EdgeInsets.only(left: DsSpace.x3, bottom: DsSpace.nudge3, right: DsSpace.x15),
            child: ExcludeSemantics(
              child: Text(
                msg.senderName!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DsText.subhead.copyWith(
                  fontWeight: FontWeight.w600,
                  color: dsAvatarAccent(_hueSeed(context), dark: DsTheme.isDarkOf(context)),
                ),
              ),
            ),
          ),
        Align(alignment: _isOut ? Alignment.centerRight : Alignment.centerLeft, child: bubble),
        if (_hasReactions)
          Padding(
            padding: EdgeInsets.only(left: _isOut ? 0 : DsSpace.x5, right: _isOut ? DsSpace.x5 : 0),
            child: Transform.translate(
              offset: const Offset(0, -6),
              child: _ReactionsRow(reactions: msg.reactions!, onTap: onReactionTap),
            ),
          ),
      ],
    );
    if (selected != null) {
      row = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Row(
          children: [
            _SelectCheck(on: selected!),
            const SizedBox(width: 8),
            Expanded(child: IgnorePointer(child: row)),
          ],
        ),
      );
    }

    return AnimatedContainer(
      duration: DsMotion.of(context, DsMotion.slow),
      curve: DsMotion.enter,
      color: highlighted ? tokens.accent.withValues(alpha: 0.14) : DsPalette.transparent,
      padding: EdgeInsets.fromLTRB(DsSpace.x3, topGap, DsSpace.x3, bottomGap),
      child: row,
    );
  }

  /// The time in a small glass pill — under big emoji and stickers.
  Widget _timePill(DsTokens tokens) => Container(
    margin: const EdgeInsets.only(top: DsSpace.x0h5),
    padding: const EdgeInsets.fromLTRB(DsSpace.x2, DsSpace.nudge3, DsSpace.x2, DsSpace.nudge3),
    // No shadows in this look: the pill is the incoming-bubble grey.
    decoration: BoxDecoration(color: tokens.bubbleIn, borderRadius: BorderRadius.circular(10)),
    child: _Meta(
      time: msg.time!,
      status: msg.status,
      edited: msg.edited,
      expiring: msg.expiring,
      isOut: _isOut,
      color: tokens.text3,
    ),
  );

  /// Big emoji with the time in a small glass pill under it. One emoji
  /// with a built-in animation plays it (ADR-049).
  Widget _jumboEmoji(BuildContext context, DsTokens tokens, int count) {
    final text = Text(
      msg.text!.trim(),
      style: TextStyle(fontSize: jumboEmojiSize(count), height: 1.15, letterSpacing: 2),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1),
      child: Column(
        key: const ValueKey('jumbo-emoji'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: _isOut ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (count == 1) AnimatedJumboEmoji(emoji: msg.text!.trim(), fallback: text) else text,
          if (msg.time != null) _timePill(tokens),
        ],
      ),
    );
  }

  /// A sticker (ADR-049): big, no bubble, the quote it answers above it
  /// and the time pill under it, like a lone emoji.
  Widget _sticker(BuildContext context, DsTokens tokens) {
    final reply = msg.reply;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1),
      child: Column(
        key: const ValueKey('sticker-bubble'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: _isOut ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (reply != null)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: reply.wireId == null || onQuoteTap == null ? null : () => onQuoteTap!(reply.wireId!),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 260),
                margin: const EdgeInsets.only(bottom: DsSpace.x1),
                padding: const EdgeInsets.all(DsSpace.x1h5),
                decoration: BoxDecoration(color: tokens.bubbleIn, borderRadius: BorderRadius.circular(12)),
                child: _ReplyQuoteWidget(reply: reply, isOut: false),
              ),
            ),
          Semantics(
            label: context.l10n.kindSticker,
            child: StickerMessage(
              mediaJson: msg.mediaJson!,
              onTap: onOpenSticker == null ? null : () => onOpenSticker!(msg.mediaJson!),
            ),
          ),
          if (msg.time != null) _timePill(tokens),
        ],
      ),
    );
  }

  /// ADR-048 — a round video message: no bubble, just the circle, with
  /// the time on it; a reply quote sits above in a small bubble.
  Widget _videoNote(BuildContext context, BoxDecoration decoration) {
    final reply = msg.reply;
    return Column(
      key: const ValueKey('video-note'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: _isOut ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (_nameInside) _senderName(context),
        if (reply != null)
          Container(
            margin: const EdgeInsets.only(bottom: DsSpace.x1),
            padding: const EdgeInsets.all(DsSpace.x1),
            constraints: const BoxConstraints(maxWidth: kVideoNoteBubbleExpanded),
            decoration: decoration,
            child: GestureDetector(
              key: const ValueKey('reply-quote'),
              behavior: HitTestBehavior.opaque,
              onTap: reply.wireId == null || onQuoteTap == null ? null : () => onQuoteTap!(reply.wireId!),
              child: _ReplyQuoteWidget(reply: reply, isOut: _isOut),
            ),
          ),
        VideoNoteBubble(
          mediaJson: msg.mediaJson!,
          meta: msg.time == null
              ? null
              : _Meta(
                  time: msg.time!,
                  status: msg.status,
                  edited: msg.edited,
                  expiring: msg.expiring,
                  isOut: _isOut,
                  color: DsPalette.white,
                ),
        ),
      ],
    );
  }

  /// "Message deleted" — what's left after delete-for-everyone.
  Widget _tombstone(BuildContext context, DsTokens tokens, Color metaFg) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            _isOut ? context.l10n.youDeleted : context.l10n.messageDeleted,
            key: const ValueKey('tombstone'),
            style: DsText.callout.copyWith(fontStyle: FontStyle.italic, color: metaFg),
          ),
        ),
        if (msg.time != null) ...[
          const SizedBox(width: 8),
          _Meta(time: msg.time!, status: msg.status, isOut: false, color: metaFg),
        ],
      ],
    );
  }

  /// Time + status under media (text carries it inline).
  Widget _mediaMeta(Color metaFg) => msg.time == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.fromLTRB(DsSpace.x2, DsSpace.x1, DsSpace.x1h5, 0),
          child: Align(
            alignment: Alignment.centerRight,
            child: _Meta(
              time: msg.time!,
              status: msg.status,
              edited: msg.edited,
              expiring: msg.expiring,
              isOut: _isOut,
              color: metaFg,
            ),
          ),
        );

  EdgeInsets _bubbleContentPadding() {
    switch (msg.kind) {
      // Status 213 — the picture flush to the bubble's edges.
      case _MsgKind.photo || _MsgKind.video:
        return _bareMedia ? EdgeInsets.zero : const EdgeInsets.only(bottom: DsSpace.x2);
      case _MsgKind.sticker:
        return const EdgeInsets.fromLTRB(DsSpace.x1, DsSpace.x1, DsSpace.x1, DsSpace.x2);
      case _MsgKind.voice:
        return const EdgeInsets.fromLTRB(DsSpace.x2, DsSpace.x2, DsSpace.x3h5, DsSpace.x2);
      case _MsgKind.document:
        return const EdgeInsets.fromLTRB(DsSpace.x2h5, DsSpace.x2, DsSpace.x3, DsSpace.x2);
      case _MsgKind.text:
        return const EdgeInsets.fromLTRB(DsSpace.x3, DsSpace.x2, DsSpace.x3, DsSpace.nudge7);
    }
  }

  Widget _content(BuildContext context, DsTokens tokens, Color fg, Color metaFg) {
    final reply = msg.reply;
    final time = msg.time;
    final quote = reply == null
        ? null
        : GestureDetector(
            key: const ValueKey('reply-quote'),
            behavior: HitTestBehavior.opaque,
            onTap: reply.wireId == null || onQuoteTap == null ? null : () => onQuoteTap!(reply.wireId!),
            child: _ReplyQuoteWidget(reply: reply, isOut: _isOut),
          );

    switch (msg.kind) {
      // Only while its media isn't stored yet — otherwise [_sticker].
      case _MsgKind.sticker:
        return Text(context.l10n.kindSticker, style: DsText.body.copyWith(color: fg));
      case _MsgKind.text:
        final contact = msg.text == null ? null : contactCardOf(msg.text!);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ?quote,
            if (contact != null)
              _ContactCard(
                contact: contact,
                isOut: _isOut,
                fg: fg,
                metaFg: metaFg,
                meta: time == null
                    ? null
                    : _Meta(
                        time: time,
                        status: msg.status,
                        edited: msg.edited,
                        expiring: msg.expiring,
                        isOut: _isOut,
                        color: metaFg,
                      ),
                onOpen: onOpenContact,
              )
            else if (msg.text != null)
              _TextWithMeta(
                text: msg.text!,
                entities: msg.entities,
                time: time,
                status: msg.status,
                edited: msg.edited,
                expiring: msg.expiring,
                isOut: _isOut,
                fg: fg,
                metaFg: metaFg,
                onOpenLink: onOpenLink,
              )
            else if (time != null)
              Padding(
                padding: const EdgeInsets.only(top: DsSpace.x1),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _Meta(time: time, status: msg.status, isOut: _isOut, color: metaFg),
                ),
              ),
            if (msg.linkJson != null) LinkPreviewCard(json: msg.linkJson!, isOut: _isOut, onOpen: onOpenLink),
          ],
        );
      case _MsgKind.photo:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (quote != null)
              Padding(padding: const EdgeInsets.fromLTRB(DsSpace.x1, DsSpace.x1, DsSpace.x1, 0), child: quote),
            if (msg.albumJsons != null && msg.albumJsons!.length > 1)
              EncryptedAlbum(
                mediaJsons: msg.albumJsons!,
                heroTags: [for (final id in msg.albumIds!) 'photo-$id'],
                onTap: onOpenPhoto == null ? null : (i) => onOpenPhoto!(msg.albumJsons![i]),
              )
            else if (msg.mediaJson != null)
              EncryptedPhoto(
                mediaJson: msg.mediaJson!,
                heroTag: msg.id == null ? null : 'photo-${msg.id}',
                onTap: onOpenPhoto == null ? null : () => onOpenPhoto!(msg.mediaJson!),
              )
            else
              // A photo still arriving: nothing to open yet.
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(width: 244, height: 160, child: CustomPaint(painter: _PhotoPlaceholderPainter())),
              ),
            if (msg.text != null) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.fromLTRB(DsSpace.x3, 0, DsSpace.x3, DsSpace.x0h5),
                child: MessageText(
                  text: msg.text!,
                  entities: msg.entities,
                  linkColor: _isOut ? fg : tokens.accent,
                  onOpenLink: onOpenLink,
                  style: DsText.body.copyWith(color: fg),
                ),
              ),
            ],
            if (msg.mediaJson != null && !_bareMedia) _mediaMeta(metaFg),
          ],
        );
      case _MsgKind.video:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (quote != null)
              Padding(padding: const EdgeInsets.fromLTRB(DsSpace.x1, DsSpace.x1, DsSpace.x1, 0), child: quote),
            if (msg.mediaJson != null)
              _maybeHero(
                msg.id == null ? null : 'photo-${msg.id}',
                EncryptedVideo(
                  mediaJson: msg.mediaJson!,
                  onTap: onOpenVideo == null ? null : () => onOpenVideo!(msg.mediaJson!),
                ),
              ),
            if (msg.text != null) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.fromLTRB(DsSpace.x2, 0, DsSpace.x2, DsSpace.x0h5),
                child: MessageText(
                  text: msg.text!,
                  entities: msg.entities,
                  linkColor: _isOut ? fg : tokens.accent,
                  onOpenLink: onOpenLink,
                  style: DsText.body.copyWith(color: fg),
                ),
              ),
            ],
            if (msg.mediaJson != null && !_bareMedia) _mediaMeta(metaFg),
          ],
        );
      case _MsgKind.voice:
        if (msg.mediaJson != null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ?quote,
              EncryptedVoice(
                mediaJson: msg.mediaJson!,
                color: _isOut ? fg : tokens.accent,
                glyph: _isOut ? tokens.bubbleOut : tokens.accentText,
                following: voiceFollowing,
              ),
              _mediaMeta(metaFg),
            ],
          );
        }
        return _VoiceContent(duration: '0:00', isOut: _isOut);
      case _MsgKind.document:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ?quote,
            if (msg.mediaJson != null) EncryptedDocument(mediaJson: msg.mediaJson!, color: fg),
            if (msg.text != null) ...[
              const SizedBox(height: 6),
              MessageText(
                text: msg.text!,
                entities: msg.entities,
                linkColor: _isOut ? fg : tokens.accent,
                onOpenLink: onOpenLink,
                style: DsText.body.copyWith(color: fg),
              ),
            ],
            if (msg.mediaJson != null && !_bareMedia) _mediaMeta(metaFg),
          ],
        );
    }
  }
}

/// A shared contact ("Share contact" sends their contact QR text): their
/// photo or initials, name, the start of their key, and "Message" — like
/// Telegram's contact card. The card's name is whatever the sender typed
/// (app-surface:9): someone I already know shows under my name for them,
/// anyone else's is marked "from the card", as invites show the key start.
class _ContactCard extends ConsumerWidget {
  const _ContactCard({
    required this.contact,
    required this.isOut,
    required this.fg,
    required this.metaFg,
    this.meta,
    this.onOpen,
  });
  final ContactQr contact;
  final bool isOut;
  final Color fg;
  final Color metaFg;
  final Widget? meta;
  final ValueChanged<ContactQr>? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    final known = ref.watch(peerNamesProvider).value?[contact.identityHex] ?? '';
    final name = known.isNotEmpty ? known : contact.name ?? l.contactCardNoName;
    final open = onOpen == null
        ? null
        : () => onOpen!(known.isEmpty ? contact : (identityHex: contact.identityHex, serverHost: contact.serverHost, name: known));
    final accent = isOut ? fg : tokens.accent;
    return GestureDetector(
      key: const ValueKey('contact-card'),
      behavior: HitTestBehavior.opaque,
      onTap: open,
      child: SizedBox(
        width: 232,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                DsAvatar(name: name, size: 44, image: peerAvatarOf(ref, contact.identityHex)),
                const SizedBox(width: DsSpace.x2h5),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DsText.body.copyWith(fontWeight: FontWeight.w600, color: fg),
                      ),
                      Text(
                        l.inviteKeyRow(keyFingerprint(contact.identityHex)),
                        maxLines: 1,
                        style: DsText.footnote.copyWith(color: metaFg),
                      ),
                      if (known.isEmpty)
                        Text(l.contactCardNameUnverified, style: DsText.footnote.copyWith(color: metaFg)),
                    ],
                  ),
                ),
              ],
            ),
            if (meta != null) Align(alignment: Alignment.centerRight, child: meta),
            const SizedBox(height: DsSpace.x1),
            GestureDetector(
              key: const ValueKey('contact-card-message'),
              behavior: HitTestBehavior.opaque,
              onTap: open,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: DsSpace.x2),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Text(
                    l.contactMessage,
                    style: DsText.subhead.copyWith(fontWeight: FontWeight.w600, color: accent),
                  ),
                ),
              ),
            ),
            const SizedBox(height: DsSpace.x1),
          ],
        ),
      ),
    );
  }
}

/// Reports its child's height after layout (the glass bars' heights pad
/// the message list under them).
class _MeasuredHeight extends SingleChildRenderObjectWidget {
  const _MeasuredHeight({required this.onHeight, super.child});
  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMeasuredHeight(onHeight);

  @override
  void updateRenderObject(BuildContext context, _RenderMeasuredHeight renderObject) =>
      renderObject.onHeight = onHeight;
}

class _RenderMeasuredHeight extends RenderProxyBox {
  _RenderMeasuredHeight(this.onHeight);
  ValueChanged<double> onHeight;
  double? _last;

  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if (h == _last) return;
    _last = h;
    // Not during layout: the screen sets state with it.
    WidgetsBinding.instance.addPostFrameCallback((_) => onHeight(h));
  }
}

class _TextWithMeta extends StatelessWidget {
  final String text;
  final List<TextEntity>? entities;
  final String? time;
  final int status;
  final bool edited;
  final bool expiring;
  final bool isOut;
  final Color fg;
  final Color metaFg;
  final ValueChanged<String>? onOpenLink;

  const _TextWithMeta({
    required this.text,
    this.entities,
    required this.time,
    required this.status,
    this.edited = false,
    this.expiring = false,
    required this.isOut,
    required this.fg,
    required this.metaFg,
    this.onOpenLink,
  });

  @override
  Widget build(BuildContext context) {
    final textStyle = DsText.body.copyWith(color: fg);

    // 1-3 emoji alone → big, the way they're meant to be seen.
    final big = bigEmojiCount(text);
    final style = big > 0 ? textStyle.copyWith(fontSize: big == 1 ? 44 : 34, height: 1.15) : textStyle;
    final linkColor = isOut ? fg : DsTheme.of(context).accent;
    // Inline meta via WidgetSpan: time/tick floats to end of last text line.
    return MessageText(
      text: text,
      entities: entities,
      style: style,
      linkColor: linkColor,
      onOpenLink: onOpenLink,
      trailing: time == null
          ? null
          : TextSpan(
              children: [
                const TextSpan(text: '   '),
                WidgetSpan(
                  alignment: PlaceholderAlignment.baseline,
                  baseline: TextBaseline.alphabetic,
                  child: _Meta(
                    time: time ?? '',
                    status: status,
                    edited: edited,
                    expiring: expiring,
                    isOut: isOut,
                    color: metaFg,
                  ),
                ),
              ],
            ),
    );
  }
}

class _Meta extends StatelessWidget {
  final String time;
  final int status;
  final bool edited;
  final bool isOut;
  final Color color;

  /// Disappearing message.
  final bool expiring;

  const _Meta({
    required this.time,
    required this.status,
    this.edited = false,
    required this.isOut,
    required this.color,
    this.expiring = false,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final label = switch (status) {
      MsgStatus.failed => l.statusFailed,
      MsgStatus.sending => l.statusSending,
      MsgStatus.sent => l.statusSent,
      MsgStatus.delivered => l.statusDelivered,
      _ => l.statusRead,
    };
    return Semantics(
      label: isOut ? '$time, $label${edited ? l.editedA11y : ''}' : '$time${edited ? l.editedA11y : ''}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (expiring) ...[
            Icon(CupertinoIcons.timer, key: const ValueKey('meta-expiring'), size: 11, color: color),
            const SizedBox(width: 3),
          ],
          if (edited) ...[
            Text(
              context.l10n.edited,
              style: DsText.caption.copyWith(height: 1.0, fontStyle: FontStyle.italic, color: color),
            ),
            const SizedBox(width: 4),
          ],
          Text(time, style: DsText.caption.copyWith(height: 1.0, color: color)),
          if (isOut) ...[
            const SizedBox(width: 4),
            SizedBox(
              key: ValueKey('status-$status'),
              width: 14,
              height: 10,
              child: CustomPaint(
                painter: _StatusPainter(
                  status: status,
                  // Read: light blue on my bubble and on a photo's dark pill, the accent on a grey one.
                  color: status == MsgStatus.read
                      ? (color == DsPalette.white || color == DsTheme.of(context).bubbleOutMeta
                            ? DsPalette.artA8E6FF
                            : DsTheme.of(context).accent)
                      : status == MsgStatus.failed
                      ? DsPalette.alert
                      : color,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Status 213 — "Message info" lines: what on the left, when on the right.
class _InfoRows extends StatelessWidget {
  const _InfoRows({required this.rows});
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return SingleChildScrollView(
      key: const ValueKey('message-info'),
      padding: const EdgeInsets.symmetric(vertical: DsSpace.x1),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Container(height: 0.5, color: tokens.divider),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: DsSpace.x4, vertical: DsSpace.x3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      rows[i].$1,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DsText.body.copyWith(color: tokens.text),
                    ),
                  ),
                  const SizedBox(width: DsSpace.x3),
                  Text(rows[i].$2, style: DsText.body.copyWith(color: tokens.text3)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ReplyQuoteWidget extends StatelessWidget {
  final _ReplyQuote reply;
  final bool isOut;
  const _ReplyQuoteWidget({required this.reply, required this.isOut});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);

    final bg = isOut ? tokens.bubbleOutText.withValues(alpha: 0.08) : tokens.accentSoft;
    final stripe = tokens.accent;
    final nameColor = isOut ? tokens.bubbleOutText : tokens.accent;
    final bodyColor = isOut ? tokens.bubbleOutMeta : tokens.text2;
    return Container(
      margin: const EdgeInsets.only(bottom: DsSpace.x1h5),
      padding: const EdgeInsets.fromLTRB(DsSpace.x2h5, DsSpace.nudge5, DsSpace.x2h5, DsSpace.x1h5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: stripe, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            reply.name,
            style: DsText.footnote.copyWith(fontWeight: FontWeight.w600, color: nameColor),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Text(
              reply.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DsText.footnote.copyWith(fontWeight: FontWeight.w400, color: bodyColor),
            ),
          ),
        ],
      ),
    );
  }
}

/// Reactions under a bubble: small floating pills that sit on the bubble's
/// edge (a ring in the screen colour cuts them out of it, like iMessage),
/// soft shadow, bigger emoji. Mine is tinted with the accent; a new or
/// changed reaction pops in.
class _ReactionsRow extends StatelessWidget {
  final List<_Reaction> reactions;
  final ValueChanged<String>? onTap;
  const _ReactionsRow({required this.reactions, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < reactions.length; i++) ...[
          if (i > 0) const SizedBox(width: DsSpace.x1),
          _ReactionChip(
            key: ValueKey('reaction-${reactions[i].emoji}'),
            reaction: reactions[i],
            onTap: onTap == null ? null : () => onTap!(reactions[i].emoji),
          ),
        ],
      ],
    );
  }
}

class _ReactionChip extends StatelessWidget {
  const _ReactionChip({super.key, required this.reaction, this.onTap});
  final _Reaction reaction;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final mine = reaction.mine;
    // The colour of an incoming bubble: a pill you can see on the page.
    // (It was the page's own white in the light theme — only the bite it
    // took out of the bubble showed, with the emoji hanging in the air.)
    final fill = mine ? Color.lerp(tokens.bubbleIn, tokens.accent, 0.16)! : tokens.bubbleIn;
    final counted = reaction.count > 1;
    final chip = AnimatedContainer(
      duration: DsMotion.of(context, DsMotion.base),
      curve: DsMotion.emphasized,
      padding: EdgeInsets.fromLTRB(DsSpace.x2, DsSpace.x1, counted ? DsSpace.x2h5 : DsSpace.x2, DsSpace.x1),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tokens.bg, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(reaction.emoji, style: DsText.reactionEmoji),
          if (counted) ...[
            const SizedBox(width: DsSpace.x1),
            Text(
              reaction.count.toString(),
              style: DsText.reactionCount.copyWith(color: mine ? tokens.accent : tokens.text2),
            ),
          ],
        ],
      ),
    );
    return Semantics(
      button: onTap != null,
      selected: mine,
      label: '${reaction.emoji} ${reaction.count}',
      excludeSemantics: true,
      child: DsPressable(
        onTap: onTap,
        scale: 0.88,
        haptic: Haptic.selection,
        // Pops when it appears or its count / owner changes.
        child: TweenAnimationBuilder<double>(
          key: ValueKey('${reaction.count}-$mine'),
          tween: Tween(begin: 0.6, end: 1),
          duration: DsMotion.of(context, DsMotion.slow),
          curve: Curves.easeOutBack,
          builder: (_, v, child) => Transform.scale(scale: v, child: child),
          child: chip,
        ),
      ),
    );
  }
}

/// Round check shown next to bubbles in selection mode.
class _SelectCheck extends StatelessWidget {
  const _SelectCheck({required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return AnimatedContainer(
      duration: DsMotion.of(context, DsMotion.fast),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on ? tokens.accent : DsPalette.transparent,
        border: Border.all(color: on ? tokens.accent : tokens.text4, width: 1.5),
      ),
      alignment: Alignment.center,
      child: on ? Icon(CupertinoIcons.checkmark_alt, size: 16, color: tokens.accentText) : null,
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Voice content — thinner bars (1.5pt) + sparser gap for delicate feel
// ═════════════════════════════════════════════════════════════════════

class _VoiceContent extends StatelessWidget {
  final String duration;
  final bool isOut;
  const _VoiceContent({required this.duration, required this.isOut});

  static const _samples = [
    3,
    5,
    8,
    12,
    9,
    14,
    18,
    16,
    11,
    8,
    12,
    16,
    20,
    18,
    14,
    10,
    7,
    11,
    15,
    19,
    17,
    13,
    9,
    6,
    10,
    14,
    12,
    8,
    5,
    9,
    13,
    16,
    14,
    10,
    7,
    4,
    8,
  ];
  static const _playedAt = 0.35;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final playButtonBg = tokens.accent;
    final baseColor = isOut ? tokens.bubbleOutMeta.withValues(alpha: 0.5) : tokens.text4;
    final playedColor = tokens.accent;
    final durationColor = isOut ? tokens.bubbleOutMeta : tokens.text3;

    final cut = (_samples.length * _playedAt).floor();

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(color: playButtonBg, shape: BoxShape.circle),
          child: Center(
            child: SizedBox(
              width: 11,
              height: 13,
              child: CustomPaint(painter: _PlayTrianglePainter(tokens.accentText)),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 22,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  for (var i = 0; i < _samples.length; i++) ...[
                    if (i > 0) const SizedBox(width: 2),
                    Container(
                      width: 1.5,
                      height: _samples[i].toDouble(),
                      decoration: BoxDecoration(
                        color: i < cut ? playedColor : baseColor,
                        borderRadius: BorderRadius.circular(1.25),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(duration, style: DsTextArt.t11w500Mono.copyWith(color: durationColor)),
          ],
        ),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Photo placeholder — gradient + faint scene
// ═════════════════════════════════════════════════════════════════════

class _PhotoPlaceholderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final grad = const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [DsPalette.peach, DsPalette.salmon, DsPalette.lilac, DsPalette.violet],
      stops: [0.0, 0.35, 0.75, 1.0],
    ).createShader(rect);
    canvas.drawRect(rect, Paint()..shader = grad);

    canvas.drawCircle(
      Offset(size.width * 170 / 220, size.height * 40 / 160),
      22 * size.width / 220,
      Paint()..color = DsPalette.artFFFFFFa80,
    );

    final hill1 = Path()
      ..moveTo(0, size.height * 130 / 160)
      ..quadraticBezierTo(
        size.width * 55 / 220,
        size.height * 100 / 160,
        size.width * 110 / 220,
        size.height * 120 / 160,
      )
      ..quadraticBezierTo(size.width * 165 / 220, size.height * 140 / 160, size.width, size.height * 110 / 160)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(hill1, Paint()..color = DsPalette.art0F1720a4D);

    final hill2 = Path()
      ..moveTo(0, size.height * 145 / 160)
      ..quadraticBezierTo(
        size.width * 70 / 220,
        size.height * 125 / 160,
        size.width * 140 / 220,
        size.height * 140 / 160,
      )
      ..quadraticBezierTo(size.width * 180 / 220, size.height * 150 / 160, size.width, size.height * 130 / 160)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(hill2, Paint()..color = DsPalette.art0F1720a73);
  }

  @override
  bool shouldRepaint(_PhotoPlaceholderPainter old) => false;
}

// ═════════════════════════════════════════════════════════════════════
// Typing indicator
// ═════════════════════════════════════════════════════════════════════

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduce Motion: three still dots (the words "typing…" say the rest).
    if (DsMotion.reduced(context)) {
      _ctrl
        ..stop()
        ..value = 0.3;
    } else if (!_ctrl.isAnimating) {
      _ctrl.repeat();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x3, DsSpace.x1h5, DsSpace.x3, DsSpace.x1h5),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          decoration: BoxDecoration(
            color: tokens.bubbleIn,
            borderRadius: BorderRadius.circular(tokens.radiusBubble),
          ),
          padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3h5, vertical: DsSpace.x2h5),
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (context, _) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < 3; i++) ...[
                    if (i > 0) const SizedBox(width: 4),
                    Opacity(
                      opacity: _dotOpacity(_ctrl.value, i),
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(color: tokens.text3, shape: BoxShape.circle),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  double _dotOpacity(double t, int dotIndex) {
    final phase = (t - dotIndex * 0.18) % 1.0;
    final wave = (1 - (phase - 0.5).abs() * 2).clamp(0.0, 1.0);
    return 0.3 + 0.7 * wave;
  }
}

// ═════════════════════════════════════════════════════════════════════
// Composer
// ═════════════════════════════════════════════════════════════════════

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool stickersOpen;

  /// The attach panel is up: "+" is turned into "×".
  final bool attachOpen;
  final VoidCallback onSmilePressed;
  final VoidCallback? onSend;

  /// ↑ in the empty field on a hardware keyboard: edit my last message.
  final VoidCallback? onEditLast;
  final VoidCallback? onAttach;

  /// Tap on the mic: voice ⇄ round video (ADR-048).
  final VoidCallback? onMic;

  /// Press-and-hold on the mic (global position of the finger).
  final ValueChanged<Offset>? onMicHold;

  /// The mic button is a camera — holding records a round video.
  final bool videoMode;

  const _Composer({
    required this.controller,
    this.focusNode,
    required this.stickersOpen,
    this.attachOpen = false,
    required this.onSmilePressed,
    this.onSend,
    this.onEditLast,
    this.onAttach,
    this.onMic,
    this.onMicHold,
    this.videoMode = false,
  });

  @override
  Widget build(BuildContext context) {
    // Rebuild just the composer as the text changes (send ⇄ mic).
    final row = ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => _buildRow(context, value.text.trim().isNotEmpty),
    );
    final c = controller;
    if (c is! RichTextController) return row;
    // Pasted Markdown turned into formatting: offer it back as it came.
    return ValueListenableBuilder<PastedMarkdown?>(
      valueListenable: c.pastedMarkdown,
      builder: (context, pasted, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedSize(
            duration: DsMotion.of(context, DsMotion.base),
            curve: DsMotion.emphasized,
            child: pasted == null ? const SizedBox(width: double.infinity) : _PastedMarkdownBar(onRevert: c.revertPastedMarkdown),
          ),
          row,
        ],
      ),
    );
  }

  Widget _buildRow(BuildContext context, bool hasText) {
    final tokens = DsTheme.of(context);
    // No fill of its own: it sits on the glass bottom bar (DsBlurBar).
    return DecoratedBox(
      decoration: const BoxDecoration(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(DsSpace.x2h5, DsSpace.x2, DsSpace.x2h5, DsSpace.x2h5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            GestureDetector(
              key: const ValueKey('composer-attach'),
              behavior: HitTestBehavior.opaque,
              onTap: onAttach,
              child: Semantics(
                button: true,
                label: attachOpen ? context.l10n.a11yCloseAttach : context.l10n.a11yAttach,
                excludeSemantics: true,
                child: AnimatedContainer(
                  duration: DsMotion.of(context, DsMotion.base),
                  curve: DsMotion.emphasized,
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: attachOpen ? tokens.accentSoft : tokens.bgSoft,
                  ),
                  alignment: Alignment.center,
                  // A quarter-and-a-half turn: + → ×.
                  child: AnimatedRotation(
                    turns: attachOpen ? 0.125 : 0,
                    duration: DsMotion.of(context, DsMotion.base),
                    curve: DsMotion.enter,
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CustomPaint(
                        painter: DsGlyphPainter(DsGlyph.plus, color: attachOpen ? tokens.accent : tokens.text2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                constraints: const BoxConstraints(minHeight: 36),
                padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, 0, DsSpace.x1h5, 0),
                // The field is the incoming-bubble grey on light, a step lighter than the screen on dark.
                decoration: BoxDecoration(
                  color: DsTheme.isDarkOf(context) ? tokens.surface : tokens.bubbleIn,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: DsSpace.x1h5),
                        child: _DraftField(
                          controller: controller,
                          focusNode: focusNode,
                          onSend: onSend,
                          onEditLast: onEditLast,
                        ),
                      ),
                    ),
                    Semantics(
                      button: true,
                      label: stickersOpen ? context.l10n.emojiKeyboard : context.l10n.a11yEmoji,
                      excludeSemantics: true,
                      onTap: onSmilePressed,
                      child: GestureDetector(
                        key: const ValueKey('composer-emoji'),
                        behavior: HitTestBehavior.opaque,
                        onTap: onSmilePressed,
                        child: SizedBox(
                          width: 32,
                          height: 32,
                          child: Center(
                            child: AnimatedSwitcher(
                              duration: DsMotion.of(context, DsMotion.fast),
                              transitionBuilder: (c, a) => ScaleTransition(scale: a, child: FadeTransition(opacity: a, child: c)),
                              child: SizedBox(
                                key: ValueKey(stickersOpen),
                                width: 20,
                                height: 20,
                                child: CustomPaint(
                                  painter: stickersOpen
                                      ? DsGlyphPainter(DsGlyph.keyboard, color: tokens.accent)
                                      : _SmilePainter(color: tokens.text3),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Owner, 2026-10-18: "you press — nothing moves, recording starts
            // seconds later". The hold fires after [kMicHoldDelay] (Flutter's
            // long press waits 500 ms) and the button swells under the finger.
            RawGestureDetector(
              key: const ValueKey('composer-send-or-mic'),
              behavior: HitTestBehavior.opaque,
              gestures: {
                TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                  TapGestureRecognizer.new,
                  (r) => r.onTap = hasText ? onSend : onMic,
                ),
                if (!hasText && onMicHold != null)
                  LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                    () => LongPressGestureRecognizer(duration: kMicHoldDelay),
                    (r) => r.onLongPressStart = (d) => onMicHold!(d.globalPosition),
                  ),
              },
              child: Semantics(
                button: true,
                label: hasText
                    ? context.l10n.a11ySend
                    : videoMode
                    ? context.l10n.a11yRecordVideo
                    : context.l10n.a11yRecord,
                excludeSemantics: true,
                child: _PressScale(
                  pressed: hasText ? 0.9 : 1.18,
                  child: _RoundButton(
                    size: 36,
                    bg: tokens.accent,
                    child: AnimatedSwitcher(
                      duration: DsMotion.of(context, DsMotion.fast),
                      transitionBuilder: (c, a) => ScaleTransition(scale: a, child: FadeTransition(opacity: a, child: c)),
                      child: SizedBox(
                        key: ValueKey(hasText ? 'send' : (videoMode ? 'video' : 'mic')),
                        width: 20,
                        height: 20,
                        child: CustomPaint(
                          painter: DsGlyphPainter(
                            hasText
                                ? DsGlyph.send
                                : videoMode
                                ? DsGlyph.video
                                : DsGlyph.mic,
                            color: tokens.accentText,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Under the chat, over the composer: "Markdown turned into formatting ·
/// Undo" after pasting an AI's answer (ADR-070).
class _PastedMarkdownBar extends StatelessWidget {
  final VoidCallback onRevert;

  const _PastedMarkdownBar({required this.onRevert});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x2, DsSpace.x4, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              context.l10n.pasteMarkdownDone,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DsText.footnote.copyWith(color: tokens.text3),
            ),
          ),
          GestureDetector(
            key: const ValueKey('paste-md-revert'),
            behavior: HitTestBehavior.opaque,
            onTap: onRevert,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: DsSpace.x1, horizontal: DsSpace.x1),
              child: Text(
                context.l10n.pasteMarkdownRevert,
                style: DsText.footnote.copyWith(color: tokens.accent, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The composer's field — our typography, formatting painted as typed
/// (ADR-070). EditableText keeps it Material-free per §18.17.
class _DraftField extends StatefulWidget {
  final TextEditingController controller;

  /// From the chat screen (reply / edit focus the field); own otherwise.
  final FocusNode? focusNode;

  /// Enter on a hardware keyboard (ADR-076); ↑ in an empty field.
  final VoidCallback? onSend;
  final VoidCallback? onEditLast;
  const _DraftField({required this.controller, this.focusNode, this.onSend, this.onEditLast});

  @override
  State<_DraftField> createState() => _DraftFieldState();
}

class _DraftFieldState extends State<_DraftField> {
  late final FocusNode _own = FocusNode();
  FocusNode get _focus => widget.focusNode ?? _own;

  /// ⌘B / Ctrl+B… on a hardware keyboard (ADR-070); Enter sends, ↑ edits
  /// my last message (ADR-076).
  Widget _formatted(Widget field) {
    final onSend = widget.onSend;
    if (onSend != null) {
      field = SendShortcuts(controller: widget.controller, onSend: onSend, onEditLast: widget.onEditLast, child: field);
    }
    return switch (widget.controller) {
      final RichTextController c => RichFormatShortcuts(controller: c, child: field),
      _ => field,
    };
  }

  @override
  void dispose() {
    _own.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final hasText = widget.controller.text.isNotEmpty;
    return Stack(
      alignment: Alignment.centerLeft,
      children: [
        if (!hasText)
          IgnorePointer(
            child: Text(context.l10n.messagePlaceholder, style: DsText.body.copyWith(color: tokens.text3)),
          ),
        _formatted(
          DsPlainField(
            controller: widget.controller,
            focusNode: _focus,
            maxLines: 4,
            minLines: 1,
            // A message starts with a capital, like in Messages / Telegram.
            textCapitalization: TextCapitalization.sentences,
            style: DsText.body.copyWith(fontWeight: FontWeight.w500, color: tokens.text),
            cursorColor: tokens.accent,
            backgroundCursorColor: tokens.text4,
            // ADR-070 — the controller paints the formatting as typed; the
            // selection menu adds "Format".
            contextMenuBuilder: switch (widget.controller) {
              final RichTextController c => richFormatToolbar(c),
              _ => null,
            },
          ),
        ),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// In-chat mention picker + stickers tray (private impls — borrow demo
// data from compose / composer_pack but kept local to keep the chat-view
// surface self-contained).
// ═════════════════════════════════════════════════════════════════════

/// A group member offered by the @-picker (tech-debt 2.21).
class _ChatMentionCandidate {
  final String name;

  /// Identity key (hex) — what the mention carries.
  final String key;
  const _ChatMentionCandidate({required this.name, required this.key});

  String get username => shortKey(key);
}

class _ChatMentionPicker extends StatelessWidget {
  final String query;
  final List<_ChatMentionCandidate> candidates;
  final ValueChanged<_ChatMentionCandidate> onPick;
  const _ChatMentionPicker({required this.query, required this.candidates, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final q = query.toLowerCase();
    final filtered = [
      for (final c in candidates)
        if (q.isEmpty || c.name.toLowerCase().contains(q) || c.username.replaceAll(' ', '').contains(q)) c,
    ].take(5).toList();
    if (filtered.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(DsSpace.x2h5, 0, DsSpace.x2h5, DsSpace.x1h5),
      constraints: const BoxConstraints(maxHeight: 200),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tokens.dividerStrong, width: 0.5),
        boxShadow: const [DsShadow.art7],
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView.builder(
        shrinkWrap: true,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: DsSpace.x1h5),
        itemCount: filtered.length,
        itemBuilder: (ctx, i) => _ChatMentionRow(candidate: filtered[i], query: query, onPick: onPick),
      ),
    );
  }
}

class _ChatMentionRow extends StatelessWidget {
  final _ChatMentionCandidate candidate;
  final String query;
  final ValueChanged<_ChatMentionCandidate> onPick;
  const _ChatMentionRow({required this.candidate, required this.query, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return GestureDetector(
      key: ValueKey('mention-${candidate.key}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => onPick(candidate),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(DsSpace.x2h5, DsSpace.nudge7, DsSpace.x2h5, DsSpace.nudge7),
        child: Row(
          children: [
            DsAvatar(name: candidate.name, size: 30),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ChatMentionHighlight(
                    text: candidate.name,
                    query: query,
                    accent: tokens.accent,
                    baseStyle: DsText.callout.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
                  ),
                  Text(candidate.username, style: DsTextArt.t11p5w500Mono.copyWith(color: tokens.text3)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatMentionHighlight extends StatelessWidget {
  final String text;
  final String query;
  final TextStyle baseStyle;
  final Color accent;
  const _ChatMentionHighlight({required this.text, required this.query, required this.baseStyle, required this.accent});

  @override
  Widget build(BuildContext context) {
    final q = query.trim();
    if (q.isEmpty) return Text(text, style: baseStyle);
    final lower = text.toLowerCase();
    final qLower = q.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    while (start < text.length) {
      final idx = lower.indexOf(qLower, start);
      if (idx == -1) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (idx > start) {
        spans.add(TextSpan(text: text.substring(start, idx)));
      }
      spans.add(
        TextSpan(
          text: text.substring(idx, idx + q.length),
          style: baseStyle.copyWith(color: accent, fontWeight: FontWeight.w700),
        ),
      );
      start = idx + q.length;
    }
    return Text.rich(TextSpan(style: baseStyle, children: spans));
  }
}

class _RoundButton extends StatelessWidget {
  final double size;
  final Color bg;
  final Widget child;

  const _RoundButton({required this.size, required this.bg, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Center(child: child),
    );
  }
}

/// How long the mic is held before recording starts. Shorter than a tap
/// is never: a tap (voice ⇄ video) is over in ~100 ms.
const kMicHoldDelay = Duration(milliseconds: 200);

/// Scales its child while a finger is on it — the first sign the press
/// was felt, before anything else happens.
class _PressScale extends StatefulWidget {
  const _PressScale({required this.pressed, required this.child});

  /// The scale under the finger.
  final double pressed;
  final Widget child;

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
  bool _down = false;

  void _set(bool v) {
    // The finger lifts after a hold has swapped the composer for the
    // recording bar — this button is gone by then.
    if (mounted && _down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => _set(true),
    onPointerUp: (_) => _set(false),
    onPointerCancel: (_) => _set(false),
    child: AnimatedScale(
      scale: _down ? widget.pressed : 1,
      duration: DsMotion.of(context, DsMotion.fast),
      curve: DsMotion.enter,
      child: widget.child,
    ),
  );
}

// ═════════════════════════════════════════════════════════════════════
// Painters (unchanged from base port)
// ═════════════════════════════════════════════════════════════════════

class _VideoPainter extends CustomPainter {
  final Color color;
  _VideoPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(2.5, 6, 13, 12), const Radius.circular(2.5)), stroke);
    final wedge = Path()
      ..moveTo(15.5, 10)
      ..lineTo(20.5, 7.5)
      ..lineTo(20.5, 16.5)
      ..lineTo(15.5, 14)
      ..close();
    canvas.drawPath(wedge, stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_VideoPainter old) => old.color != color;
}

class _PhonePainter extends CustomPainter {
  final Color color;
  _PhonePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final p = Path()
      ..moveTo(22, 16.92)
      ..lineTo(22, 19.92)
      ..arcToPoint(const Offset(19.82, 21.92), radius: const Radius.circular(2))
      ..arcToPoint(const Offset(11.19, 18.85), radius: const Radius.circular(19.79))
      ..arcToPoint(const Offset(5.19, 12.85), radius: const Radius.circular(19.5))
      ..arcToPoint(const Offset(2.12, 4.18), radius: const Radius.circular(19.79))
      ..arcToPoint(const Offset(4.11, 2), radius: const Radius.circular(2))
      ..lineTo(7.11, 2)
      ..arcToPoint(const Offset(9.11, 3.72), radius: const Radius.circular(2))
      ..cubicTo(9.24, 4.68, 9.47, 5.62, 9.81, 6.53)
      ..arcToPoint(const Offset(9.36, 8.64), radius: const Radius.circular(2))
      ..lineTo(8.09, 9.91)
      ..arcToPoint(const Offset(14.09, 15.91), radius: const Radius.circular(16), clockwise: false)
      ..lineTo(15.36, 14.64)
      ..arcToPoint(const Offset(17.47, 14.19), radius: const Radius.circular(2))
      ..cubicTo(18.38, 14.53, 19.32, 14.76, 20.28, 14.89)
      ..arcToPoint(const Offset(22, 16.92), radius: const Radius.circular(2))
      ..close();
    canvas.drawPath(p, stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PhonePainter old) => old.color != color;
}

class _SmilePainter extends CustomPainter {
  final Color color;
  _SmilePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(const Offset(12, 12), 9, stroke);
    final smile = Path()
      ..moveTo(8.5, 14)
      ..cubicTo(9.2, 15, 10.4, 15.7, 12, 15.7)
      ..cubicTo(13.6, 15.7, 14.8, 15, 15.5, 14);
    canvas.drawPath(smile, stroke);
    canvas.drawCircle(const Offset(9, 10), 1.1, fill);
    canvas.drawCircle(const Offset(15, 10), 1.1, fill);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SmilePainter old) => old.color != color;
}

class _PlayTrianglePainter extends CustomPainter {
  final Color color;
  _PlayTrianglePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 12;
    final sy = size.height / 14;
    canvas.save();
    canvas.scale(sx, sy);
    final p = Path()
      ..moveTo(1, 1)
      ..lineTo(11, 7)
      ..lineTo(1, 13)
      ..close();
    canvas.drawPath(
      p,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PlayTrianglePainter old) => old.color != color;
}

/// ✓ sent · ✓✓ delivered · ✓✓ (light blue) read · clock sending · ! failed.
class _StatusPainter extends CustomPainter {
  final Color color;
  final int status;
  _StatusPainter({required this.color, required this.status});

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 22;
    final sy = size.height / 14;
    canvas.save();
    canvas.scale(sx, sy);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (status == MsgStatus.sending) {
      canvas.drawCircle(const Offset(11, 7), 5.5, stroke..strokeWidth = 1.4);
      canvas.drawLine(const Offset(11, 4), const Offset(11, 7), stroke);
      canvas.drawLine(const Offset(11, 7), const Offset(13.5, 8.5), stroke);
      canvas.restore();
      return;
    }
    if (status == MsgStatus.failed) {
      canvas.drawCircle(const Offset(11, 7), 6, stroke..strokeWidth = 1.4);
      canvas.drawLine(const Offset(11, 3.8), const Offset(11, 7.6), stroke);
      canvas.drawCircle(const Offset(11, 10), 0.6, stroke);
      canvas.restore();
      return;
    }
    final p1 = Path()
      ..moveTo(1, 7)
      ..lineTo(5.5, 11.5)
      ..lineTo(13, 4);
    canvas.drawPath(p1, stroke);
    if (status >= MsgStatus.delivered) {
      final p2 = Path()
        ..moveTo(9, 7)
        ..lineTo(13.5, 11.5)
        ..lineTo(21, 4);
      canvas.drawPath(p2, stroke);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StatusPainter old) => old.color != color || old.status != status;
}

// ═════════════════════════════════════════════════════════════════════
// Media composer pieces (ADR-017)
// ═════════════════════════════════════════════════════════════════════

/// Camera / Photos / Video / File — round tiles above the composer, opened
/// by "+". Coloured badges with a soft gradient and a staggered rise, like
/// the attach sheets people know from Telegram and iMessage.
/// Camera / Photos / Video / Document, in the keyboard's place under the
/// composer — part of the bottom bar, not a card floating over the chat.
class _AttachPanel extends StatefulWidget {
  final VoidCallback onCamera;
  final VoidCallback onPhotos;
  final VoidCallback onVideo;
  final VoidCallback onDocument;

  /// The home indicator's room (the composer above gives it up while a
  /// panel is open).
  final double bottomPad;

  const _AttachPanel({
    required this.onCamera,
    required this.onPhotos,
    required this.onVideo,
    required this.onDocument,
    this.bottomPad = 0,
  });

  @override
  State<_AttachPanel> createState() => _AttachPanelState();
}

class _AttachPanelState extends State<_AttachPanel> with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(vsync: this, duration: DsMotion.slow)..forward();

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = [
      ('attach-camera', context.l10n.camera, DsGlyph.camera, DsPalette.blue, widget.onCamera),
      ('attach-photos', context.l10n.photos, DsGlyph.gallery, DsPalette.indigo, widget.onPhotos),
      ('attach-video', context.l10n.video, DsGlyph.video, DsPalette.pink, widget.onVideo),
      ('attach-document', context.l10n.document, DsGlyph.document, DsPalette.orange, widget.onDocument),
    ];
    return ColoredBox(
      key: const ValueKey('attach-panel'),
      // The glass bottom bar shows through.
      color: DsPalette.transparent,
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: EdgeInsets.fromLTRB(DsSpace.x3, DsSpace.x5, DsSpace.x3, DsSpace.x6 + widget.bottomPad),
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: _AttachTile(
                    key: ValueKey(items[i].$1),
                    label: items[i].$2,
                    glyph: items[i].$3,
                    color: items[i].$4,
                    onTap: items[i].$5,
                    // Each tile rises a beat after the one before it.
                    appear: CurvedAnimation(
                      parent: _in,
                      curve: Interval(i * 0.12, 0.64 + i * 0.12, curve: DsMotion.emphasized),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AttachTile extends StatelessWidget {
  const _AttachTile({
    super.key,
    required this.label,
    required this.glyph,
    required this.color,
    required this.onTap,
    required this.appear,
  });

  final String label;
  final DsGlyph glyph;
  final Color color;
  final VoidCallback onTap;
  final Animation<double> appear;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final top = Color.lerp(color, DsPalette.white, 0.22)!;
    return AnimatedBuilder(
      animation: appear,
      builder: (context, child) => Opacity(
        opacity: appear.value.clamp(0.0, 1.0),
        child: Transform.translate(offset: Offset(0, (1 - appear.value) * 14), child: child),
      ),
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: DsPressable(
          onTap: onTap,
          scale: 0.9,
          haptic: Haptic.selection,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [top, color]),
                  boxShadow: [DsShadow.glowOf(color, alpha: 0.32, y: 4, blur: 12)],
                ),
                alignment: Alignment.center,
                child: CustomPaint(
                  size: const Size.square(26),
                  painter: DsGlyphPainter(glyph, color: DsPalette.white, strokeWidth: 1.9),
                ),
              ),
              const SizedBox(height: DsSpace.x2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DsText.footnote.copyWith(fontWeight: FontWeight.w500, color: tokens.text2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Replaces the composer while a voice message is being recorded.
class _RecordingBar extends StatefulWidget {
  /// How long it has been recording.
  final Duration Function() elapsed;

  /// Voice: the live level meter; null for a round video (ADR-048).
  final List<int> Function()? levels;
  final VoidCallback onCancel;
  final VoidCallback onSend;

  /// Non-null while the finger is still on the mic: show "slide to
  /// cancel" / "slide up to lock" instead of the buttons.
  final ValueListenable<Offset>? hold;

  /// Mic or camera — the big round button under the finger while held.
  final DsGlyph glyph;

  const _RecordingBar({
    super.key,
    required this.elapsed,
    this.levels,
    required this.onCancel,
    required this.onSend,
    this.hold,
    this.glyph = DsGlyph.mic,
  });

  @override
  State<_RecordingBar> createState() => _RecordingBarState();
}

/// Ticks itself (timer + live level meter) so only this bar rebuilds.
class _RecordingBarState extends State<_RecordingBar> {
  Timer? _tick;

  /// Drives the red dot's blink and the held button's breathing.
  final Stopwatch _since = Stopwatch()..start();

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() {});
    });
  }

  /// 0..1, one slow breath a second.
  double get _breath => 0.5 + 0.5 * math.sin(_since.elapsedMilliseconds / 1000 * 2 * math.pi);

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  VoidCallback get onCancel => widget.onCancel;
  VoidCallback get onSend => widget.onSend;
  Duration get elapsed => widget.elapsed();

  /// "‹ Slide to cancel   ↑ lock", following the finger to the left.
  static Widget _holdHint(BuildContext context, DsTokens tokens, ValueListenable<Offset> hold) =>
      ValueListenableBuilder<Offset>(
        valueListenable: hold,
        builder: (_, d, _) {
          final pull = d.dx.clamp(-120.0, 0.0);
          return Transform.translate(
            offset: Offset(pull * 0.6, 0),
            child: Opacity(
              opacity: (1 + pull / 160).clamp(0.2, 1.0),
              child: Text(
                context.l10n.slideToCancel,
                key: const ValueKey('recording-hold-hint'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DsText.subhead.copyWith(color: tokens.text3),
              ),
            ),
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.bg,
        border: Border(top: BorderSide(color: tokens.divider, width: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x2h5, DsSpace.x2h5, DsSpace.x2h5),
        child: Row(
          children: [
            Opacity(
              key: const ValueKey('recording-dot'),
              opacity: DsMotion.reduced(context) ? 1 : 0.35 + 0.65 * _breath,
              child: Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(color: DsPalette.alert, shape: BoxShape.circle),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatVoiceDuration(elapsed.inMilliseconds),
              key: const ValueKey('recording-time'),
              style: DsText.body.copyWith(color: tokens.text),
            ),
            const SizedBox(width: 10),
            // A round video has no level meter: the hint takes its place
            // (and shortens on a narrow phone instead of overflowing).
            Expanded(
              child: widget.levels == null && widget.hold != null
                  ? Align(alignment: Alignment.centerRight, child: _holdHint(context, tokens, widget.hold!))
                  : SizedBox(
                      height: 24,
                      child: widget.levels == null
                          ? null
                          : CustomPaint(
                              painter: WaveformPainter(
                                levels: Uint8List.fromList(widget.levels!()),
                                progress: 1,
                                color: tokens.accent,
                              ),
                            ),
                    ),
            ),
            const SizedBox(width: 10),
            if (widget.hold != null) ...[
              if (widget.levels != null) _holdHint(context, tokens, widget.hold!),
              const SizedBox(width: 10),
              // The button under the finger, bigger and breathing — the
              // recording is on (Telegram-style).
              Transform.scale(
                key: const ValueKey('recording-held-button'),
                scale: DsMotion.reduced(context) ? 1 : 1 + 0.06 * _breath,
                child: _RoundButton(
                  size: 44,
                  bg: tokens.accent,
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CustomPaint(painter: DsGlyphPainter(widget.glyph, color: tokens.accentText)),
                  ),
                ),
              ),
            ] else ...[
              GestureDetector(
                key: const ValueKey('recording-cancel'),
                behavior: HitTestBehavior.opaque,
                onTap: onCancel,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: DsSpace.x2, vertical: DsSpace.x2),
                  child: Text(context.l10n.cancel, style: DsText.body.copyWith(color: tokens.text2)),
                ),
              ),
              GestureDetector(
                key: const ValueKey('recording-send'),
                behavior: HitTestBehavior.opaque,
                onTap: onSend,
                child: _RoundButton(
                  size: 36,
                  bg: tokens.accent,
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CustomPaint(painter: DsGlyphPainter(DsGlyph.send, color: tokens.accentText)),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// ADR-048 — the round video while it records: the live picture in a
/// circle over the dimmed chat, a ring filling up to the 60 s cap, and a
/// flip-camera button. Ticks itself, like [_RecordingBar].
class _VideoNoteOverlay extends StatefulWidget {
  const _VideoNoteOverlay({required this.recorder, required this.bottomInset});

  final VideoNoteRecorder recorder;

  /// The composer's height — the circle centres in the space above it.
  final double bottomInset;

  @override
  State<_VideoNoteOverlay> createState() => _VideoNoteOverlayState();
}

class _VideoNoteOverlayState extends State<_VideoNoteOverlay> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final size = MediaQuery.sizeOf(context);
    final d = (size.shortestSide - 64).clamp(160.0, 320.0);
    const ring = 6.0;
    final pct = widget.recorder.elapsed.inMilliseconds / kMaxVideoNoteDuration.inMilliseconds;
    return ColoredBox(
      key: const ValueKey('video-note-overlay'),
      color: DsPalette.black60,
      child: Padding(
        padding: EdgeInsets.only(bottom: widget.bottomInset),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: d + ring * 2,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        key: const ValueKey('video-note-record-ring'),
                        painter: DsProgressRingPainter(
                          pct: pct.clamp(0.0, 1.0),
                          trackColor: DsPalette.white25,
                          fillColor: tokens.accent,
                          strokeWidth: 4,
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.all(ring),
                        child: ClipOval(
                          child: ColoredBox(
                            color: DsPalette.black,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                widget.recorder.preview(),
                                // The circle is up at once; the camera
                                // takes a moment to open.
                                if (!widget.recorder.isRecording)
                                  const Center(
                                    key: ValueKey('video-note-starting'),
                                    child: DsSpinner(color: DsPalette.white, size: 28),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.recorder.canSwitchCamera) ...[
                const SizedBox(height: 20),
                Semantics(
                  button: true,
                  label: context.l10n.callFlipCamera,
                  excludeSemantics: true,
                  child: GestureDetector(
                    key: const ValueKey('video-note-flip'),
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.recorder.switchCamera,
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: const BoxDecoration(color: DsPalette.black60, shape: BoxShape.circle),
                      alignment: Alignment.center,
                      child: const CallCameraSwitchGlyph(color: DsPalette.white),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Lifts its child above the keyboard (or the home indicator). Reads the
/// insets itself so keyboard animation frames rebuild only the composer,
/// not the whole chat. (Bare WidgetsApp: no Scaffold resizing.)
class _KeyboardInset extends StatelessWidget {
  final bool stickersOpen;
  final Widget child;

  const _KeyboardInset({required this.stickersOpen, required this.child});

  /// The keyboard's height last time it was up (the app root lifts every
  /// screen above the keyboard — `AvoidKeyboard`); the emoji panel takes
  /// the same place.
  static double get lastKeyboard => AvoidKeyboard.lastKeyboard;

  @override
  Widget build(BuildContext context) {
    // Above the keyboard the safe-area bottom is 0; without it, the home
    // indicator's. The emoji panel brings its own.
    final safe = MediaQuery.paddingOf(context).bottom;
    if (stickersOpen) return child;
    return Padding(padding: EdgeInsets.only(bottom: safe), child: child);
  }
}

// ═════════════════════════════════════════════════════════════════════
// ADR-019 / backlog §3 — chat chrome: pinned strip, reply/edit bar,
// selection header, newest-end button, unread divider, appear animation
// ═════════════════════════════════════════════════════════════════════

/// Registers a bubble's on-screen box for the floating day pill.
class _DayProbe extends StatefulWidget {
  const _DayProbe({required this.day, required this.registry, required this.child});
  final String day;
  final Set<_DayProbeState> registry;
  final Widget child;

  @override
  State<_DayProbe> createState() => _DayProbeState();
}

class _DayProbeState extends State<_DayProbe> {
  @override
  void initState() {
    super.initState();
    widget.registry.add(this);
  }

  @override
  void dispose() {
    widget.registry.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// New bubble: rises and settles with a spring; a sent one comes from
/// the composer side.
class _AppearIn extends StatefulWidget {
  const _AppearIn({required this.child, this.fromSide = -1});
  final Widget child;

  /// 1 = from the right (mine), -1 = from the left.
  final double fromSide;

  @override
  State<_AppearIn> createState() => _AppearInState();
}

class _AppearInState extends State<_AppearIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: DsMotion.slow);

  @override
  void initState() {
    super.initState();
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (DsMotion.reduced(context)) return widget.child;
    final pos = CurvedAnimation(parent: _c, curve: DsMotion.enter);
    final fade = CurvedAnimation(
      parent: _c,
      curve: const Interval(0, 0.5, curve: Curves.easeOut),
    );
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) => Opacity(
        opacity: fade.value.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, 24 * (1 - pos.value)),
          child: Transform.scale(
            scale: 0.92 + 0.08 * pos.value,
            alignment: widget.fromSide > 0 ? Alignment.bottomRight : Alignment.bottomLeft,
            child: child,
          ),
        ),
      ),
    );
  }
}

class _UnreadDividerRow extends StatelessWidget {
  const _UnreadDividerRow();

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      key: const ValueKey('unread-divider'),
      margin: const EdgeInsets.symmetric(vertical: DsSpace.x2h5),
      padding: const EdgeInsets.symmetric(vertical: DsSpace.nudge5),
      color: tokens.bgSoft,
      alignment: Alignment.center,
      child: Text(
        context.l10n.unreadMessages,
        style: DsText.footnote.copyWith(fontWeight: FontWeight.w600, color: tokens.text3),
      ),
    );
  }
}

class _OngoingCallBar extends StatelessWidget {
  const _OngoingCallBar({required this.video, required this.onJoin});
  final bool video;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      key: const ValueKey('ongoing-call-bar'),
      padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x2, DsSpace.x2, DsSpace.x2),
      decoration: BoxDecoration(
        color: tokens.bg,
        border: Border(bottom: BorderSide(color: tokens.divider, width: 0.5)),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: tokens.success, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              video ? context.l10n.callOngoingVideo : context.l10n.callOngoing,
              style: DsText.subhead.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
            ),
          ),
          DsButton(
            key: const ValueKey('ongoing-call-join'),
            label: context.l10n.callJoin,
            size: DsButtonSize.small,
            fullWidth: false,
            onPressed: onJoin,
          ),
        ],
      ),
    );
  }
}

class _PinnedBar extends StatelessWidget {
  const _PinnedBar({required this.text, this.onTap, this.onUnpin});
  final String text;
  final VoidCallback? onTap;
  final VoidCallback? onUnpin;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return GestureDetector(
      key: const ValueKey('pinned-bar'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x2, DsSpace.x1h5, DsSpace.x2),
        decoration: BoxDecoration(
          color: tokens.bg,
          border: Border(bottom: BorderSide(color: tokens.divider, width: 0.5)),
        ),
        child: Row(
          children: [
            Container(width: 2.5, height: 30, color: tokens.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    context.l10n.pinnedMessage,
                    style: DsText.footnote.copyWith(fontWeight: FontWeight.w600, color: tokens.accent),
                  ),
                  Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DsText.subhead.copyWith(color: tokens.text2),
                  ),
                ],
              ),
            ),
            GestureDetector(
              key: const ValueKey('unpin'),
              behavior: HitTestBehavior.opaque,
              onTap: onUnpin,
              child: Padding(
                padding: const EdgeInsets.all(DsSpace.x2),
                child: Icon(CupertinoIcons.xmark, size: 16, color: tokens.text3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Reply to …" / "Edit message" strip above the composer.
class _ComposerModeBar extends StatelessWidget {
  const _ComposerModeBar({
    required this.reply,
    required this.editing,
    required this.contactName,
    required this.onCancel,
  });

  final ValueListenable<ReplyTarget?> reply;
  final ValueListenable<_Msg?> editing;
  final String contactName;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([reply, editing]),
      builder: (context, _) {
        final r = reply.value;
        final e = editing.value;
        final Widget child;
        if (r == null && e == null) {
          child = const SizedBox(width: double.infinity);
        } else {
          final title = e != null
              ? context.l10n.editMessage
              : (r!.mine ? context.l10n.replyToYourself : context.l10n.replyTo(contactName));
          final body = e != null ? (e.text ?? '') : r!.snippet;
          // The strip grows (AnimatedSize below) while its content rises in;
          // switching reply ↔ edit, the new content rises in again.
          child = DsAppear(
            key: ValueKey('mode:$title|$body'),
            offset: const Offset(0, 8),
            child: Container(
              key: ValueKey(e != null ? 'edit-bar' : 'reply-bar'),
              padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x2, DsSpace.x1h5, DsSpace.x2),
              decoration: BoxDecoration(
                color: tokens.bg,
                border: Border(top: BorderSide(color: tokens.divider, width: 0.5)),
              ),
              child: Row(
                children: [
                  Container(width: 2.5, height: 32, color: tokens.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: DsText.footnote.copyWith(fontWeight: FontWeight.w600, color: tokens.accent),
                        ),
                        Text(
                          body,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DsText.subhead.copyWith(color: tokens.text2),
                        ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    key: const ValueKey('composer-mode-cancel'),
                    behavior: HitTestBehavior.opaque,
                    onTap: onCancel,
                    child: Padding(
                      padding: const EdgeInsets.all(DsSpace.x2),
                      child: Icon(CupertinoIcons.xmark, size: 17, color: tokens.text3),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        return AnimatedSize(
          duration: DsMotion.of(context, DsMotion.fast),
          curve: DsMotion.enter,
          alignment: Alignment.bottomCenter,
          child: child,
        );
      },
    );
  }
}

class _SelectionHeader extends StatelessWidget {
  const _SelectionHeader({super.key, required this.count, required this.onCancel, required this.onCopy});

  final int count;
  final VoidCallback onCancel;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1h5),
      decoration: BoxDecoration(
        color: tokens.bg,
        border: Border(bottom: BorderSide(color: tokens.divider, width: 0.5)),
      ),
      child: Row(
        children: [
          _BarAction(context.l10n.cancel, onCancel, key: const ValueKey('selection-cancel')),
          Expanded(
            child: Text(
              context.l10n.selectedCount(count),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DsText.body.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
            ),
          ),
          _BarAction(context.l10n.copy, onCopy, key: const ValueKey('selection-copy')),
        ],
      ),
    );
  }
}

/// Replaces the composer in selection mode: Delete · Forward.
/// Message request (tech-debt 2.27): shown instead of the composer until
/// the chat is accepted, blocked or deleted.
class _RequestBar extends StatelessWidget {
  const _RequestBar({
    required this.name,
    required this.canBlock,
    required this.onAccept,
    required this.onBlock,
    required this.onDelete,
  });
  final String name;
  final bool canBlock;
  final VoidCallback onAccept;
  final VoidCallback onBlock;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    final pad = MediaQuery.paddingOf(context);
    return Container(
      key: const ValueKey('request-bar'),
      padding: EdgeInsets.fromLTRB(DsSpace.gutter, DsSpace.x3, DsSpace.gutter, DsSpace.x3 + pad.bottom),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border(top: BorderSide(color: tokens.divider, width: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l.requestTitle, style: DsText.headline.copyWith(color: tokens.text)),
          const SizedBox(height: DsSpace.x1),
          Text(
            l.requestBody,
            textAlign: TextAlign.center,
            style: DsText.subhead.copyWith(color: tokens.text2),
          ),
          const SizedBox(height: DsSpace.x3),
          Row(
            children: [
              if (canBlock) ...[
                Expanded(
                  flex: 3, // the longest word of the three
                  child: DsButton(
                    key: const ValueKey('request-block'),
                    label: l.chatInfoBlock,
                    variant: DsButtonVariant.secondary,
                    size: DsButtonSize.medium,
                    onPressed: onBlock,
                  ),
                ),
                const SizedBox(width: DsSpace.x2),
              ],
              Expanded(
                flex: 2,
                child: DsButton(
                  key: const ValueKey('request-delete'),
                  label: l.delete,
                  variant: DsButtonVariant.secondary,
                  size: DsButtonSize.medium,
                  onPressed: onDelete,
                ),
              ),
              const SizedBox(width: DsSpace.x2),
              Expanded(
                flex: 2,
                child: DsButton(
                  key: const ValueKey('request-accept'),
                  label: l.requestAccept,
                  size: DsButtonSize.medium,
                  onPressed: onAccept,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// ADR-035 — shown instead of the composer once a group removed me: the
/// history stays readable; the chat can be deleted.
/// In place of the composer in a chat with someone I blocked.
class _BlockedBar extends StatelessWidget {
  const _BlockedBar({required this.name, required this.onUnblock});
  final String name;
  final VoidCallback onUnblock;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    final pad = MediaQuery.paddingOf(context);
    return Padding(
      key: const ValueKey('blocked-bar'),
      padding: EdgeInsets.fromLTRB(DsSpace.gutter, DsSpace.x3, DsSpace.gutter, DsSpace.x3 + pad.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l.blockedChatNote(name),
            textAlign: TextAlign.center,
            style: DsText.subhead.copyWith(color: tokens.text2),
          ),
          const SizedBox(height: DsSpace.x3),
          DsButton(
            key: const ValueKey('blocked-unblock'),
            label: l.blockedUnblock,
            variant: DsButtonVariant.secondary,
            size: DsButtonSize.medium,
            onPressed: onUnblock,
          ),
        ],
      ),
    );
  }
}

class _NotMemberBar extends StatelessWidget {
  const _NotMemberBar({required this.onDelete});
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    final pad = MediaQuery.paddingOf(context);
    return Container(
      key: const ValueKey('not-member-bar'),
      padding: EdgeInsets.fromLTRB(DsSpace.gutter, DsSpace.x3, DsSpace.gutter, DsSpace.x3 + pad.bottom),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border(top: BorderSide(color: tokens.divider, width: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l.groupNotMember,
            textAlign: TextAlign.center,
            style: DsText.subhead.copyWith(color: tokens.text2),
          ),
          const SizedBox(height: DsSpace.x3),
          DsButton(
            key: const ValueKey('not-member-delete'),
            label: l.deleteChat,
            variant: DsButtonVariant.secondary,
            size: DsButtonSize.medium,
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({required this.onDelete, required this.onForward});
  final VoidCallback onDelete;
  final VoidCallback onForward;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(DsSpace.x2, DsSpace.x1, DsSpace.x2, bottom > 0 ? bottom : DsSpace.x2),
      decoration: BoxDecoration(
        color: tokens.bg,
        border: Border(top: BorderSide(color: tokens.divider, width: 0.5)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _BarAction(context.l10n.delete, onDelete, color: tokens.danger, key: const ValueKey('selection-delete')),
          _BarAction(context.l10n.forward, onForward, key: const ValueKey('selection-forward')),
        ],
      ),
    );
  }
}

class _BarAction extends StatelessWidget {
  const _BarAction(this.label, this.onTap, {super.key, this.color});
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x2h5, vertical: DsSpace.x3),
        child: Text(label, style: DsText.bodyLarge.copyWith(color: color ?? tokens.accent)),
      ),
    );
  }
}

/// Round "↓" with the number of messages that arrived below.
class _DownButton extends StatelessWidget {
  const _DownButton({required this.visible, required this.newCount, required this.onTap});
  final bool visible;
  final ValueListenable<int> newCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedScale(
        scale: visible ? 1 : 0.6,
        duration: DsMotion.of(context, DsMotion.base),
        curve: visible ? DsMotion.enter : DsMotion.exit,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: DsMotion.of(context, DsMotion.fast),
          child: GestureDetector(
            key: const ValueKey('jump-to-newest'),
            onTap: onTap,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: tokens.surface,
                    shape: BoxShape.circle,
                    border: Border.all(color: tokens.dividerStrong, width: 0.5),
                    boxShadow: DsShadow.float,
                  ),
                  child: Icon(CupertinoIcons.chevron_down, size: 20, color: tokens.text2),
                ),
                Positioned(
                  top: -6,
                  right: -4,
                  child: ValueListenableBuilder<int>(
                    valueListenable: newCount,
                    builder: (_, n, _) => n == 0
                        ? const SizedBox.shrink()
                        : Container(
                            key: const ValueKey('new-below-count'),
                            padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1h5, vertical: DsSpace.x0h5),
                            decoration: BoxDecoration(color: tokens.accent, borderRadius: BorderRadius.circular(10)),
                            child: Text('$n', style: DsTextArt.t11w700.copyWith(color: tokens.accentText)),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
