import AVFoundation
import AuthenticationServices
import Flutter
import PushKit
import ReplayKit
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, PKPushRegistryDelegate {
  // Overnight item 9 — PushKit: VoIP pushes wake the app for a call. Made
  // at launch (a push may be what started the app); calls are reported
  // to CallKit through `CallKitBridge.shared` at once.
  private var voipRegistry: PKPushRegistry?

  // UI backlog §8 item 58 — unread count on the app icon
  // (`lib/core/app_badge.dart`, channel `dev.sinhron/badge`).
  private var badgeChannel: FlutterMethodChannel?

  // ADR-021 — device key in the Keychain (`lib/core/session.dart`,
  // channel `dev.sinhron/keychain`).
  private var keychainChannel: FlutterMethodChannel?

  // Tech-debt 4.2 — QR scanner for pairing a new device
  // (`lib/core/qr_scan.dart`, channel `dev.sinhron/qrscan`).
  private var qrScanChannel: FlutterMethodChannel?

  // Audit storage-devices:8 — the 24 words to the clipboard as a secret
  // (`lib/core/screen_privacy.dart`, channel `dev.sinhron/privacy`).
  private var privacyChannel: FlutterMethodChannel?

  // Overnight item 8 — push notifications (`lib/core/push.dart`).
  private var pushBridge: PushBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    AppDelegate.protectAppFiles()
    AppDelegate.excludeFromBackup()
    // Overnight item 8 — notification taps and foreground pushes come here.
    UNUserNotificationCenter.current().delegate = self
    // ADR-066 — "Reply" on message notifications, in the app's language.
    PushBridge.registerCategories()
    let voip = PKPushRegistry(queue: .main)
    voip.delegate = self
    voip.desiredPushTypes = [.voIP]
    voipRegistry = voip
    // New database files (WAL) appear after launch: mark them before the
    // night's backup, which runs while the app is in the background.
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { _ in AppDelegate.excludeFromBackup() }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Tech-debt 2.32 — the message databases and local media copies stay
  /// out of iCloud / computer backups. They are useless elsewhere (the
  /// device key never leaves this phone's Keychain), and an old MLS state
  /// restored from a backup would be behind its groups (epochs moved on)
  /// — recovery is the 24 words and a fresh sync, never a backup. Every
  /// `sinhron*` item in Documents; the media folder is created up front so
  /// files written into it later are excluded with it.
  static func excludeFromBackup() {
    let fm = FileManager.default
    guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
    try? fm.createDirectory(at: docs.appendingPathComponent("sinhron.db.blobs"), withIntermediateDirectories: true)
    guard let items = try? fm.contentsOfDirectory(atPath: docs.path) else { return }
    for name in items where name.hasPrefix("sinhron") {
      var url = docs.appendingPathComponent(name)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try? url.setResourceValues(values)
    }
    // Audit storage-devices:15 — the "Report a problem" journal
    // (lib/core/diag_log.dart) isn't for iCloud either (from the launch
    // after it first appears).
    guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
    for name in ["diag.log", "diag-native.log"] {
      var url = support.appendingPathComponent(name)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try? url.setResourceValues(values)
    }
  }

  // MARK: - Push notifications (overnight item 8)

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    pushBridge?.didRegister(token: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    NSLog("[sinhron] APNs registration failed: \(error.localizedDescription)")
  }

  // MARK: - PushKit (overnight item 9)

  func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    guard type == .voIP else { return }
    pushBridge?.didRegisterVoip(token: pushCredentials.token)
    pendingVoipToken = pushBridge == nil ? pushCredentials.token : nil
  }

  /// iOS requires every VoIP push to show a call — report it now; the app
  /// gets the invite from the server once it connects.
  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    guard type == .voIP else { completion(); return }
    let callId = (payload.dictionaryPayload["call_id"] as? String) ?? UUID().uuidString
    DiagNative.log("pushkit: incoming call \(callId.prefix(8))")
    let video = (payload.dictionaryPayload["video"] as? Bool) ?? false
    // ADR-056 — HMAC of call + chat under this phone's key: the chat's name
    // from the app's list, at once.
    let hint = payload.dictionaryPayload["h"] as? String
    // ADR-090 — the caller's own signature on the invite: a name only then.
    let proof = payload.dictionaryPayload["s"] as? String
    CallKitBridge.shared.reportFromPush(callId: callId, video: video, hint: hint, proof: proof, completion: completion)
  }

  /// ADR-071 (amended) — a message request comes as a background push:
  /// iOS shows nothing by itself, and the app decides with its own block
  /// list (`RequestNotice`): someone blocked → nothing; else one quiet
  /// "New message request". Not delivered when the app was swiped away —
  /// the request is in the chat list on the next start.
  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    guard userInfo["r"] != nil else {
      super.application(application, didReceiveRemoteNotification: userInfo, fetchCompletionHandler: completionHandler)
      return
    }
    // On screen: the request arrives over the app's own connection.
    guard application.applicationState != .active,
      let b64 = userInfo["p"] as? String, let sealed = Data(base64Encoded: b64)
    else { return completionHandler(.noData) }
    let secrets = SharedKeychain.read(SharedKeychain.keys)
      .flatMap { try? JSONDecoder().decode([String].self, from: $0) }?
      .compactMap { Data(hex: $0) } ?? []
    guard let r = RequestNotice.decide(PushPreview.open(sealed, secrets: secrets), context: PushContext.load(), now: Date())
    else { return completionHandler(.noData) }
    let c = UNMutableNotificationContent()
    c.title = r.title
    c.body = r.body
    if !r.chatId.isEmpty {
      c.userInfo = ["chatId": r.chatId]
      c.threadIdentifier = r.chatId
    }
    if r.quiet {
      c.sound = nil
      if #available(iOS 15.0, *) { c.interruptionLevel = .passive }
    } else {
      c.sound = .default
    }
    let request = UNNotificationRequest(identifier: RequestNotice.identifier(chatId: r.chatId), content: c, trigger: nil)
    UNUserNotificationCenter.current().add(request) { _ in completionHandler(.newData) }
  }

  /// A VoIP token that came before the Flutter engine.
  private var pendingVoipToken: Data?

  /// In the app the chat list already shows new messages: no banner.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([])
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    // ADR-056 — the extension put the chat it found into the notification.
    let chatId = response.notification.request.content.userInfo["chatId"] as? String ?? ""
    // ADR-066 — "Reply": iOS woke the app in the background (it may have
    // been closed); the text goes to Dart, which sends it.
    if response.actionIdentifier == NotificationRender.replyAction,
      let input = response as? UNTextInputNotificationResponse
    {
      let text = input.userText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !chatId.isEmpty, !text.isEmpty else { return completionHandler() }
      NotificationReplies.shared.handle(chatId: chatId, text: text, completion: completionHandler)
      return
    }
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return completionHandler() }
    // A cold start: the tap comes before the Flutter engine (ADR-066).
    if let bridge = pushBridge {
      bridge.didOpenNotification(chatId: chatId)
    } else {
      PushBridge.launchOpen = chatId
    }
    completionHandler()
  }

  /// Tech-debt 2.6 — iOS Data Protection for everything the app writes.
  /// `completeUntilFirstUserAuthentication`: files are encrypted by the
  /// OS with a key that exists only after the phone has been unlocked
  /// once since boot — on top of SQLCipher. Not the stricter `.complete`
  /// on purpose: SQLite keeps its WAL open, and push handling (later)
  /// must read the DB while the screen is locked. New files inherit the
  /// class of their directory, so setting it on the folders is enough;
  /// existing files are updated too.
  static func protectAppFiles() {
    let fm = FileManager.default
    let attrs: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    for dir in [fm.urls(for: .documentDirectory, in: .userDomainMask).first,
                fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
                fm.urls(for: .cachesDirectory, in: .userDomainMask).first].compactMap({ $0 }) {
      try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
      try? fm.setAttributes(attrs, ofItemAtPath: dir.path)
      if let items = fm.enumerator(atPath: dir.path) {
        for case let item as String in items {
          try? fm.setAttributes(attrs, ofItemAtPath: dir.appendingPathComponent(item).path)
        }
      }
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // CE1 — wire CallKit ↔ Flutter platform channel.
    // `FlutterImplicitEngineBridge` doesn't expose a binaryMessenger directly;
    // pull one off a per-plugin registrar instead. Любой plugin name работает —
    // registrar даёт нам тот же messenger что и engine.binaryMessenger.
    // ADR-043 — invite links (https://<server>/join#…, sinhron://join#…).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SinhronLinks") {
      LinksBridge.shared.attach(messenger: registrar.messenger())
    }
    // ADR-060 — what the Share Extension left in the App Group.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SinhronShare") {
      ShareBridge.shared.attach(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CallKitBridge") {
      CallKitBridge.shared.attach(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SinhronAudioRoute") {
      AudioRouteBridge.shared.attach(messenger: registrar.messenger())
    }
    // ADR-073 — the chat backup in iCloud Drive.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SinhronBackup") {
      BackupBridge.shared.attach(messenger: registrar.messenger())
    }
    // ADR-063 — a call's camera keeps running in the background where iOS
    // allows it (multitasking camera access).
    CameraMultitasking.start()

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SinhronPush") {
      pushBridge = PushBridge(messenger: registrar.messenger())
      NotificationReplies.shared.bridge = pushBridge
      if let t = pendingVoipToken {
        pushBridge?.didRegisterVoip(token: t)
        pendingVoipToken = nil
      }
    }

    // Status 183 — is a VPN on? Calls then take the reserve path (TURN over
    // TLS on 443) straight away: many VPNs drop the direct media path.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NetworkInfo") {
      let channel = FlutterMethodChannel(name: "dev.sinhron/network", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        if call.method == "vpnActive" { result(VpnCheck.active()) } else { result(FlutterMethodNotImplemented) }
      }
    }

    // Status 223 — screen sharing crashed on iPad: LiveKit fires the
    // system "Screen Broadcast" picker from a view that is in no window,
    // and on iPad that sheet is a popover anchored to it (UIKit aborts).
    // Ours sits in the key window, at the bottom centre, then goes.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SinhronScreenShare") {
      let channel = FlutterMethodChannel(name: "dev.sinhron/screen_share", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "pick" else {
          result(FlutterMethodNotImplemented)
          return
        }
        let window = UIApplication.shared.connectedScenes
          .compactMap { $0 as? UIWindowScene }
          .flatMap { $0.windows }
          .first { $0.isKeyWindow }
        guard let host = window?.rootViewController?.view,
              let ext = Bundle.main.object(forInfoDictionaryKey: "RTCScreenSharingExtension") as? String else {
          result(false)
          return
        }
        let picker = RPSystemBroadcastPickerView(
          frame: CGRect(x: host.bounds.midX - 22, y: host.bounds.maxY - 120, width: 44, height: 44))
        picker.preferredExtension = ext
        picker.showsMicrophoneButton = false
        picker.alpha = 0.01
        host.addSubview(picker)
        // The picker's own button does what a tap on it would.
        let button = picker.subviews.compactMap { $0 as? UIButton }.first
        if let button = button {
          button.sendActions(for: .touchUpInside)
        } else if picker.responds(to: NSSelectorFromString("buttonPressed:")) {
          picker.perform(NSSelectorFromString("buttonPressed:"), with: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { picker.removeFromSuperview() }
        result(true)
      }
    }

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AppBadge") {
      let channel = FlutterMethodChannel(name: "dev.sinhron/badge", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "requestPermission":
          // Badge only — no alerts or sounds are asked for.
          UNUserNotificationCenter.current().requestAuthorization(options: [.badge]) { granted, _ in
            DispatchQueue.main.async { result(granted) }
          }
        case "set":
          let count = max(0, (call.arguments as? Int) ?? 0)
          if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
          } else {
            UIApplication.shared.applicationIconBadgeNumber = count
          }
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      badgeChannel = channel
    }

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SinhronQrScan") {
      let channel = FlutterMethodChannel(name: "dev.sinhron/qrscan", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "scan" else {
          result(FlutterMethodNotImplemented)
          return
        }
        AVCaptureDevice.requestAccess(for: .video) { granted in
          DispatchQueue.main.async {
            guard granted else {
              result(FlutterError(code: "denied", message: "camera access denied", details: nil))
              return
            }
            let window = UIApplication.shared.connectedScenes
              .compactMap { $0 as? UIWindowScene }
              .flatMap { $0.windows }
              .first { $0.isKeyWindow }
            guard var top = window?.rootViewController else {
              result(nil)
              return
            }
            while let presented = top.presentedViewController { top = presented }
            let scanner = QRScannerViewController()
            scanner.modalPresentationStyle = .fullScreen
            scanner.onResult = { result($0) }
            top.present(scanner, animated: true)
          }
        }
      }
      qrScanChannel = channel
    }

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SinhronPrivacy") {
      let channel = FlutterMethodChannel(name: "dev.sinhron/privacy", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        // wordsShown / hideRecents are Android's (FLAG_SECURE).
        guard call.method == "copySecret",
              let args = call.arguments as? [String: Any],
              let text = args["text"] as? String
        else {
          result(FlutterMethodNotImplemented)
          return
        }
        let seconds = args["seconds"] as? Int ?? 60
        // This phone only (no Universal Clipboard to the Mac / iPad), and
        // iOS empties it after `seconds`.
        UIPasteboard.general.setItems(
          [["public.utf8-plain-text": text]],
          options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(TimeInterval(seconds))]
        )
        result(nil)
      }
      privacyChannel = channel
    }

    // ADR-059 — the 24 words to Passwords and back (`lib/core/account_access.dart`).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SinhronPasswords") {
      PasswordsBridge.shared.attach(messenger: registrar.messenger())
    }

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SinhronKeychain") {
      let channel = FlutterMethodChannel(name: "dev.sinhron/keychain", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        let account = (call.arguments as? [String: Any])?["account"] as? String ?? "device-key"
        let base: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: "dev.sinhron",
          kSecAttrAccount as String: account,
        ]
        switch call.method {
        case "read":
          var query = base
          query[kSecReturnData as String] = true
          query[kSecMatchLimit as String] = kSecMatchLimitOne
          var out: CFTypeRef?
          let status = SecItemCopyMatching(query as CFDictionary, &out)
          if status == errSecSuccess, let data = out as? Data {
            result(String(data: data, encoding: .utf8))
          } else if status == errSecItemNotFound {
            result(nil)
          } else {
            result(FlutterError(code: "keychain", message: "read failed: \(status)", details: nil))
          }
        case "write":
          guard let value = (call.arguments as? [String: Any])?["value"] as? String,
                let data = value.data(using: .utf8) else {
            result(FlutterError(code: "keychain", message: "no value", details: nil))
            return
          }
          SecItemDelete(base as CFDictionary)
          var item = base
          item[kSecValueData as String] = data
          // This device only: never in iCloud Keychain or a backup that
          // restores onto another phone. Readable after the first unlock
          // since boot (same reasoning as the file protection above).
          item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
          let status = SecItemAdd(item as CFDictionary, nil)
          status == errSecSuccess
            ? result(nil)
            : result(FlutterError(code: "keychain", message: "write failed: \(status)", details: nil))
        case "delete":
          let status = SecItemDelete(base as CFDictionary)
          status == errSecSuccess || status == errSecItemNotFound
            ? result(nil)
            : result(FlutterError(code: "keychain", message: "delete failed: \(status)", details: nil))
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      keychainChannel = channel
    }
  }
}

