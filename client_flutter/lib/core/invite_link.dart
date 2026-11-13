// ADR-043 — invite links: `https://<server>/join#<signed payload>`, shared
// as the short `https://<server>/i/<id>#<key>` (the server keeps the signed
// link sealed under `key`; `invite_link_resolve` fetches and opens it, then
// it goes on as the long one; `sinhron://i/<server>/<id>#…` from the page).
//
// The owner taps Share on "My QR code" → the link goes by any messenger →
// the person taps it: with Sinhron installed the phone opens it in the app
// (iOS universal link / Android App Link; `sinhron://join#…` from the web
// page's button), without it the server's /join page says how to install.
// Rust checks the signature (`invite_link_open`): a changed server, key or
// name is refused. Navigation (what to show) is `handleInviteLink` in
// app/navigation.dart; this file is the plumbing and the testable parts.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/rust/api/simple.dart' as core;

/// A verified invite.
typedef OpenedInvite = ({String serverHost, String identityHex, String name});

/// Why a link was refused: `forged` (changed / signed by someone else),
/// `damaged`, `expired` / `offline` (a short link: gone from its server /
/// the server can't be reached), `not_invite` (some other link — ignored).
class InviteLinkError implements Exception {
  const InviteLinkError(this.code);
  final String code;
  @override
  String toString() => 'InviteLinkError($code)';
}

/// The native side: links that opened the app (faked in tests).
abstract class InviteLinkPlatform {
  /// A link that started the app before Dart listened, once.
  Future<String?> takeInitial();

  /// Links while the app runs.
  Stream<String> get links;
}

class ChannelInviteLinkPlatform implements InviteLinkPlatform {
  ChannelInviteLinkPlatform() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'link' && call.arguments is String) _links.add(call.arguments as String);
      return true;
    });
  }

  static const _channel = MethodChannel('dev.sinhron/links');
  final _links = StreamController<String>.broadcast();

  @override
  Stream<String> get links => _links.stream;

  @override
  Future<String?> takeInitial() async {
    try {
      return await _channel.invokeMethod<String>('takeInitial');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

final inviteLinkPlatformProvider = Provider<InviteLinkPlatform>((ref) => ChannelInviteLinkPlatform());

/// A short invite link: `https://<host>/i/<id>#<key>` or `sinhron://i/<host>/<id>#<key>`.
bool isShortInviteLink(String link) {
  final l = link.trim().toLowerCase();
  if (l.startsWith('sinhron://i/')) return true;
  if (!l.startsWith('https://')) return false;
  final slash = l.indexOf('/', 'https://'.length);
  return slash > 0 && l.startsWith('/i/', slash);
}

/// The server a short link is fetched from, as Rust reads it (`parse_short_link`).
String shortInviteHost(String link) {
  final l = link.trim().toLowerCase().split('#').first.split('?').first;
  final rest = l.startsWith('sinhron://i/') ? l.substring(12) : (l.startsWith('https://') ? l.substring(8) : '');
  final host = rest.split('/').first.replaceAll(RegExp(r'\.$'), '');
  return host.endsWith(':443') ? host.substring(0, host.length - 4) : host;
}

/// A short link → the long one it stands for (Rust fetches and opens it).
/// Throws [InviteLinkError] `expired` / `offline` / `damaged`.
final inviteResolverProvider = Provider<Future<String> Function(String link)>(
  (ref) =>
      (link) async {
        try {
          return await core.inviteLinkResolve(link: link);
        } catch (e) {
          final s = e.toString();
          throw InviteLinkError(
            s.contains('expired')
                ? 'expired'
                : s.contains('offline')
                ? 'offline'
                : 'damaged',
          );
        }
      },
);

/// Verify a link (Rust); a short one is resolved first. Throws [InviteLinkError].
final inviteOpenerProvider = Provider<Future<OpenedInvite> Function(String link)>(
  (ref) =>
      (link) async {
        if (isShortInviteLink(link)) link = await ref.read(inviteResolverProvider)(link);
        try {
          final l = await core.inviteLinkOpen(link: link);
          return (serverHost: l.serverHost, identityHex: l.identityHex, name: l.name);
        } catch (e) {
          final s = e.toString();
          throw InviteLinkError(
            s.contains('forged')
                ? 'forged'
                : s.contains('not_invite')
                ? 'not_invite'
                : 'damaged',
          );
        }
      },
);

/// My signed link for the server I'm on (Rust signs with my key) — short
/// when the server keeps it, else the long one.
final inviteLinkCreatorProvider = Provider<Future<String> Function(String serverHost, String name)>(
  (ref) =>
      (serverHost, name) => core.inviteLinkCreate(serverHost: serverHost, name: name),
);

/// Invite accepted by someone without an account yet: kept through
/// onboarding, offered again once the account exists.
class PendingInvite extends Notifier<OpenedInvite?> {
  @override
  OpenedInvite? build() => null;

  void set(OpenedInvite? invite) => state = invite;

  /// Read and clear.
  OpenedInvite? take() {
    final v = state;
    state = null;
    return v;
  }
}

final pendingInviteProvider = NotifierProvider<PendingInvite, OpenedInvite?>(PendingInvite.new);

/// What to do with a verified invite, given the account on this phone.
enum InviteAction {
  /// No account here yet: start one on the invite's server.
  newAccount,

  /// Same server: offer to add the inviter.
  addContact,

  /// It's my own link.
  self,

  /// My account is on another server — chats don't cross servers.
  otherServer,
}

InviteAction inviteActionFor(
  OpenedInvite invite, {
  required bool hasAccount,
  required String? myIdentityHex,
  required String myServerHost,
}) {
  if (!hasAccount) return InviteAction.newAccount;
  if (myIdentityHex != null && myIdentityHex.toLowerCase() == invite.identityHex) return InviteAction.self;
  if (myServerHost.toLowerCase() != invite.serverHost) return InviteAction.otherServer;
  return InviteAction.addContact;
}

/// Mounted once at the app root: hands every link (and the one that
/// started the app) to [onLink]. Renders nothing.
class InviteLinkListener extends ConsumerStatefulWidget {
  const InviteLinkListener({super.key, required this.child, required this.onLink});
  final Widget child;
  final void Function(String link) onLink;

  @override
  ConsumerState<InviteLinkListener> createState() => _InviteLinkListenerState();
}

class _InviteLinkListenerState extends ConsumerState<InviteLinkListener> {
  StreamSubscription<String>? _sub;
  String? _last;
  DateTime _lastAt = DateTime(0);

  void _deliver(String link) {
    // The same tap can arrive twice (cold start + the live event).
    final now = DateTime.now();
    if (link == _last && now.difference(_lastAt) < const Duration(seconds: 5)) return;
    _last = link;
    _lastAt = now;
    widget.onLink(link);
  }

  @override
  void initState() {
    super.initState();
    final platform = ref.read(inviteLinkPlatformProvider);
    _sub = platform.links.listen(_deliver);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final first = await platform.takeInitial();
      if (first != null && mounted) _deliver(first);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
