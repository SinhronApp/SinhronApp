// CE1 — CallKit ↔ Flutter platform channel; overnight item 9 — PushKit.
//
// Bridges the Flutter-side `activeCallProvider` to iOS native CallKit
// via a `FlutterMethodChannel`. CallKit produces the native incoming-
// call UI (the "Apple ringer" with Accept/Decline) and the system call
// history entry.
//
// Calls while the app is closed (PushKit): `AppDelegate` gets a VoIP push
// (call id + audio/video, no caller, no group — ADR-056: plus `h`, an HMAC
// of call + chat under this phone's key) and calls `reportFromPush` at
// once: iOS requires every VoIP push to show a call. The hint names the
// chat from the app's list in the shared Keychain (`CallHint.lookup`), so
// the lock screen says who is calling before the app connects; a personal
// chat with someone blocked is ended at once. ADR-090 (calls:5) — the name
// only when `s`, the caller's own signature on the invite, checks out
// (`CallProof`): the server knows the hint key and could ring "Mom" itself.
// The app then starts, connects and receives the invite again from the
// server; Dart's `reportIncoming` for the same call "claims" it (and sets
// the chat's name). An Accept / Decline tapped before that is kept and
// delivered on claim. A push call Dart never claims (the call ended, or
// Dart screened it out — `dismiss`) is ended after `unclaimedTimeout`.
//
// One provider per process (`shared`), made at launch so a push that
// starts the app can report before Flutter is up; the channel attaches
// once the engine exists.
//
// Method channel name: `dev.sinhron/callkit`.
//
// Methods (Dart → Native):
//   - `startCall(call_id, peer_name, video)`: outgoing call begins.
//   - `reportIncoming(call_id, peer_name, video)`: incoming call arrives
//     (or claims the one a push already reported). Returns true: CallKit
//     shows it — the app opens no ringing screen of its own (one UI, not
//     both — owner, 2026-10-18); false on error / the Simulator.
//   - `answerCall(call_id)`: answered in the app's own call screen — tell
//     CallKit (`CXAnswerCallAction`), or iOS keeps its "Accept" banner up
//     over the live call (owner, 2026-10-16). Not echoed back as onAccept.
//   - `endCall(call_id)`: terminate. Reports `CXEndCallAction`.
//   - `dismiss(call_id)`: a push-reported call Dart won't ring (screened
//     out): end it quietly.
//
// Events (Native → Dart):
//   - `onAccept(call_id)`, `onEnd(call_id)`, `onMute(call_id, muted)`.
//
// Audio (owner, 2026-10-18: "calls with mum's iPhone often have no sound,
// or it comes only after a long time"): a CallKit call's audio session is
// activated by CallKit (`didActivate`), not by the app. WebRTC used to
// start its audio unit by itself — before CallKit's activation, which then
// interrupted it — so the mic recorded silence or nothing played. Now
// WebRTC waits (`RTCAudioSession.useManualAudio`) and starts on CallKit's
// `didActivate` (`CallAudio`), with a 2 s fallback so audio never stays off.

import AVFoundation
import AVKit
import CallKit
import Flutter
import UIKit
import VideoToolbox
import WebRTC

final class CallKitBridge: NSObject, CXProviderDelegate {
    static let shared = CallKitBridge()

    /// Method channel for invocation + event push back to Dart; nil until
    /// the Flutter engine is up.
    private var channel: FlutterMethodChannel?

    /// CallKit's per-process provider — owns the UI surface.
    private let provider: CXProvider

    /// Controller for sending action requests (start, end, mute).
    private let callController = CXCallController()

    /// Map our `call_id` (UUIDv7 string) to CallKit's internal UUID.
    private var idMap: [String: UUID] = [:]
    private var reverseMap: [UUID: String] = [:]

    /// Reported from a VoIP push, not yet claimed by Dart.
    private var unclaimed: Set<String> = []
    /// Accept / Decline tapped on a push call before Dart claimed it.
    private var pendingAnswer: Set<String> = []
    private var pendingEnd: Set<String> = []
    /// Answered in the app (`answerCall`): CallKit's answer action for it
    /// is ours — don't send it back to Dart as a second accept.
    private var answeredByApp: Set<String> = []

    /// How long a push call waits for Dart (app start + connect + invite).
    private let unclaimedTimeout: TimeInterval = 45

