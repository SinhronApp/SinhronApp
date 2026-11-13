// ADR-056 — Notification Service Extension: names and text in message
// notifications without the server or Apple seeing them.
//
// The server's push says only "New message" and carries the sender's
// preview sealed to this person's delivery key (`p`, base64). Here, on the
// phone: open it with the keys the app left in the shared Keychain, check
// the sender's signature, look the chat and sender up in the app's names
// and write "<chat>" / "<sender>: <text>" — or less, as Settings →
// Notifications show says. Anything missing (old iOS, no keys yet, an
// unknown chat, a stale preview) leaves the server's "New message".
//
// Pure Swift + CryptoKit (`ios/Shared/PushShared.swift`): no Rust, no
// database — far below the extension's ~24 MB, and nothing to lock against
// the app holding its database open.
//
// Blocked here: iOS lets an extension drop a notification only with the
// `com.apple.developer.usernotifications.filtering` entitlement, which
// Apple grants on request. Until then (`SinhronCanFilterNotifications` =
// false) it becomes a silent "New message" without the badge change, and
// the app clears it from the notification list when it next starts.

import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var fallback: UNNotificationContent?

  /// Set to true in Info.plist once Apple granted the filtering entitlement
  /// (and it is added to NotificationService.entitlements).
  private static let canFilter = (Bundle.main.object(forInfoDictionaryKey: "SinhronCanFilterNotifications") as? Bool) ?? false

  /// Thread of silent "New message"s from blocked people (the app removes them).
  static let blockedThread = "sinhron-blocked"

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    fallback = request.content
    guard let content = request.content.mutableCopy() as? UNMutableNotificationContent,
      let b64 = request.content.userInfo["p"] as? String,
      let sealed = Data(base64Encoded: b64)
    else {
      finish(request.content)
      return
    }
    let secrets = SharedKeychain.read(SharedKeychain.keys)
      .flatMap { try? JSONDecoder().decode([String].self, from: $0) }?
      .compactMap { Data(hex: $0) } ?? []
    let opened = PushPreview.open(sealed, secrets: secrets)
    guard let r = NotificationRender.render(opened, context: PushContext.load(), now: Date()) else {
      finish(request.content)
      return
    }
    var info = content.userInfo
    info.removeValue(forKey: "p")
    if r.blocked {
      if Self.canFilter {
        finish(UNNotificationContent())
        return
      }
      content.badge = nil
      content.threadIdentifier = Self.blockedThread
    } else {
      info["chatId"] = r.chatId
      if !r.chatId.isEmpty { content.threadIdentifier = r.chatId }
      // ADR-066 — "Reply" (registered by the app, AppDelegate.swift).
      if r.canReply { content.categoryIdentifier = NotificationRender.replyCategory }
    }
    content.userInfo = info
    content.title = r.title
    content.body = r.body
    if r.quiet || r.blocked {
      content.sound = nil
      if #available(iOS 15.0, *) { content.interruptionLevel = .passive }
    }
    finish(content)
  }

  /// Out of time: what the server sent.
  override func serviceExtensionTimeWillExpire() {
    if let f = fallback { finish(f) }
  }

  private func finish(_ c: UNNotificationContent) {
    contentHandler?(c)
    contentHandler = nil
  }
}