/// ADR-059 / ADR-085 — the secret words in iCloud Keychain, channel
/// `dev.sinhron/passwords`:
///   - `save {account, secret}` → a synchronizable Keychain item of this app
///     (service `dev.sinhron.words`): it moves to a new iPhone with iCloud
///     Keychain, only this app reads it, and Safari never offers it on a
///     website. true = saved.
///   - `pick` → that item (the newest one, if there are several); or, saved
///     before ADR-085, the old website password — the person picks it in
///     `ASAuthorizationPasswordProvider`, it moves into the item above and
///     the website password is deleted.
/// Audit storage-devices:2: until ADR-085 the words were a Safari password
/// of `SinhronPasswordDomain` (Info.plist), so a page on that domain could
/// AutoFill-phish them. That domain is now only read from, to move them.
final class PasswordsBridge: NSObject, ASAuthorizationControllerDelegate,
  ASAuthorizationControllerPresentationContextProviding
{
  static let shared = PasswordsBridge()
  private var channel: FlutterMethodChannel?
  private var pending: FlutterResult?
  private var controller: ASAuthorizationController?

  private var domain: String? {
    Bundle.main.object(forInfoDictionaryKey: "SinhronPasswordDomain") as? String
  }

  func attach(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "dev.sinhron/passwords", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "save": self.save(call.arguments as? [String: Any], result)
      case "pick": self.pick(result)
      default: result(FlutterMethodNotImplemented)
      }
    }
    channel = ch
  }

  private static let service = "dev.sinhron.words"

  private func save(_ args: [String: Any]?, _ result: @escaping FlutterResult) {
    guard let account = args?["account"] as? String,
          let secret = args?["secret"] as? String
    else {
      result(FlutterError(code: "unavailable", message: "no words", details: nil))
      return
    }
    let status = store(account: account, secret: secret)
    // Never the secret in a message.
    status == errSecSuccess
      ? result(true)
      : result(FlutterError(code: "failed", message: "save failed: \(status)", details: nil))
  }

  /// Adds or replaces the item for [account].
  private func store(account: String, secret: String) -> OSStatus {
    let match: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: PasswordsBridge.service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: true,
    ]
    let value: [String: Any] = [
      kSecValueData as String: Data(secret.utf8),
      // Synchronizable items can't be "this device only".
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]
    let status = SecItemUpdate(match as CFDictionary, value as CFDictionary)
    guard status == errSecItemNotFound else { return status }
    return SecItemAdd(match.merging(value) { $1 } as CFDictionary, nil)
  }

  /// The words of the newest item, or nil.
  private func stored() -> String? {
    let all: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: PasswordsBridge.service,
      kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
      kSecMatchLimit as String: kSecMatchLimitAll,
      kSecReturnAttributes as String: true,
    ]
    var out: CFTypeRef?
    guard SecItemCopyMatching(all as CFDictionary, &out) == errSecSuccess,
          let items = out as? [[String: Any]],
          let newest = items.max(by: {
            ($0[kSecAttrModificationDate as String] as? Date ?? .distantPast)
              < ($1[kSecAttrModificationDate as String] as? Date ?? .distantPast)
          }),
          let account = newest[kSecAttrAccount as String] as? String
    else { return nil }
    let one: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: PasswordsBridge.service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnData as String: true,
    ]
    var data: CFTypeRef?
    guard SecItemCopyMatching(one as CFDictionary, &data) == errSecSuccess, let d = data as? Data else { return nil }
    return String(data: d, encoding: .utf8)
  }

  private func pick(_ result: @escaping FlutterResult) {
    if let words = stored() {
      result(words)
      return
    }
    // Saved before ADR-085: the website password, picked once and moved.
    guard pending == nil else {
      result(FlutterError(code: "busy", message: "already asking", details: nil))
      return
    }
    pending = result
    let c = ASAuthorizationController(authorizationRequests: [ASAuthorizationPasswordProvider().createRequest()])
    c.delegate = self
    c.presentationContextProvider = self
    controller = c
    c.performRequests()
  }

  private func finish(_ value: String?) {
    pending?(value)
    pending = nil
    controller = nil
  }

  func authorizationController(
    controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization
  ) {
    let old = authorization.credential as? ASPasswordCredential
    if let old = old, store(account: old.user, secret: old.password) == errSecSuccess,
       let domain = domain, !domain.isEmpty {
      // A nil password deletes it: Safari no longer offers the words there.
      SecAddSharedWebCredential(domain as CFString, old.user as CFString, nil) { _ in }
    }
    finish(old?.password)
  }

  func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
    finish(nil) // closed, or nothing saved
  }

  func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow } ?? ASPresentationAnchor()
  }
}