    private override init() {
        // Provider configuration — what CallKit shows in the system UI.
        let config = CXProviderConfiguration(localizedName: "Sinhron")
        config.supportsVideo = true
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic] // a chat, not a phone number
        // storage-devices:9 (owner 2026-11-04, «исправь всё» — reverses status
        // 109): not in Phone → Recents, which goes to iCloud backups and the
        // Apple ID's other devices, past App Lock.
        config.includesCallsInRecents = false
        self.provider = CXProvider(configuration: config)
        super.init()
        self.provider.setDelegate(self, queue: nil)
    }

    /// The Flutter engine is up: Dart can talk now.
    func attach(messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "dev.sinhron/callkit", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call: call, result: result)
        }
        self.channel = channel
    }

    // MARK: - PushKit (overnight item 9)

    /// A VoIP push: show the call now. [completion] must run after the
    /// report (PushKit's contract).
    func reportFromPush(callId: String, video: Bool, hint: String?, proof: String?, completion: @escaping () -> Void) {
        if idMap[callId] != nil {
            completion() // already showing (Dart got the invite first)
            return
        }
        let uuid = uuidFor(callId: callId)
        unclaimed.insert(callId)
        let (name, blocked) = CallHint.lookup(hint: hint, callId: callId, video: video, proof: proof)
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = name
        update.hasVideo = video
        update.supportsHolding = false
        update.supportsGrouping = false
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if error != nil {
                self?.forget(callId: callId, uuid: uuid)
            } else if !blocked {
                CallAudio.callKitTakesAudio()
                // Status 223 — Dart connects now: the invite arrives, and so
                // does "answered on another device" (it rang on 45 s).
                self?.channel?.invokeMethod("onPushCall", arguments: ["call_id": callId])
            }
            if error == nil, blocked, let self {
                // iOS insists the call is shown; it ends right away instead
                // of ringing until the app connects and screens it.
                self.provider.reportCall(with: uuid, endedAt: nil, reason: .declinedElsewhere)
                self.forget(callId: callId, uuid: uuid)
            }
            completion()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + unclaimedTimeout) { [weak self] in
            guard let self, self.unclaimed.contains(callId) else { return }
            self.provider.reportCall(with: uuid, endedAt: nil, reason: .unanswered)
            self.forget(callId: callId, uuid: uuid)
        }
    }

    // MARK: - Dart → Native

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        #if targetEnvironment(simulator)
        // The Simulator has no telephony: CallKit ends every reported call
        // about a second later (CXEndCallAction → onEnd → hang-up), so calls
        // to and from a simulator dropped at once (2026-10-15). The in-app
        // call screen is the whole UX there; report success, do nothing —
        // and an incoming call is not shown by the system (false), so the
        // app rings it itself.
        result(call.method == "reportIncoming" ? false : true)
        return
        #endif
        switch call.method {
        case "startCall":
            handleStartCall(call: call, result: result)
        case "reportIncoming":
            handleReportIncoming(call: call, result: result)
        case "answerCall":
            handleAnswerCall(call: call, result: result)
        case "endCall":
            handleEndCall(call: call, result: result)
        case "dismiss":
            handleDismiss(call: call, result: result)
        case "endedElsewhere":
            handleEndedElsewhere(call: call, result: result)
        case "outgoingConnected":
            handleOutgoingConnected(call: call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func handleStartCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let callIdStr = args["call_id"] as? String,
              let peerName = args["peer_name"] as? String else {
            result(FlutterError(code: "bad_args",
                                message: "startCall requires call_id + peer_name",
                                details: nil))
            return
        }
        let video = (args["video"] as? Bool) ?? false
        let uuid = uuidFor(callId: callIdStr)

        let handle = CXHandle(type: .generic, value: peerName)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = video

        let transaction = CXTransaction(action: action)
        CallAudio.callKitTakesAudio()
        callController.request(transaction) { error in
            if let error = error {
                CallAudio.released()
                result(FlutterError(code: "start_failed",
                                    message: error.localizedDescription,
                                    details: nil))
            } else {
                result(true)
            }
        }
    }

    private func handleReportIncoming(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let callIdStr = args["call_id"] as? String,
              let peerName = args["peer_name"] as? String else {
            result(FlutterError(code: "bad_args",
                                message: "reportIncoming requires call_id + peer_name",
                                details: nil))
            return
        }
        let video = (args["video"] as? Bool) ?? false

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: peerName)
        update.localizedCallerName = peerName
        update.hasVideo = video
        update.supportsHolding = false
        update.supportsGrouping = false

        // A push already showed this call: claim it, name it, and hand
        // over what was tapped meanwhile.
        if unclaimed.remove(callIdStr) != nil, let uuid = idMap[callIdStr] {
            result(true)
            if pendingEnd.remove(callIdStr) != nil {
                // Already declined on the lock screen (that call is over in
                // CallKit): Dart declines it with the server.
                cleanup(uuid: uuid)
                channel?.invokeMethod("onEnd", arguments: ["call_id": callIdStr])
                return
            }
            provider.reportCall(with: uuid, updated: update)
            if pendingAnswer.remove(callIdStr) != nil {
                channel?.invokeMethod("onAccept", arguments: ["call_id": callIdStr])
            }
            return
        }

        let uuid = uuidFor(callId: callIdStr)
        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error = error {
                result(FlutterError(code: "incoming_failed",
                                    message: error.localizedDescription,
                                    details: nil))
            } else {
                CallAudio.callKitTakesAudio()
                result(true)
            }
        }
    }

    /// Answered in the app's call screen: answer the CallKit call too, so
    /// its banner goes and iOS treats the call as live (audio session,
    /// green indicator) — the same state as the system "Accept".
    private func handleAnswerCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let callIdStr = args["call_id"] as? String,
              let uuid = idMap[callIdStr] else {
            result(true) // CallKit doesn't know this call — nothing to close
            return
        }
        answeredByApp.insert(callIdStr)
        let transaction = CXTransaction(action: CXAnswerCallAction(call: uuid))
        callController.request(transaction) { error in
            if let error = error {
                self.answeredByApp.remove(callIdStr)
                result(FlutterError(code: "answer_failed",
                                    message: error.localizedDescription,
                                    details: nil))
            } else {
                result(true)
            }
        }
    }

    private func handleEndCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let callIdStr = args["call_id"] as? String,
              let uuid = idMap[callIdStr] else {
            // No active CallKit session — return success silently.
            result(true)
            return
        }
        let action = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: action)
        callController.request(transaction) { error in
            if let error = error {
                result(FlutterError(code: "end_failed",
                                    message: error.localizedDescription,
                                    details: nil))
            } else {
                result(true)
            }
            self.cleanup(uuid: uuid)
        }
    }

    /// Dart won't ring this push call (blocked, a request, calls off).
    private func handleDismiss(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let callIdStr = args["call_id"] as? String,
              unclaimed.contains(callIdStr),
              let uuid = idMap[callIdStr] else {
            result(true)
            return
        }
        provider.reportCall(with: uuid, endedAt: nil, reason: .declinedElsewhere)
        forget(callId: callIdStr, uuid: uuid)
        result(true)
    }

    /// Status 212 — my outgoing call was answered: the system's call (status
    /// bar timer) counts from now, not from when it rang.
    private func handleOutgoingConnected(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let callIdStr = args["call_id"] as? String,
              let uuid = idMap[callIdStr] else {
            result(true)
            return
        }
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
        result(true)
    }

    /// 2026-10-26 — answered or declined on another of my devices: the
    /// system shows it as such (not a missed call).
    private func handleEndedElsewhere(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let callIdStr = args["call_id"] as? String,
              let uuid = idMap[callIdStr] else {
            result(true)
            return
        }
        let answered = args["answered"] as? Bool ?? true
        provider.reportCall(with: uuid, endedAt: nil, reason: answered ? .answeredElsewhere : .declinedElsewhere)
        forget(callId: callIdStr, uuid: uuid)
        result(true)
    }

    // MARK: - CXProviderDelegate (Native → Dart events)

    func providerDidReset(_ provider: CXProvider) {
        CallAudio.released()
        idMap.removeAll()
        reverseMap.removeAll()
        unclaimed.removeAll()
        pendingAnswer.removeAll()
        pendingEnd.removeAll()
        answeredByApp.removeAll()
    }

    /// CallKit activated the call's audio session: now WebRTC may start.
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        DiagNative.log("callkit: audio session activated")
        CallAudio.activated(audioSession)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        DiagNative.log("callkit: audio session deactivated")
        CallAudio.deactivated(audioSession)
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        DiagNative.log("callkit: answered")
        CallAudio.expectActivation()
        if let callIdStr = reverseMap[action.callUUID] {
            if answeredByApp.remove(callIdStr) != nil {
                // Our own `answerCall`: Dart is already accepting.
            } else if unclaimed.contains(callIdStr) {
                pendingAnswer.insert(callIdStr) // Dart gets it on claim
            } else {
                channel?.invokeMethod("onAccept", arguments: ["call_id": callIdStr])
            }
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if let callIdStr = reverseMap[action.callUUID] {
            if unclaimed.contains(callIdStr) {
                // Declined from the lock screen before the app had the
                // invite: Dart declines it on claim.
                pendingEnd.insert(callIdStr)
                action.fulfill()
                return
            }
            channel?.invokeMethod("onEnd", arguments: ["call_id": callIdStr])
        }
        cleanup(uuid: action.callUUID)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        if let callIdStr = reverseMap[action.callUUID] {
            channel?.invokeMethod("onMute", arguments: [
                "call_id": callIdStr,
                "muted": action.isMuted,
            ])
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        CallAudio.expectActivation()
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        action.fulfill()
    }

    // MARK: - Helpers

    private func uuidFor(callId: String) -> UUID {
        if let existing = idMap[callId] {
            return existing
        }
        // Our CallId IS a UUIDv7, so this should parse. If not, a fresh one.
        let uuid = UUID(uuidString: callId) ?? UUID()
        idMap[callId] = uuid
        reverseMap[uuid] = callId
        return uuid
    }

    private func forget(callId: String, uuid: UUID) {
        unclaimed.remove(callId)
        pendingAnswer.remove(callId)
        pendingEnd.remove(callId)
        cleanup(uuid: uuid)
    }

    private func cleanup(uuid: UUID) {
        if let callIdStr = reverseMap[uuid] {
            idMap.removeValue(forKey: callIdStr)
        }
        reverseMap.removeValue(forKey: uuid)
        // No CallKit call left: WebRTC handles its audio by itself again.
        if idMap.isEmpty { CallAudio.released() }
    }
}

