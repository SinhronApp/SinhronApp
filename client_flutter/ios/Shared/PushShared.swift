// ADR-056 — what the app and its Notification Service Extension share.
//
// Both targets compile this file. Everything lives in the Keychain under a
// shared access group (`SinhronKeychainGroup` in each Info.plist =
// `$(AppIdentifierPrefix)com.sinhron.shared`), readable after the first
// unlock — so a push that comes to a locked phone still finds it. No App
// Group container: the Keychain is encrypted by iOS and needs no extra
// capability in the Apple developer account.
//
//   push-context   JSON (PushContext): what notifications show, the words,
//                  chat / people names, who is blocked, whether "Reply" is
//                  on (ADR-066) — the app rewrites it when any of that
//                  changes.
//   push-keys      JSON [hex]: this person's private delivery keys for the
//                  weeks a sender may seal to (Rust `push_preview_secrets`).
//   call-hint-key  32 random bytes: the server gets them with the PushKit
//                  token and puts HMAC(key, call ‖ chat) into a call push;
//                  only this phone can tell which chat that is.
//
// Opening a preview: HPKE (RFC 9180) from CryptoKit, iOS 17+ — the same
// steps as Rust `sinhron_sync::push_preview::open`. Older iOS shows the
// server's "New message".

import CryptoKit
import Foundation
import Security

enum SharedKeychain {
  static let context = "push-context"
  static let keys = "push-keys"
  static let callHintKey = "call-hint-key"
  private static let service = "com.sinhron.push"

  /// `$(AppIdentifierPrefix)com.sinhron.shared` from Info.plist.
  static var group: String? {
    (Bundle.main.object(forInfoDictionaryKey: "SinhronKeychainGroup") as? String).flatMap {
      $0.isEmpty || $0.hasPrefix("$(") ? nil : $0
    }
  }

  private static func query(_ account: String) -> [String: Any] {
    var q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if let g = group { q[kSecAttrAccessGroup as String] = g }
    return q
  }

  static func read(_ account: String) -> Data? {
    var q = query(account)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: AnyObject?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
    return out as? Data
  }

  @discardableResult
  static func write(_ account: String, _ data: Data?) -> Bool {
    let q = query(account)
    guard let data = data else {
      let s = SecItemDelete(q as CFDictionary)
      return s == errSecSuccess || s == errSecItemNotFound
    }
    let attrs: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let s = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
    if s == errSecItemNotFound {
      return SecItemAdd(q.merging(attrs) { $1 } as CFDictionary, nil) == errSecSuccess
    }
    return s == errSecSuccess
  }

  /// The call hint key, made once.
  static func callHintKeyMakingIfNeeded() -> Data? {
    if let k = read(callHintKey), k.count == 32 { return k }
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, 32, &bytes) == errSecSuccess else { return nil }
    let k = Data(bytes)
    return write(callHintKey, k) ? k : nil
  }
}

/// What the app tells the extension (Dart `NotificationContext`).
struct PushContext: Codable {
  struct Chat: Codable {
    var n: String
    var g: Bool?
    var m: Bool?
    var b: Bool?
    /// ADR-066 — a message request: no "Reply" from the notification.
    var q: Bool?
    /// ADR-090 — a personal chat's person (identity key hex, lower case).
    var p: String?
  }
  /// "nameAndText" / "nameOnly" / "nothing".
  var mode: String
  /// newMessage, photo, voice, video, document, sticker… in the app's language.
  var words: [String: String]
  /// Chat id (group id hex) → name, group?, muted?, blocked (personal chat)?
  var chats: [String: Chat]
  /// Identity key hex → name.
  var people: [String: String]
  /// Identity keys blocked on this phone.
  var blocked: [String]
  /// ADR-066 — "Reply" on message notifications (off with "show nothing"
  /// and with App Lock; absent in an older app's context = off).
  var reply: Bool?

  static func load() -> PushContext? {
    SharedKeychain.read(SharedKeychain.context).flatMap { try? JSONDecoder().decode(PushContext.self, from: $0) }
  }
}

/// A preview the extension opened and verified.
struct OpenedPreview: Equatable {
  var sentAt: UInt64
  var groupId: Data
  var kind: String
  var text: String
  var sender: Data
}

enum PushPreview {
  static let info = Data("sinhron-push-preview-v1".utf8)
  static let sigDomain = Data("sinhron-push-preview-v1:".utf8)
  static let certDomain = Data("sinhron-device-cert-v1:".utf8)
  static let plainLen = 640
  static let sealedLen = 1 + 32 + plainLen + 16