/// Tech-debt 4.2 — full-screen camera that returns the first QR code it
/// sees (or nil on ✕ / no camera). Only reads codes; nothing is stored.
final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  var onResult: ((String?) -> Void)?
  private let session = AVCaptureSession()
  private var preview: AVCaptureVideoPreviewLayer?
  private var finished = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    let output = AVCaptureMetadataOutput()
    guard let camera = AVCaptureDevice.default(for: .video),
          let input = try? AVCaptureDeviceInput(device: camera),
          session.canAddInput(input) else {
      finish(nil)
      return
    }
    session.addInput(input)
    guard session.canAddOutput(output) else {
      finish(nil)
      return
    }
    session.addOutput(output)
    output.setMetadataObjectsDelegate(self, queue: .main)
    output.metadataObjectTypes = [.qr]

    let layer = AVCaptureVideoPreviewLayer(session: session)
    layer.videoGravity = .resizeAspectFill
    view.layer.addSublayer(layer)
    preview = layer

    let close = UIButton(type: .system)
    close.setTitle("✕", for: .normal)
    close.titleLabel?.font = .systemFont(ofSize: 28, weight: .semibold)
    close.tintColor = .white
    close.accessibilityLabel = "Close"
    close.translatesAutoresizingMaskIntoConstraints = false
    close.addTarget(self, action: #selector(cancel), for: .touchUpInside)
    view.addSubview(close)
    NSLayoutConstraint.activate([
      close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      close.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      close.widthAnchor.constraint(equalToConstant: 44),
      close.heightAnchor.constraint(equalToConstant: 44),
    ])

    let session = self.session
    DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    preview?.frame = view.bounds
  }

  func metadataOutput(
    _ output: AVCaptureMetadataOutput,
    didOutput metadataObjects: [AVMetadataObject],
    from connection: AVCaptureConnection
  ) {
    guard let code = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
          let text = code.stringValue else { return }
    finish(text)
  }

  @objc private func cancel() { finish(nil) }

  private func finish(_ text: String?) {
    guard !finished else { return }
    finished = true
    let session = self.session
    DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
    // May run from viewDidLoad (no camera) before the presentation ends.
    DispatchQueue.main.async {
      if self.presentingViewController != nil {
        self.dismiss(animated: true) { self.onResult?(text) }
      } else {
        self.onResult?(text)
      }
    }
  }
}