// MARK: - Native journal for "Report a problem"

/// What the call / push code did natively — the part the Dart journal
/// (lib/core/diag_log.dart) can't see (a call reported before Flutter
/// started, the audio session). One line per event, "ISO-time text", in
/// Application Support/diag-native.log; cut to its newer half past 128 KB.
/// Never message text, names or keys.
enum DiagNative {
    private static let queue = DispatchQueue(label: "dev.sinhron.diag")
    private static let maxBytes = 128 * 1024

    static func log(_ text: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [ios] \(text)\n"
        queue.async {
            guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("diag-native.log")
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                h.closeFile()
            } else {
                try? data.write(to: url)
            }
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes,
               let all = try? String(contentsOf: url, encoding: .utf8) {
                let lines = all.split(separator: "\n")
                let keep = lines.suffix(lines.count / 2).joined(separator: "\n") + "\n"
                try? keep.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

// MARK: - Call audio under CallKit (ADR-063)

/// WebRTC's audio unit starts only once CallKit has activated the audio
/// session (Apple's rule for CallKit apps): `useManualAudio` while CallKit
/// holds a call, `isAudioEnabled` on `didActivate`. A 2 s fallback after an
/// answer / start turns audio on anyway, should the activation not come.
enum CallAudio {
    private static var fallback: DispatchWorkItem?

    /// CallKit has (or is about to have) a call: WebRTC waits for it.
    static func callKitTakesAudio() {
        let rtc = RTCAudioSession.sharedInstance()
        if rtc.useManualAudio { return } // already waiting / running under CallKit
        rtc.useManualAudio = true
        rtc.isAudioEnabled = false
    }

    /// Answered / started: the activation should follow within moments.
    static func expectActivation() {
        fallback?.cancel()
        let item = DispatchWorkItem {
            let rtc = RTCAudioSession.sharedInstance()
            if rtc.useManualAudio && (!rtc.isAudioEnabled || !rtc.isActive) {
                // Turning WebRTC's audio on alone left the session
                // inactive — mic sent nothing (owner, 2026-10-20, iPad).
                NSLog("[callkit] no audio activation from CallKit in 2 s — activating it ourselves")
                DiagNative.log("callkit: no audio activation in 2 s — activating it ourselves")
                _ = recover()
            }
        }
        fallback = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    static func activated(_ session: AVAudioSession) {
        fallback?.cancel()
        let rtc = RTCAudioSession.sharedInstance()
        rtc.audioSessionDidActivate(session)
        rtc.isAudioEnabled = true
    }

    static func deactivated(_ session: AVAudioSession) {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.audioSessionDidDeactivate(session)
        if rtc.useManualAudio { rtc.isAudioEnabled = false }
    }

    /// A live call whose audio isn't running (no activation from CallKit, an
    /// interruption that never ended): activate the session ourselves, tell
    /// WebRTC, and restart its audio unit. True if the session is active.
    @discardableResult
    static func recover() -> Bool {
        let s = AVAudioSession.sharedInstance()
        let rtc = RTCAudioSession.sharedInstance()
        do {
            if s.category != .playAndRecord {
                try s.setCategory(.playAndRecord, mode: s.mode == .videoChat ? .videoChat : .voiceChat, options: [.allowBluetooth])
            }
            try s.setActive(true)
        } catch {
            NSLog("[callkit] recover: couldn't activate the audio session: \(error)")
        }
        rtc.audioSessionDidActivate(s)
        // Off and on: WebRTC starts its audio unit afresh.
        rtc.isAudioEnabled = false
        rtc.isAudioEnabled = true
        NSLog("[callkit] recover: audio session active=\(rtc.isActive)")
        DiagNative.log("callkit: recover — audio session active=\(rtc.isActive)")
        return rtc.isActive
    }

    /// An interruption (Siri, an alarm, another app's sound) is on now — for
    /// the diagnostics (this WebRTC build's RTCAudioSession has no
    /// `isInterrupted`; 2026-10-22, the iOS 0.8.0 build failed on it).
    private(set) static var interrupted = false

    /// An interruption (Siri, an alarm, another app's sound) ended while a
    /// CallKit call holds the audio: CallKit doesn't re-activate it for us.
    static func observeInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            interrupted = type == .began
            guard type == .ended else { return }
            let rtc = RTCAudioSession.sharedInstance()
            if rtc.useManualAudio && rtc.isAudioEnabled { recover() }
        }
    }

    /// No CallKit call any more: back to WebRTC's own handling.
    static func released() {
        fallback?.cancel()
        let rtc = RTCAudioSession.sharedInstance()
        rtc.isAudioEnabled = true
        rtc.useManualAudio = false
    }

    /// The audio session as the diagnostics panel shows it.
    static func state() -> [String: Any] {
        let s = AVAudioSession.sharedInstance()
        let rtc = RTCAudioSession.sharedInstance()
        return [
            "category": s.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: ""),
            "mode": s.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: ""),
            "active": rtc.isActive,
            "manual": rtc.useManualAudio,
            "enabled": rtc.isAudioEnabled,
            "interrupted": interrupted,
            "input": s.isInputAvailable,
            "out": s.currentRoute.outputs.first?.portType.rawValue ?? "",
            "in": s.currentRoute.inputs.first?.portType.rawValue ?? "",
        ]
    }
}

