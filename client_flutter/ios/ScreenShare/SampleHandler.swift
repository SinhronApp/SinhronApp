//
//  SampleHandler.swift
//  Broadcast Extension — Sinhron ScreenShare (ADR-061), from the LiveKit
//  Flutter example (Apache-2.0, originally 8x8 / Jitsi).
//
//  The iPhone's whole screen goes to the call: ReplayKit hands this
//  extension the frames (also while Sinhron is in the background), the
//  extension passes them over a Unix socket in the App Group to the app,
//  where flutter_webrtc turns them into the LiveKit screen track (encrypted
//  with SFrame like the camera). Changed for Sinhron:
//   - the App Group comes from Info.plist (RTCAppGroupIdentifier), not code;
//   - started outside a call (Control Center), nobody listens: after 10 s
//     the broadcast ends with "Start screen sharing from a call in Sinhron";
//   - the app's "stop" request ends it too.
//

import ReplayKit
import OSLog

let broadcastLogger = OSLog(subsystem: "com.sinhron.sinhron.ScreenShare", category: "Broadcast")

private enum Constants {
    static let connectTimeout: TimeInterval = 10
    /// Sinhron's own code (not a ReplayKit one) for "ended on purpose".
    static let stoppedCode = 10001
}

class SampleHandler: RPBroadcastSampleHandler {

    private var clientConnection: SocketConnection?
    private var uploader: SampleUploader?

    var socketFilePath: String {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "RTCAppGroupIdentifier") as? String,
              let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return "" }
        return sharedContainer.appendingPathComponent("rtc_SSFD").path
    }

    override init() {
        super.init()
        if let connection = SocketConnection(filePath: socketFilePath) {
            clientConnection = connection
            setupConnection()

            uploader = SampleUploader(connection: connection)
        }
        os_log(.debug, log: broadcastLogger, "%{public}s", socketFilePath)
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        DarwinNotificationCenter.shared.postNotification(.broadcastStarted)
        DarwinNotificationCenter.shared.observe(.broadcastRequestStop) { [weak self] in
            self?.finish(message: nil)
        }
        openConnection()
    }

    override func broadcastPaused() {
        // Samples stop coming; nothing to do.
    }

    override func broadcastResumed() {
        // Samples come again.
    }

    override func broadcastFinished() {
        DarwinNotificationCenter.shared.postNotification(.broadcastStopped)
        clientConnection?.close()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case RPSampleBufferType.video:
            uploader?.send(sample: sampleBuffer)
        default:
            break
        }
    }
}

private extension SampleHandler {

    /// Russian phones get Russian (the system shows this text in its alert).
    func text(_ en: String, _ ru: String) -> String {
        Locale.preferredLanguages.first?.hasPrefix("ru") == true ? ru : en
    }

    func finish(message: String?) {
        let error = NSError(
            domain: RPRecordingErrorDomain,
            code: Constants.stoppedCode,
            userInfo: [NSLocalizedDescriptionKey: message ?? text("Screen sharing stopped", "Показ экрана остановлен")]
        )
        finishBroadcastWithError(error)
    }

    func setupConnection() {
        clientConnection?.didClose = { [weak self] error in
            os_log(.debug, log: broadcastLogger, "client connection did close \(String(describing: error))")
            if let error = error {
                self?.finishBroadcastWithError(error)
            } else {
                // The app stopped the track (Stop, hang-up): the socket closed.
                self?.finish(message: nil)
            }
        }
    }

    func openConnection() {
        let queue = DispatchQueue(label: "com.sinhron.screenshare.connectTimer")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let started = Date()
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self = self else {
                timer.cancel()
                return
            }
            if self.clientConnection?.open() == true {
                timer.cancel()
                return
            }
            if Date().timeIntervalSince(started) > Constants.connectTimeout {
                timer.cancel()
                self.finish(message: self.text(
                    "Start screen sharing from a call in Sinhron",
                    "Начните показ экрана из звонка в Sinhron"
                ))
            }
        }
        timer.resume()
    }
}