// Overnight item 8 — push notifications ↔ Flutter (`lib/core/push.dart`).
//
// Channel `dev.sinhron/push`:
//   Dart → native
//     register()  ask for alerts / badge / sound, then register with APNs;
//                 returns whether notifications are allowed.
//     status()    "authorized" | "denied" | "notDetermined" | "provisional"
//   native → Dart
//     token({token, sandbox})  the APNs device token (hex) and whether it
//                              belongs to Apple's development environment
//     opened({chatId})         the person tapped a notification (its chat,
//                              found by the extension — ADR-056)
//     reply({id, chatId, text}) ADR-066 — a reply typed into a notification;
//                              Dart answers true once it has it
//   Dart → native (ADR-066)
//     takeReplies()            replies Dart hasn't taken yet (forgotten here)
//     replyDone({id, outcome}) "sent" | "queued" | "failed"
//     showMessage({chatId, title, body, reply})  a local notification (a
//                              missed call; a message that came while the app
//                              was connected in the background)
//
// The server's push carries no content and no chat (it can't read
// messages): "New message" and the badge; the extension makes it
// "<name>: <text>" and puts the chat in. Tapping it opens that chat.


final class PushBridge {
  private let channel: FlutterMethodChannel
  /// A tap that came before Dart was listening (cold start from a push):
  /// its chat ("" = none known).
  private var pendingOpen: String?