// Where the call's sound goes (owner, 2026-10-16: headphones, speakers and
// mics must switch in real time). Dart side: lib/features/calls/call_audio.dart.
//
// Method channel `dev.sinhron/audio`:
//   - `currentRoute` → {kind, name, external}: the output now (`speaker`,
//     `earpiece`, `wired`, `bluetooth`, `car`, `airplay`, `usb`, `other`),
//     its name ("AirPods Pro"), and whether a headset / Bluetooth is around
//     (then the call's speaker button opens the route menu).
//   - `showRoutePicker`: the system's route menu — the same one as in the
//     Phone app (AVRoutePickerView; its button is tapped for the user).
// Native → Dart: `routeChanged` on every AVAudioSession route change.
final class AudioRouteBridge: NSObject {
    static let shared = AudioRouteBridge()
    private var channel: FlutterMethodChannel?
    private var mediaChannel: FlutterMethodChannel?
    private var picker: AVRoutePickerView?

    func attach(messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: "dev.sinhron/audio", binaryMessenger: messenger)
        CallAudio.observeInterruptions()
        ch.setMethodCallHandler { [weak self] call, result in
            switch call.method {
            case "currentRoute": result(AudioRouteBridge.route())
            case "showRoutePicker": result(self?.showPicker() ?? false)
            // The mic mode (iOS 15+): Standard / Voice Isolation / Wide
            // Spectrum — the person picks it in the system's menu; an app
            // can only open that menu and read the result.
            case "micMode": result(AudioRouteBridge.micMode())
            // Diagnostics (ADR-063): category / mode / active, WebRTC's audio
            // switch and the route — which side of a silent call is silent.
            case "audioState": result(CallAudio.state())
            // A live call's mic sends nothing (lib/features/calls/silent_mic_watch.dart).
            case "recoverAudio": result(CallAudio.recover())
            case "showMicModes":
                if #available(iOS 15.0, *) {
                    AVCaptureDevice.showSystemUserInterface(.microphoneModes)
                    result(true)
                } else {
                    result(false)
                }
            default: result(FlutterMethodNotImplemented)
            }
        }
        channel = ch
        // ADR-045 — which video codecs this iPhone encodes in hardware;
        // ADR-046 — how hot it is.
        let media = FlutterMethodChannel(name: "dev.sinhron/media", binaryMessenger: messenger)
        media.setMethodCallHandler { call, result in
            switch call.method {
            case "hardwareVideoEncoders": result(AudioRouteBridge.hardwareVideoEncoders())
            // ADR-046 — 0 nominal, 1 fair, 2 serious, 3 critical: the call
            // steps its best picture down from 1080p as the phone heats up.
            case "thermalState": result(ProcessInfo.processInfo.thermalState.rawValue)
            // ADR-048 — a round video message: the centre square, side px.
            case "squareVideo":
                let args = call.arguments as? [String: Any]
                guard let path = args?["path"] as? String else { return result(nil) }
                VideoNoteExport.square(path, side: args?["side"] as? Int ?? 480) { result($0) }
            default: result(FlutterMethodNotImplemented)
            }
        }
        mediaChannel = media
        NotificationCenter.default.addObserver(
            self, selector: #selector(routeChanged(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil)
    }

    @objc private func routeChanged(_ note: Notification) {
        DispatchQueue.main.async { self.channel?.invokeMethod("routeChanged", arguments: nil) }
    }

    private static func kind(_ port: AVAudioSession.Port) -> String {
        switch port {
        case .builtInSpeaker: return "speaker"
        case .builtInReceiver: return "earpiece"
        case .headphones, .headsetMic: return "wired"
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: return "bluetooth"
        case .carAudio: return "car"
        case .airPlay: return "airplay"
        case .usbAudio: return "usb"
        default: return "other"
        }
    }

    static func route() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        let out = session.currentRoute.outputs.first
        let k = out.map { kind($0.portType) } ?? "earpiece"
        // A Bluetooth / wired headset shows up as an input even while the
        // sound plays on the speaker.
        let otherInput = (session.availableInputs ?? []).contains { $0.portType != .builtInMic }
        let external = !(k == "speaker" || k == "earpiece") || otherInput
        return ["kind": k, "name": out?.portName ?? "", "external": external]
    }

    /// H.264 always; H.265 when VideoToolbox can open a hardware HEVC
    /// encoder (A10 and newer) — the FaceTime codec, no heat or battery cost.
    /// The Simulator has none: H.264 only.
    static func hardwareVideoEncoders() -> [String] {
        var out = ["h264"]
        var session: VTCompressionSession?
        // iOS has no software HEVC encoder, so a session that opens is the
        // hardware one; 17.4+ can also say so explicitly.
        var spec: CFDictionary?
        if #available(iOS 17.4, *) {
            spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue] as CFDictionary
        }
        let status = VTCompressionSessionCreate(
            allocator: nil, width: 1280, height: 720, codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        if status == noErr, let s = session {
            VTCompressionSessionInvalidate(s)
            out.append("h265")
        }
        return out
    }

    static func micMode() -> String? {
        guard #available(iOS 15.0, *) else { return nil }
        switch AVCaptureDevice.activeMicrophoneMode {
        case .standard: return "standard"
        case .voiceIsolation: return "voiceIsolation"
        case .wideSpectrum: return "wideSpectrum"
        @unknown default: return "standard"
        }
    }

    private func showPicker() -> Bool {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        guard let window else { return false }
        let p = picker ?? AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        p.alpha = 0.01
        p.prioritizesVideoDevices = false
        if p.superview !== window { window.addSubview(p) }
        picker = p
        guard let button = p.subviews.compactMap({ $0 as? UIButton }).first else { return false }
        button.sendActions(for: .touchUpInside)
        return true
    }
}

