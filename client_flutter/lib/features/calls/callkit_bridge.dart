// CE1 — Flutter side of the CallKit platform channel.
//
// Mirrors `ios/Runner/CallKitBridge.swift`. Method channel name:
// `dev.sinhron/callkit`.
//
// One ringing UI per incoming call (owner, 2026-10-18: the system banner
// and the app's screen both came up). `reportIncoming` returns whether the
// system shows the call: iPhone — CallKit, always (its banner when the app
// is open; false only on the Simulator, which has no CallKit); Android —
// the call notification while the app isn't in front. Only on false does
// the app open its own ringing screen (`_IncomingCallSentinel` in app.dart).
// Android: the app coming to the front takes over from the notification
// (`onShowIncoming`); going to the background hands it back (native side).
//
// On non-iOS platforms this entire bridge is a silent no-op.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show MethodCall, MethodChannel;

/// Inbound events from CallKit's user actions (Accept / End / Mute in
/// the system UI). Wired by ActiveCallNotifier on construction.
typedef CallKitEventCallback = void Function(CallKitEvent event);

enum CallKitEventKind {
  /// User tapped "Accept" in the CallKit incoming-call UI.
  accept,

  /// User tapped "End" / hangup in CallKit UI.
  end,

  /// User toggled mute in CallKit UI. Payload includes `muted: bool`.
  mute,

  /// Android: the app came to the front while its call notification rang —
  /// the notification is gone; the app's own screen should ring.
  showInApp,

  /// Status 223 — iOS: a call push woke the app and CallKit shows the call;
  /// the app must connect to learn the call (and that it was answered on
  /// another device — it used to ring on).
  pushCall,
}

class CallKitEvent {
  final CallKitEventKind kind;
  final String callId;
  final bool muted;

  const CallKitEvent({required this.kind, required this.callId, this.muted = false});
}

class CallKitBridge {
  static const MethodChannel _channel = MethodChannel('dev.sinhron/callkit');

  /// iOS CallKit, or on Android the call notifications and the call's
  /// foreground service (ADR-040, `android/.../Calls.kt`) — same contract.
  static bool get _native => debugNative ?? (Platform.isIOS || Platform.isAndroid);

  /// Tests: pretend to be on a phone (the channel calls go to a mock).
  @visibleForTesting
  static bool? debugNative;

  /// Tests: pretend to be on Android (the call's foreground service).
  @visibleForTesting
  static bool? debugAndroid;

  CallKitEventCallback? _onEvent;