  /// ADR-066 — a tap that came before this bridge (no Flutter engine yet).
  static var launchOpen: String?

  init(messenger: FlutterBinaryMessenger) {
    pendingOpen = PushBridge.launchOpen
    PushBridge.launchOpen = nil
    channel = FlutterMethodChannel(name: "dev.sinhron/push", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "register":
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
          DispatchQueue.main.async {
            if granted { UIApplication.shared.registerForRemoteNotifications() }
            result(granted)
          }
        }
      case "status":
        UNUserNotificationCenter.current().getNotificationSettings { s in
          let v: String
          switch s.authorizationStatus {
          case .authorized: v = "authorized"
          case .denied: v = "denied"
          case .provisional, .ephemeral: v = "provisional"
          default: v = "notDetermined"
          }
          DispatchQueue.main.async { result(v) }
        }
      case "voipToken":
        result(self?.lastVoip)
      case "takeOpened":
        // Dart asks once it is ready: was the app opened from a push?
        let opened = self?.pendingOpen
        self?.pendingOpen = nil
        result(opened)
      // ADR-056 — what the Notification Service Extension needs, into the
      // Keychain group it shares with the app (ios/Shared/PushShared.swift).
      case "setNotificationContext":
        let json = (call.arguments as? [String: Any])?["json"] as? String ?? ""
        result(SharedKeychain.write(SharedKeychain.context, json.isEmpty ? nil : Data(json.utf8)))
        PushBridge.clearBlockedNotifications()
        PushBridge.registerCategories() // its words may have changed
      case "takeReplies":
        result(NotificationReplies.shared.take())
      case "replyDone":
        let a = call.arguments as? [String: Any]
        NotificationReplies.shared.done(id: a?["id"] as? String ?? "", outcome: a?["outcome"] as? String ?? "failed")
        result(nil)
      case "showMessage":
        let a = call.arguments as? [String: Any]
        PushBridge.post(
          chatId: a?["chatId"] as? String ?? "", title: a?["title"] as? String ?? "",
          body: a?["body"] as? String ?? "", reply: a?["reply"] as? Bool ?? false)
        result(nil)
      case "clearChat":
        // Status 223 — read here or on my other device: its notifications go.
        let chatId = (call.arguments as? [String: Any])?["chatId"] as? String ?? ""
        PushBridge.clearChatNotifications(chatId: chatId)
        result(nil)
      case "setPreviewKeys":
        let keys = (call.arguments as? [String: Any])?["keys"] as? [String] ?? []
        result(SharedKeychain.write(SharedKeychain.keys, try? JSONEncoder().encode(keys)))
      case "callHintKey":
        result(SharedKeychain.callHintKeyMakingIfNeeded()?.hex)
      case "clearNotificationData":
        for item in [SharedKeychain.context, SharedKeychain.keys, SharedKeychain.callHintKey] {
          SharedKeychain.write(item, nil)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func didRegister(token: Data) {
    let hex = token.map { String(format: "%02x", $0) }.joined()
    channel.invokeMethod("token", arguments: ["token": hex, "sandbox": PushBridge.isSandbox])
  }

  /// The PushKit token (calls), any time iOS gives a new one.
  func didRegisterVoip(token: Data) {
    let hex = token.map { String(format: "%02x", $0) }.joined()
    lastVoip = ["token": hex, "sandbox": PushBridge.isSandbox]
    channel.invokeMethod("voipToken", arguments: lastVoip)
  }

  /// Dart asks for it when it starts listening (it may have come first).
  private var lastVoip: [String: Any]?

  func didOpenNotification(chatId: String) {
    pendingOpen = chatId
    channel.invokeMethod("opened", arguments: ["chatId": chatId]) { [weak self] r in
      // ADR-066 — Dart has it (or keeps it for its `takeOpened`): not twice.
      if !(r is FlutterError), (r as? NSObject) !== FlutterMethodNotImplemented, self?.pendingOpen == chatId {
        self?.pendingOpen = nil
      }
    }
  }

  /// ADR-066 — a reply for Dart; [taken] true once Dart has it.
  func offerReply(_ reply: [String: String], taken: @escaping (Bool) -> Void) {
    channel.invokeMethod("reply", arguments: reply) { r in taken((r as? Bool) == true) }
  }

  /// ADR-066 — the category with the "Reply" text field, worded in the
  /// app's language (the words come with the extension's context).
  static func registerCategories() {
    let w = PushContext.load()?.words ?? [:]
    let reply = UNTextInputNotificationAction(
      identifier: NotificationRender.replyAction,
      title: w["reply"] ?? "Reply",
      // Only on an unlocked phone: nobody answers from the lock screen.
      options: [.authenticationRequired],
      textInputButtonTitle: w["replySend"] ?? "Send",
      textInputPlaceholder: w["replyPlaceholder"] ?? "Message")
    let message = UNNotificationCategory(
      identifier: NotificationRender.replyCategory, actions: [reply], intentIdentifiers: [], options: [])
    UNUserNotificationCenter.current().setNotificationCategories([message])
  }

  /// ADR-066 — a notification drawn by the app itself (tap → [chatId]).
  static func post(chatId: String, title: String, body: String, reply: Bool) {
    let c = UNMutableNotificationContent()
    c.title = title
    c.body = body
    c.sound = .default
    if !chatId.isEmpty {
      c.userInfo = ["chatId": chatId]
      c.threadIdentifier = chatId
    }
    if reply { c.categoryIdentifier = NotificationRender.replyCategory }
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
  }

  /// Status 223 — the notifications of one chat (the extension and the app
  /// both put the chat id in `threadIdentifier`).
  static func clearChatNotifications(chatId: String) {
    guard !chatId.isEmpty else { return }
    let center = UNUserNotificationCenter.current()
    center.getDeliveredNotifications { list in
      let ids = list.filter { $0.request.content.threadIdentifier == chatId }.map { $0.request.identifier }
      if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
    }
  }

  /// ADR-056 — without Apple's filtering entitlement the extension can only
  /// make a blocked person's push silent; take those off the list.
  static func clearBlockedNotifications() {
    let center = UNUserNotificationCenter.current()
    center.getDeliveredNotifications { list in
      let ids = list.filter { $0.request.content.threadIdentifier == "sinhron-blocked" }.map { $0.request.identifier }
      if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
    }
  }

  /// Builds installed from Xcode carry a development provisioning profile
  /// (`aps-environment` = development) — their tokens work only with
  /// Apple's sandbox. TestFlight / App Store builds have none, or a
  /// distribution one: production.
  static let isSandbox: Bool = {
    guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
          let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .isoLatin1),
          let key = text.range(of: "<key>aps-environment</key>") else { return false }
    let rest = text[key.upperBound...].prefix(80)
    return rest.contains("development")
  }()
}

// ADR-066 — "Reply" on a message notification, the iPhone side
// (`lib/core/notification_reply.dart`). iOS wakes the app in the background
// for it and gives it ~30 s. The text is kept in this app's Keychain
// ("this device only") until Dart takes it — at once when the app was only
// in the background, or when Dart next starts: an app iOS had closed comes
// back here without its screen, and Flutter starts its engine with the
// screen, so such a reply goes when Sinhron is next opened (the notification
// says so). Dart sends it as an ordinary encrypted message and answers how it
// went: sent → nothing more; queued / no answer in time → "it will go…";
// failed → "not sent — open the chat".
final class NotificationReplies {
  static let shared = NotificationReplies()
  weak var bridge: PushBridge?