// MARK: - The camera in the background (ADR-063)

/// Owner, 2026-10-18: "the camera must not close when the call is minimised
/// — on both platforms". iOS stops every app's camera in the background
/// (`AVCaptureSession` is interrupted: videoDeviceNotAvailableInBackground)
/// unless the session allows multitasking camera access — and iOS offers
/// that only to apps Apple has granted the
/// `com.apple.developer.avfoundation.multitasking-camera-access` entitlement
/// (video-calling apps, by request — docs/open-items.md). WebRTC owns the
/// capture session, so we switch it on as each session starts running; on
/// a phone without the entitlement `isMultitaskingCameraAccessSupported`
/// is false and nothing changes (the camera pauses in the background and
/// resumes on return, as before).
enum CameraMultitasking {
    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.didStartRunningNotification, object: nil, queue: nil
        ) { note in
            guard let session = note.object as? AVCaptureSession else { return }
            allow(session)
        }
    }

    static func allow(_ session: AVCaptureSession) {
        guard #available(iOS 16.0, *) else { return }
        guard session.isMultitaskingCameraAccessSupported, !session.isMultitaskingCameraAccessEnabled else { return }
        session.beginConfiguration()
        session.isMultitaskingCameraAccessEnabled = true
        session.commitConfiguration()
    }
}