  /// Open `sealed` with one of `secrets` (32-byte X25519 private keys).
  static func open(_ sealed: Data, secrets: [Data]) -> OpenedPreview? {
    guard #available(iOS 17.0, macOS 14.0, *) else { return nil }
    let s = [UInt8](sealed)
    guard s.count == sealedLen, s[0] == 1 else { return nil }
    let enc = Data(s[1..<33])
    let ct = Data(s[33...])
    for secret in secrets {
      guard let sk = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: secret) else { continue }
      let keyId = Data(SHA256.hash(data: sk.publicKey.rawRepresentation).prefix(16))
      guard
        var r = try? HPKE.Recipient(
          privateKey: sk, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info, encapsulatedKey: enc),
        let plain = try? r.open(ct, authenticating: keyId)
      else { continue }
      return parse([UInt8](plain), keyId: keyId)
    }
    return nil
  }

  private static func parse(_ p: [UInt8], keyId: Data) -> OpenedPreview? {
    guard p.count >= 10, p[0] == 1 else { return nil }
    var sentAt: UInt64 = 0
    for b in p[1..<9] { sentAt = sentAt << 8 | UInt64(b) }
    let kn = Int(p[9])
    var at = 10 + kn
    guard at <= p.count, let kind = String(bytes: p[10..<at], encoding: .utf8) else { return nil }
    func take() -> [UInt8]? {
      guard at + 2 <= p.count else { return nil }
      let n = Int(p[at]) << 8 | Int(p[at + 1])
      guard at + 2 + n <= p.count else { return nil }
      defer { at += 2 + n }
      return Array(p[at + 2..<at + 2 + n])
    }
    guard let group = take(), let textBytes = take(), let text = String(bytes: textBytes, encoding: .utf8),
      let credential = take(), at + 64 <= p.count
    else { return nil }
    let body = Data(p[0..<at])
    let sig = Data(p[at..<at + 64])
    let identity: Data
    let signer: Data
    if credential.count == 32 {
      identity = Data(credential)
      signer = identity
    } else if credential.count == 132, Array(credential[0..<4]) == Array("SDC1".utf8) {
      identity = Data(credential[4..<36])
      signer = Data(credential[36..<68])
      guard let ik = try? Curve25519.Signing.PublicKey(rawRepresentation: identity),
        ik.isValidSignature(Data(credential[68..<132]), for: certDomain + signer)
      else { return nil }
    } else {
      return nil
    }
    guard let vk = try? Curve25519.Signing.PublicKey(rawRepresentation: signer),
      vk.isValidSignature(sig, for: sigDomain + keyId + body)
    else { return nil }
    return OpenedPreview(sentAt: sentAt, groupId: Data(group), kind: kind, text: text, sender: identity)
  }
}

extension Data {
  init?(hex: String) {
    let chars = Array(hex.utf8)
    guard chars.count % 2 == 0 else { return nil }
    var out = [UInt8]()
    out.reserveCapacity(chars.count / 2)
    for i in stride(from: 0, to: chars.count, by: 2) {
      guard let b = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
      out.append(b)
    }
    self.init(out)
  }

  var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// What a message notification turns into.
struct RenderedNotification: Equatable {
  /// "" = no title (iOS shows "Sinhron" above anyway).
  var title: String
  var body: String
  /// Chat id for grouping and for opening it on tap ("" = none).
  var chatId: String
  /// No sound, no lit screen (muted chat).
  var quiet: Bool
  /// Someone blocked here: show nothing if iOS lets us (the filtering
  /// entitlement), else the plain "New message", silently.
  var blocked: Bool
  /// ADR-066 — gets the "Reply" field (category [NotificationRender.replyCategory]).
  var canReply: Bool = false
}

enum NotificationRender {
  /// Older than this, a preview is old news (or replayed): plain text.
  static let maxAge: UInt64 = 24 * 3600

  /// ADR-066 — the category with the "Reply" text field, and its action.
  static let replyCategory = "sinhron-message"
  static let replyAction = "reply"