  /// No answer from Dart by then: say it will go later.
  static let waitSeconds = 25.0

  private struct Wait {
    let chatId: String
    let done: () -> Void
    var task: UIBackgroundTaskIdentifier
  }

  private var waits: [String: Wait] = [:]
  private let account = "pending-replies"

  private var base: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "dev.sinhron",
      kSecAttrAccount as String: account,
    ]
  }

  private func load() -> [[String: String]] {
    var q = base
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
      let list = try? JSONDecoder().decode([[String: String]].self, from: data)
    else { return [] }
    return list
  }

  private func save(_ list: [[String: String]]) {
    SecItemDelete(base as CFDictionary)
    guard !list.isEmpty, let data = try? JSONEncoder().encode(list) else { return }
    var item = base
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(item as CFDictionary, nil)
  }

  /// Main thread (the notification delegate).
  func handle(chatId: String, text: String, completion: @escaping () -> Void) {
    let id = UUID().uuidString
    let reply = ["id": id, "chatId": chatId, "text": text]
    save(load() + [reply])
    let task = UIApplication.shared.beginBackgroundTask(withName: "sinhron-reply") { [weak self] in
      self?.finish(id, outcome: nil)
    }
    waits[id] = Wait(chatId: chatId, done: completion, task: task)
    bridge?.offerReply(reply) { [weak self] taken in
      if taken { self?.forget(id) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.waitSeconds) { [weak self] in
      self?.finish(id, outcome: nil)
    }
  }

  private func forget(_ id: String) {
    save(load().filter { $0["id"] != id })
  }

  /// Dart started: every reply waiting for it, forgotten here.
  func take() -> [[String: String]] {
    let list = load()
    save([])
    return list
  }

  func done(id: String, outcome: String) {
    finish(id, outcome: outcome)
  }

  private func finish(_ id: String, outcome: String?) {
    guard let w = waits.removeValue(forKey: id) else { return }
    if outcome != "sent" {
      let ctx = PushContext.load()
      let words = ctx?.words ?? [:]
      let stillHere = load().contains { $0["id"] == id }
      let body: String
      switch outcome {
      case "failed": body = words["replyFailed"] ?? "Reply not sent — open the chat"
      case nil where stillHere && bridge == nil: body = words["replyOnOpen"] ?? "Your reply will go when you open Sinhron"
      default: body = words["replyLater"] ?? "Your reply will go once Sinhron connects"
      }
      let title = ctx?.mode == "nothing" ? "" : (ctx?.chats[w.chatId]?.n ?? "")
      PushBridge.post(chatId: w.chatId, title: title, body: body, reply: false)
    }
    w.done()
    if w.task != .invalid { UIApplication.shared.endBackgroundTask(w.task) }
  }
}