// MARK: - Round video messages (ADR-048)

/// The centre square of a camera clip, upright, scaled to `side` px, black
/// outside the inscribed circle, re-encoded by the hardware H.264 encoder
/// (+ AAC) into an .mp4 in the temp dir. nil on any failure — the app then
/// tries once more and otherwise sends nothing (never the uncropped clip).
/// The caller deletes both files once the clip is in memory.
enum VideoNoteExport {
    static func square(_ input: String, side: Int, done: @escaping (String?) -> Void) {
        let asset = AVURLAsset(url: URL(fileURLWithPath: input))
        guard let track = asset.tracks(withMediaType: .video).first, side > 0 else { return done(nil) }
        // The frame as shown (preferredTransform turns the sensor's
        // landscape picture upright).
        let shown = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
        let w = abs(shown.width), h = abs(shown.height)
        let crop = min(w, h)
        guard crop > 0 else { return done(nil) }
        let scale = CGFloat(side) / crop
        let transform = track.preferredTransform
            .concatenating(CGAffineTransform(translationX: -shown.minX - (w - crop) / 2, y: -shown.minY - (h - crop) / 2))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: side, height: side)
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.instructions = [instruction]
        // Black outside the circle: the file holds only what the recorder
        // saw in the round preview, not the square's corners (owner,
        // 2026-10-19 — privacy).
        let frame = CGRect(x: 0, y: 0, width: side, height: side)
        let videoLayer = CALayer()
        videoLayer.frame = frame
        let parent = CALayer()
        parent.frame = frame
        parent.backgroundColor = CGColor(gray: 0, alpha: 1)
        parent.addSublayer(videoLayer)
        parent.addSublayer(cornerMask(frame))
        composition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parent)
        // Medium quality ≈ 0.7–1 Mbit/s for a 480 px square: about 6 MB a minute.
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
            return done(nil)
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("vnote-\(UUID().uuidString).mp4")
        export.outputURL = out
        export.outputFileType = .mp4
        export.videoComposition = composition
        export.shouldOptimizeForNetworkUse = true
        export.exportAsynchronously {
            let ok = export.status == .completed
            if !ok { try? FileManager.default.removeItem(at: out) }
            DispatchQueue.main.async { done(ok ? out.path : nil) }
        }
    }

    /// Opaque black over the square except its inscribed circle.
    static func cornerMask(_ frame: CGRect) -> CAShapeLayer {
        let path = CGMutablePath()
        path.addRect(frame)
        path.addEllipse(in: frame)
        let mask = CAShapeLayer()
        mask.frame = frame
        mask.path = path
        mask.fillRule = .evenOdd
        mask.fillColor = CGColor(gray: 0, alpha: 1)
        return mask
    }
}