  static func render(_ p: OpenedPreview?, context c: PushContext?, now: Date) -> RenderedNotification? {
    guard let p = p, let c = c else { return nil }
    let generic = c.words["newMessage"] ?? "New message"
    let chatId = p.groupId.hex
    let senderHex = p.sender.hex
    let chat = c.chats[chatId]
    let nowSecs = UInt64(max(0, now.timeIntervalSince1970))
    if c.blocked.contains(senderHex) || chat?.b == true {
      return RenderedNotification(title: "", body: generic, chatId: "", quiet: true, blocked: true)
    }
    // Unknown chat (not in the app's list yet), stale or a future time: the
    // server's words, but the tap still opens the chat.
    guard let known = chat, p.sentAt + maxAge >= nowSecs, p.sentAt <= nowSecs + 600 else {
      return RenderedNotification(title: "", body: generic, chatId: chat == nil ? "" : chatId, quiet: chat?.m == true, blocked: false)
    }
    let quiet = known.m == true
    if c.mode == "nothing" {
      return RenderedNotification(title: "", body: generic, chatId: chatId, quiet: quiet, blocked: false)
    }
    let title = known.n
    let senderName = c.people[senderHex].flatMap { $0.isEmpty ? nil : $0 }
    // sealed-push:2 — the signature says who wrote it, not that they are in
    // this chat: a personal chat is named only for its own peer, a group
    // shows text only from someone named here (a typed "Мама: " can't pass).
    let trusted = known.g == true ? senderName != nil : known.p?.lowercased() == senderHex
    if !trusted {
      return RenderedNotification(
        title: known.g == true ? title : "", body: generic, chatId: chatId, quiet: quiet, blocked: false)
    }
    if c.mode == "nameOnly" {
      let body = known.g == true ? (senderName.map { "\($0): \(generic)" } ?? generic) : generic
      return RenderedNotification(
        title: title, body: body, chatId: chatId, quiet: quiet, blocked: false, canReply: canReply(known, c))
    }
    var text = displayMentions(p.text, people: c.people)
    if text.isEmpty { text = c.words[p.kind] ?? generic }
    let body = known.g == true ? (senderName.map { "\($0): \(text)" } ?? text) : text
    return RenderedNotification(
      title: title, body: body, chatId: chatId, quiet: quiet, blocked: false, canReply: canReply(known, c))
  }

  /// ADR-066 — "Reply" for a known chat: the app said so (not "show nothing",
  /// no App Lock) and it isn't a request or a chat with someone blocked.
  static func canReply(_ chat: PushContext.Chat, _ c: PushContext) -> Bool {
    c.reply == true && c.mode != "nothing" && chat.q != true && chat.b != true
  }

  /// `@[<identity key>]` → "@Name" (lib/core/mentions.dart).
  static func displayMentions(_ text: String, people: [String: String]) -> String {
    guard text.contains("@["),
      let re = try? NSRegularExpression(pattern: "@\\[([0-9a-f]{64})\\]")
    else { return text }
    var out = text
    for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
      guard let whole = Range(m.range, in: text), let keyRange = Range(m.range(at: 1), in: text) else { continue }
      let key = String(text[keyRange])
      let name = people[key].flatMap { $0.isEmpty ? nil : $0 } ?? String(key.prefix(8))
      out.replaceSubrange(whole, with: "@\(name)")
    }
    return out
  }
}

/// ADR-071 (amended) — a message request: someone wrote without my access
/// key (a stranger, or before our keys were exchanged). The server sends a
/// background push with the sender's sealed preview and nothing else; the
/// app decides here. `nil` = show nothing: the preview doesn't open or
/// verify, the app left no context, or the sender is blocked on this
/// phone. A chat I already accepted gets its usual notification; anything
/// else one quiet "New message request" — no name, no text, no sound.
enum RequestNotice {
  /// One per chat, replaced by the next (and one for unknown chats).
  static func identifier(chatId: String) -> String { "sinhron-request-\(chatId)" }

  static func decide(_ p: OpenedPreview?, context c: PushContext?, now: Date) -> RenderedNotification? {
    guard let p = p, let c = c else { return nil }
    let chatId = p.groupId.hex
    let chat = c.chats[chatId]
    if c.blocked.contains(p.sender.hex) || chat?.b == true { return nil }
    if let known = chat, known.q != true {
      guard let r = NotificationRender.render(p, context: c, now: now), !r.blocked else { return nil }
      return r
    }
    let words = c.words["request"] ?? "New message request"
    return RenderedNotification(title: "", body: words, chatId: chat == nil ? "" : chatId, quiet: true, blocked: false)
  }
}

/// ADR-090 (calls:5) — the caller's signature on its invite, as the server
/// passes it in a VoIP push (`s`, `push::seal_call_proof`): base64 of
/// nonce ‖ AES-256-GCM(call hint key, u8 len ‖ proof ‖ zeros) ‖ tag, aad
/// `sinhron-call-proof-v1`. proof = u64 BE ts ‖ Ed25519 signature ‖
/// credential (32: identity key; 132: device certificate), signed over
/// `sinhron-call-invite-v1:` ‖ ts ‖ kind (1 audio, 2 video) ‖ u8 len call id
/// ‖ call id ‖ group id — the same as Rust's `sinhron_sync::call_invite`.
enum CallProof {
  static let domain = Data("sinhron-call-invite-v1:".utf8)
  static let aad = Data("sinhron-call-proof-v1".utf8)
  static let maxAge: Int64 = 120