/// Status 183 — a VPN shows up as a scoped network interface (utun / ipsec /
/// ppp / tun / tap) in the system proxy settings. A false "yes" only sends a
/// call over the reserve path, which works anyway.
enum VpnCheck {
  static func active() -> Bool {
    guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
          let scoped = settings["__SCOPED__"] as? [String: Any]
    else { return false }
    let prefixes = ["utun", "ipsec", "ppp", "tun", "tap"]
    return scoped.keys.contains { key in prefixes.contains { key.hasPrefix($0) } }
  }
}

// MARK: - Chat backup in iCloud Drive (ADR-073)

/// The app's own iCloud container (`iCloud.com.sinhron.sinhron`), folder
/// `Documents/Backup` — hidden from the Files app (no NSUbiquitousContainers
/// entry), synced by iOS in its own time. Every file in it is already
/// encrypted (lib/core/backup/backup_service.dart). Channel
/// `dev.sinhron/backup`: `icloudAvailable`, `icloudList`, `icloudPut {name,
/// path}`, `icloudGet {name, path}` (downloads first if iOS evicted it),
/// `icloudDelete {name}`. All off the main thread: iCloud calls can block.
final class BackupBridge: NSObject {
  static let shared = BackupBridge()
  private static let container = "iCloud.com.sinhron.sinhron"
  private let queue = DispatchQueue(label: "dev.sinhron.backup", qos: .utility)

