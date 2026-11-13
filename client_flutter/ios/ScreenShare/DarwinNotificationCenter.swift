//
//  DarwinNotificationCenter.swift
//  Broadcast Extension — Sinhron ScreenShare (ADR-061), from the LiveKit
//  Flutter example (Apache-2.0, originally 8x8 / Jitsi). Added: observing
//  the app's "stop" request (livekit_client posts iOS_BroadcastRequestStop).
//

import Foundation

enum DarwinNotification: String {
    case broadcastStarted = "iOS_BroadcastStarted"
    case broadcastStopped = "iOS_BroadcastStopped"
    case broadcastRequestStop = "iOS_BroadcastRequestStop"
}

final class DarwinNotificationCenter {

    static let shared = DarwinNotificationCenter()

    private let notificationCenter: CFNotificationCenter
    private var handlers: [String: () -> Void] = [:]

    init() {
        notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
    }

    func postNotification(_ name: DarwinNotification) {
        CFNotificationCenterPostNotification(notificationCenter, CFNotificationName(rawValue: name.rawValue as CFString), nil, nil, true)
    }

    /// Calls [handler] (on the main queue) whenever [name] is posted.
    func observe(_ name: DarwinNotification, handler: @escaping () -> Void) {
        handlers[name.rawValue] = handler
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(notificationCenter, observer, { _, observer, name, _, _ in
            guard let observer = observer, let name = name?.rawValue as String? else { return }
            let center = Unmanaged<DarwinNotificationCenter>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { center.handlers[name]?() }
        }, name.rawValue as CFString, nil, .deliverImmediately)
    }
}