  /// The caller's identity key, if [sealed] opens with [key] and holds a
  /// fresh signature on this call.
  static func caller(sealed: Data, key: Data, callId: String, groupId: Data, video: Bool, now: Date) -> Data? {
    guard let box = try? AES.GCM.SealedBox(combined: sealed),
      let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
    else { return nil }
    let p = [UInt8](plain)
    guard let n = p.first, p.count >= 1 + Int(n) else { return nil }
    return verify(Array(p[1..<1 + Int(n)]), callId: callId, groupId: groupId, video: video, now: now)
  }

  /// The identity key behind [proof] (not sealed), or nil.
  static func verify(_ proof: [UInt8], callId: String, groupId: Data, video: Bool, now: Date) -> Data? {
    guard proof.count >= 8 + 64 + 32 else { return nil }
    var ts: UInt64 = 0
    for b in proof[0..<8] { ts = ts << 8 | UInt64(b) }
    guard ts <= UInt64(Int64.max), abs(Int64(now.timeIntervalSince1970) - Int64(ts)) <= maxAge else { return nil }
    let sig = Data(proof[8..<72])
    let credential = Array(proof[72...])
    let identity: Data
    let signer: Data
    if credential.count == 32 {
      identity = Data(credential)
      signer = identity
    } else if credential.count == 132, Array(credential[0..<4]) == Array("SDC1".utf8) {
      identity = Data(credential[4..<36])
      signer = Data(credential[36..<68])
      guard let ik = try? Curve25519.Signing.PublicKey(rawRepresentation: identity),
        ik.isValidSignature(Data(credential[68..<132]), for: PushPreview.certDomain + signer)
      else { return nil }
    } else {
      return nil
    }
    var msg = domain
    msg.append(contentsOf: proof[0..<8])
    msg.append(UInt8(video ? 2 : 1))
    let id = Data(callId.utf8)
    msg.append(UInt8(min(id.count, 255)))
    msg.append(id)
    msg.append(groupId)
    guard let vk = try? Curve25519.Signing.PublicKey(rawRepresentation: signer), vk.isValidSignature(sig, for: msg)
    else { return nil }
    return identity
  }
}

/// ADR-056 — which chat an incoming call push is for.
enum CallHint {
  /// What CallKit shows for a call push: the caller's name (or "Sinhron" when
  /// unknown / notifications show nothing), and whether that chat is a
  /// personal one with someone blocked here (or the caller is blocked).
  /// ADR-090 (calls:5) — a name only when [proof] (the push's `s`) is the
  /// caller's own fresh signature on this call in this chat: the server
  /// knows the hint key, so the hint alone could name anyone.
  static func lookup(hint: String?, callId: String, video: Bool, proof: String?) -> (name: String, blocked: Bool) {
    guard let hint = hint, let key = SharedKeychain.read(SharedKeychain.callHintKey),
      let c = PushContext.load(),
      let id = chat(hint: hint, callId: callId, key: key, chatIds: Array(c.chats.keys)),
      let found = c.chats[id], let groupId = Data(hex: id)
    else { return ("Sinhron", false) }
    guard let sealed = proof.flatMap({ Data(base64Encoded: $0) }),
      let caller = CallProof.caller(sealed: sealed, key: key, callId: callId, groupId: groupId, video: video, now: Date())
    else { return ("Sinhron", found.b == true) }
    if c.blocked.contains(caller.hex) { return ("Sinhron", true) }
    // Its own person in a personal chat: the chat's name; anyone else: the
    // signer's own name here (a stranger's key has none — "Sinhron").
    let person = found.p == caller.hex ? found.n : (c.people[caller.hex] ?? "")
    let name = c.mode == "nothing" || person.isEmpty ? "Sinhron" : person
    return (name, found.b == true)
  }

  /// HMAC-SHA256(key, "sinhron-call-hint-v1" ‖ call id ‖ group id), first
  /// 16 bytes, hex — the same as the server's `push::call_hint`.
  static func hint(key: Data, callId: String, groupId: Data) -> String {
    var msg = Data("sinhron-call-hint-v1".utf8)
    msg.append(Data(callId.utf8))
    msg.append(groupId)
    let mac = HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key))
    return Data(mac).prefix(16).hex
  }

  /// The chat id whose hint this is, among [chatIds].
  static func chat(hint: String, callId: String, key: Data, chatIds: [String]) -> String? {
    let want = hint.lowercased()
    return chatIds.first { id in
      guard let g = Data(hex: id) else { return false }
      return Self.hint(key: key, callId: callId, groupId: g) == want
    }
  }
}