  func attach(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "dev.sinhron/backup", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      let args = call.arguments as? [String: Any] ?? [:]
      let name = args["name"] as? String ?? ""
      let path = args["path"] as? String ?? ""
      let reply: (Any?) -> Void = { value in DispatchQueue.main.async { result(value) } }
      self.queue.async {
        switch call.method {
        case "icloudAvailable": reply(self.folder() != nil)
        case "icloudList": reply(self.list())
        case "icloudPut": reply(self.put(name: name, path: path))
        case "icloudGet": reply(self.get(name: name, path: path))
        case "icloudDelete": reply(self.delete(name: name))
        case "icloudUploaded": reply(self.uploaded(name: name))
        default: DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
        }
      }
    }
  }

  /// Nil when iCloud Drive is off or nobody is signed in to iCloud.
  private func folder() -> URL? {
    let fm = FileManager.default
    guard fm.ubiquityIdentityToken != nil,
          let base = fm.url(forUbiquityContainerIdentifier: BackupBridge.container) else { return nil }
    let dir = base.appendingPathComponent("Documents", isDirectory: true).appendingPathComponent("Backup", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Only our own names reach the file system.
  private func safe(_ name: String) -> Bool {
    name.range(of: "^[0-9a-f]{16}-([0-9a-f]{64}|root\\.sinhron)$", options: .regularExpression) != nil
  }

  private func list() -> [String] {
    guard let dir = folder() else { return [] }
    // 2026-10-26 — a backup just made on my other phone may not be in this
    // folder yet: ask iCloud what it holds (and fetch newer roots) first.
    let remote = gather(in: dir)
    let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    // A file iOS evicted shows as ".<name>.icloud".
    let local = items.map { n -> String in
      if n.hasPrefix(".") && n.hasSuffix(".icloud") { return String(n.dropFirst().dropLast(7)) }
      return n
    }
    return Array(Set(local + remote)).filter(safe).sorted()
  }

  /// What iCloud knows of our folder (NSMetadataQuery — also files whose
  /// newest version hasn't reached this phone yet). Roots that aren't
  /// current here start downloading. Waits at most 10 s; [] if it can't.
  private func gather(in _: URL) -> [String] {
    let done = DispatchSemaphore(value: 0)
    var names: [String] = []
    var observer: NSObjectProtocol?
    let query = NSMetadataQuery()
    DispatchQueue.main.async {
      query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
      // The scope is our container's Documents; our names are checked below
      // (a path prefix may differ by "/private").
      query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*")
      observer = NotificationCenter.default.addObserver(
        forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
      ) { _ in
        query.disableUpdates()
        for case let item as NSMetadataItem in query.results {
          guard let name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String, self.safe(name) else { continue }
          names.append(name)
          let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
          if name.hasSuffix("root.sinhron"), status != NSMetadataUbiquitousItemDownloadingStatusCurrent,
             let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
          }
        }
        query.stop()
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        done.signal()
      }
      if !query.start() { done.signal() }
    }
    if done.wait(timeout: .now() + 10) == .timedOut {
      DispatchQueue.main.async {
        query.stop()
        if let o = observer { NotificationCenter.default.removeObserver(o) }
      }
      DiagNative.log("backup: iCloud listing timed out — using what is on this phone")
    }
    return names
  }

  /// Has iCloud taken [name] from this phone yet? (False while it waits
  /// for Wi-Fi.) True when it can't tell.
  private func uploaded(name: String) -> Bool {
    guard safe(name), let dir = folder() else { return true }
    var u = dir.appendingPathComponent(name)
    u.removeAllCachedResourceValues()
    return (try? u.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey]))?.ubiquitousItemIsUploaded ?? true
  }

  private func put(name: String, path: String) -> Bool {
    guard safe(name), let dir = folder() else { return false }
    let dest = dir.appendingPathComponent(name)
    let src = URL(fileURLWithPath: path)
    var ok = false
    var err: NSError?
    NSFileCoordinator().coordinate(writingItemAt: dest, options: .forReplacing, error: &err) { url in
      try? FileManager.default.removeItem(at: url)
      ok = (try? FileManager.default.copyItem(at: src, to: url)) != nil
    }
    if !ok { DiagNative.log("backup: iCloud write failed \(err?.localizedDescription ?? "")") }
    return ok && err == nil
  }

  private func get(name: String, path: String) -> Bool {
    guard safe(name), let dir = folder() else { return false }
    let fm = FileManager.default
    let src = dir.appendingPathComponent(name)
    let evicted = dir.appendingPathComponent(".\(name).icloud")
    guard fm.fileExists(atPath: src.path) || fm.fileExists(atPath: evicted.path) else { return false }
    try? fm.startDownloadingUbiquitousItem(at: src)
    let deadline = Date().addingTimeInterval(180)
    while Date() < deadline {
      var u = src
      u.removeAllCachedResourceValues()
      let status = (try? u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
      if status == .current || (status == nil && fm.fileExists(atPath: src.path)) { break }
      Thread.sleep(forTimeInterval: 0.5)
    }
    let dest = URL(fileURLWithPath: path)
    var ok = false
    var err: NSError?
    NSFileCoordinator().coordinate(readingItemAt: src, options: [], error: &err) { url in
      try? fm.removeItem(at: dest)
      ok = (try? fm.copyItem(at: url, to: dest)) != nil
    }
    if !ok { DiagNative.log("backup: iCloud read failed for a file \(err?.localizedDescription ?? "")") }
    return ok && err == nil
  }

  private func delete(name: String) -> Bool {
    guard safe(name), let dir = folder() else { return false }
    let target = dir.appendingPathComponent(name)
    var ok = false
    var err: NSError?
    NSFileCoordinator().coordinate(writingItemAt: target, options: .forDeleting, error: &err) { url in
      ok = (try? FileManager.default.removeItem(at: url)) != nil
    }
    return ok
  }
}