  /// Wire an event listener. Replaces any previous registration. Only
  /// one consumer at a time (typically `ActiveCallNotifier`).
  void registerEventCallback(CallKitEventCallback callback) {
    _onEvent = callback;
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  /// CE1 — declare an outgoing call to CallKit. Triggers the native
  /// "Calling..." UI overlay. Required before `room.connect` so the
  /// system audio session is reserved properly. Android: starts the call's
  /// foreground service. No-op elsewhere.
  Future<void> startCall({required String callId, required String peerName, required bool video}) async {
    if (!_native) return;
    try {
      await _channel.invokeMethod<bool>('startCall', <String, dynamic>{
        'call_id': callId,
        'peer_name': peerName,
        'video': video,
      });
    } catch (e) {
      // ignore: avoid_print
      print('[callkit] startCall failed: $e');
    }
  }

  /// CE1 — report an incoming call to the system: CallKit's ringer (iOS),
  /// the full-screen call notification (Android, app not in front). True
  /// when the system shows it — the app then doesn't open its own ringing
  /// screen; false (no system UI here, or it failed) → the app rings.
  Future<bool> reportIncoming({required String callId, required String peerName, required bool video}) async {
    if (!_native) return false;
    try {
      return await _channel.invokeMethod<bool>('reportIncoming', <String, dynamic>{
            'call_id': callId,
            'peer_name': peerName,
            'video': video,
          }) ??
          false;
    } catch (e) {
      // ignore: avoid_print
      print('[callkit] reportIncoming failed: $e');
      return false;
    }
  }

  /// ADR-040 — the call connected: on Android keep it running in a
  /// foreground service (microphone, camera) when the app goes to background.
  /// iOS: CallKit already does — nothing to do.
  /// Called again when the camera comes on mid-call ([video] true): the
  /// service then keeps the camera running in background as well.
  Future<void> callConnected({required String callId, required String peerName, required bool video}) async {
    if (!(debugAndroid ?? Platform.isAndroid)) return;
    try {
      await _channel.invokeMethod<bool>('startCall', <String, dynamic>{
        'call_id': callId,
        'peer_name': peerName,
        'video': video,
      });
    } catch (e) {
      // ignore: avoid_print
      print('[callkit] callConnected failed: $e');
    }
  }

  /// Status 212 — iOS: my outgoing call is answered; the system's call
  /// (status bar, "Recents") counts its time from now.
  Future<void> outgoingConnected(String callId) async {
    if (!_native || (debugAndroid ?? Platform.isAndroid)) return;
    try {
      await _channel.invokeMethod<bool>('outgoingConnected', <String, dynamic>{'call_id': callId});
    } catch (e) {
      // ignore: avoid_print
      print('[callkit] outgoingConnected failed: $e');
    }
  }

  /// Answered with the app's own Accept button: tell CallKit (iOS) / drop
  /// the incoming-call notification (Android). Without it the system
  /// "Accept" banner stayed up over the live call (owner, 2026-10-16).
  /// Not for an accept that came from the system UI — that one knows.
  Future<void> answer(String callId) async {
    if (!_native) return;
    try {
      await _channel.invokeMethod<bool>('answerCall', <String, dynamic>{'call_id': callId});
    } catch (e) {
      // ignore: avoid_print
      print('[callkit] answerCall failed: $e');
    }
  }

  /// CE1 — tell CallKit the call ended (we hung up or remote did).
  /// Idempotent on the native side (no-op if CallKit doesn't have this
  /// call_id registered).
  Future<void> endCall(String callId) async {
    if (!_native) return;
    try {
      await _channel.invokeMethod<bool>('endCall', <String, dynamic>{'call_id': callId});
    } catch (e) {
      // ignore: avoid_print
      print('[callkit] endCall failed: $e');
    }
  }

  /// 2026-10-26 — answered (or declined) on another of my devices: the
  /// ringing call goes away as "answered elsewhere" — not missed.
  Future<void> endedElsewhere(String callId, {required bool answered}) async {
    if (!_native) return;
    try {
      await _channel.invokeMethod<bool>('endedElsewhere', <String, dynamic>{'call_id': callId, 'answered': answered});
    } catch (e) {
      // ignore: avoid_print
      print('[callkit] endedElsewhere failed: $e');
    }
  }

  /// Overnight item 9 — a call a VoIP push already put on screen that this
  /// app won't ring (blocked, a message request, calls off): end it quietly.
  Future<void> dismiss(String callId) async {
    if (!_native) return;
    try {
      await _channel.invokeMethod<bool>('dismiss', <String, dynamic>{'call_id': callId});
    } catch (e) {
      // ignore: avoid_print
      print('[callkit] dismiss failed: $e');
    }
  }

  // ── Native → Dart event router ────────────────────────────────────

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    final args = (call.arguments as Map?) ?? const <String, dynamic>{};
    final callId = args['call_id'] as String? ?? '';
    switch (call.method) {
      case 'onAccept':
        _onEvent?.call(CallKitEvent(kind: CallKitEventKind.accept, callId: callId));
        break;
      case 'onEnd':
        _onEvent?.call(CallKitEvent(kind: CallKitEventKind.end, callId: callId));
        break;
      case 'onShowIncoming':
        _onEvent?.call(CallKitEvent(kind: CallKitEventKind.showInApp, callId: callId));
        break;
      case 'onPushCall':
        _onEvent?.call(CallKitEvent(kind: CallKitEventKind.pushCall, callId: callId));
        break;
      case 'onMute':
        _onEvent?.call(
          CallKitEvent(kind: CallKitEventKind.mute, callId: callId, muted: (args['muted'] as bool?) ?? false),
        );
        break;
    }
    return null;
  }
}

/// Process-wide singleton — only one CallKit provider lives in the iOS
/// app process anyway, so a singleton mirrors that on the Dart side.
final callKitBridge = CallKitBridge();
