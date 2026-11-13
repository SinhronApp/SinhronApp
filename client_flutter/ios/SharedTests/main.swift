// ADR-056 — checks for ios/Shared/PushShared.swift against the Rust side,
// run on a Mac without Xcode's UI or a simulator:
//
//   swiftc -O ios/Shared/PushShared.swift ios/SharedTests/main.swift -o /tmp/push_shared_test && /tmp/push_shared_test
//
// The vector comes from `cargo test -p sinhron_sync push_preview_vector
// -- --nocapture` (Rust seals, Swift opens); the call hint from the
// server's `push::tests::call_hint_matches_the_phone`.

import CryptoKit
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String) {
  print(ok ? "ok   \(what)" : "FAIL \(what)")
  if !ok { failed += 1 }
}

let secret = Data(hex: "d804e78c96c67d5ffcf785c0c0caacaede2e54c1397786c3739d6c04cf80f39e")!
let sealed = Data(hex: "01fe16a29b0dfb2c0922aeae1703909e9b891ac3b3319d42fdb9a582e684afd23312e4677246684b7c3c06c9c9a6d1b5b21825b3b588ca6ae464d4b784e0ba58f24dabdca46e2e8c564c755d01e18e0412af23d8f0b0ff5678bf2e10d183cd7a00dfc0d2e54a57083aaa74a48500c8534fdd7980ac83c791c94d2f901965e824052439329d0ef9f64d73fab1294e085a97570d38d8ba41ad757335ad887651a8644aabfc5e89ddfcaa0f35c8e396bf946ec5b40f381f5debc705929f86733ed75376a4782d111db9a02b1aff568390d899a97bfbae626c499ac620a88b7d847203d0eac22508f19ed0db6a064af727ecad9c3758eefc0d089db42613db9ccbea0c59dcfc13ef3cabb91d06af0f2cfa7790d3d066982f5a5387f8ab6ac37e04a9cb08edebcf8592eb6340568a67818350f66b006d42362c40fdb1f85688d11909d22c7fced806ca6ec4a7e3f2608eb2a6ca1bf83d89d9b250c00e3985b6e8c3932bd3a1caa955e4423ceae580fc2c998f66162d07e11d61e85f8e43e2ae5fe7e564b6ac4eead13dbf0479a2b36a5c90a2fe3a59cfd8a3c5bf0c9ff684d4230582e2ce46a54bbf2f21fc2671c4ad84ba7341f5926751083733ddac84d68741b4eae21bcf7f4abd460ba2caec037d0e39f67267cda81cbd4943971997db1f28a09a30123eff6620d1b172caf831f8cee890670380a52f35495a2f797620a4d05c67f98117597a3b7690137f324effbdcd84a489fb461993a226dab7fb51f082086ade247c16d2c5672537918600c6f54ff76754d63eae09b0aa449790a7bfbdd0b6cef4aba77ff46ce875ad5f106d15c59ceaaaa230ec81a058b2eac58dd65e4de020cb0d3f56586411f5e7084dbc5465b2f034437497ffeca3564bfa7f3da79f2cf7b3a035713b973c21b050577acce41ea193f58c0ae70a0e0472aef20de488a6993627cf025d45d756d1de607831e108ec")!

let other = Data(repeating: 0x42, count: 32)
let p = PushPreview.open(sealed, secrets: [other, secret])
check(p?.text == "Привет!", "Rust's preview opens in Swift: \(p?.text ?? "nil")")
check(p?.kind == "text" && p?.sentAt == 1_760_000_000, "kind and time")
check(p?.groupId == Data(repeating: 0xab, count: 16), "chat id")
// SigningKey::from_bytes([9; 32]).verifying_key()
let sender = p?.sender.hex ?? ""
check(sender.count == 64, "sender identity \(sender)")
check(PushPreview.open(sealed, secrets: [other]) == nil, "someone else's key opens nothing")
var bad = sealed
bad[200] ^= 1
check(PushPreview.open(bad, secrets: [secret]) == nil, "a changed byte opens nothing")

let chat = Data(repeating: 0xab, count: 16).hex
var ctx = PushContext(
  mode: "nameAndText",
  words: ["newMessage": "Новое сообщение", "photo": "Фото"],
  chats: [chat: .init(n: "Мама", g: false, m: false, b: false, p: sender)],
  people: [sender: "Мама"],
  blocked: [])
let now = Date(timeIntervalSince1970: 1_760_000_100)
let r = NotificationRender.render(p, context: ctx, now: now)
check(r == RenderedNotification(title: "Мама", body: "Привет!", chatId: chat, quiet: false, blocked: false), "name and text: \(String(describing: r))")
// sealed-push:2 — someone else's valid preview with Mom's chat id: no "Мама",
// no text; in a group, a sender not named here can't type a fake "Мама: ".
ctx.chats[chat]?.p = String(repeating: "0", count: 64)
let spoof = NotificationRender.render(p, context: ctx, now: now)
check(spoof?.title == "" && spoof?.body == "Новое сообщение", "a stranger in Mom's chat: plain: \(String(describing: spoof))")
ctx.chats[chat]?.p = sender
ctx.chats[chat]?.g = true
ctx.people = [:]
check(NotificationRender.render(p, context: ctx, now: now)?.body == "Новое сообщение", "group, unnamed sender: plain")
ctx.people = [sender: "Мама"]
ctx.chats[chat]?.g = false
ctx.mode = "nameOnly"
check(NotificationRender.render(p, context: ctx, now: now)?.body == "Новое сообщение", "name only")
ctx.mode = "nothing"
check(NotificationRender.render(p, context: ctx, now: now)?.title == "", "nothing: no name")
ctx.mode = "nameAndText"
ctx.chats[chat]?.g = true
check(NotificationRender.render(p, context: ctx, now: now)?.body == "Мама: Привет!", "group: sender: text")
ctx.blocked = [sender]
check(NotificationRender.render(p, context: ctx, now: now)?.blocked == true, "blocked sender")
ctx.blocked = []
check(NotificationRender.render(p, context: ctx, now: Date(timeIntervalSince1970: 1_760_200_000))?.body == "Новое сообщение", "a day-old preview is plain")
// ADR-066 — "Reply" only when the app turned it on, for a known chat that
// isn't a request, never with "show nothing".
check(NotificationRender.render(p, context: ctx, now: now)?.canReply == false, "no reply unless the app says so")
ctx.reply = true
check(NotificationRender.render(p, context: ctx, now: now)?.canReply == true, "reply on")
ctx.mode = "nameOnly"
check(NotificationRender.render(p, context: ctx, now: now)?.canReply == true, "reply with name only")
ctx.mode = "nothing"
check(NotificationRender.render(p, context: ctx, now: now)?.canReply == false, "no reply with nothing shown")
ctx.mode = "nameAndText"
ctx.chats[chat]?.q = true
check(NotificationRender.render(p, context: ctx, now: now)?.canReply == false, "no reply in a message request")
ctx.chats[chat]?.q = nil
ctx.blocked = [sender]
check(NotificationRender.render(p, context: ctx, now: now)?.canReply == false, "no reply to someone blocked")
ctx.blocked = []
let decoded = try? JSONDecoder().decode(PushContext.self, from: Data(#"{"mode":"nameAndText","words":{},"chats":{"ab":{"n":"A","q":true}},"people":{},"blocked":[],"reply":true}"#.utf8))
check(decoded?.reply == true && decoded?.chats["ab"]?.q == true, "Dart's reply / q fields decode")
let old = try? JSONDecoder().decode(PushContext.self, from: Data(#"{"mode":"nameAndText","words":{},"chats":{},"people":{},"blocked":[]}"#.utf8))
check(old != nil && old?.reply == nil, "an older context still decodes (no reply)")
check(NotificationRender.displayMentions("hi @[\(sender)]!", people: [sender: "Мама"]) == "hi @Мама!", "mentions")

// ADR-071 (amended) — a message request: a stranger's chat (q) or one not
// on this phone yet → one quiet "New message request", no name or text;
// an accepted chat → its usual notification; someone blocked or a preview
// that doesn't open → nothing at all.
ctx.words["request"] = "Новый запрос на переписку"
ctx.chats[chat]?.g = false
ctx.chats[chat]?.q = true
let req = RequestNotice.decide(p, context: ctx, now: now)
check(req == RenderedNotification(title: "", body: "Новый запрос на переписку", chatId: chat, quiet: true, blocked: false), "request: quiet, no name: \(String(describing: req))")
ctx.chats[chat]?.q = nil
check(RequestNotice.decide(p, context: ctx, now: now)?.body == "Привет!", "an accepted chat: its usual notification")
var unknownChat = ctx
unknownChat.chats = [:]
check(RequestNotice.decide(p, context: unknownChat, now: now)?.chatId == "", "a chat not here yet: the request, no chat id")
ctx.blocked = [sender]
check(RequestNotice.decide(p, context: ctx, now: now) == nil, "blocked sender: nothing")
ctx.blocked = []
ctx.chats[chat]?.b = true
check(RequestNotice.decide(p, context: ctx, now: now) == nil, "a personal chat with someone blocked: nothing")
ctx.chats[chat]?.b = nil
check(RequestNotice.decide(nil, context: ctx, now: now) == nil, "no preview: nothing (can't rule out a blocked sender)")
check(RequestNotice.decide(p, context: nil, now: now) == nil, "no context: nothing")

// Server `push::call_hint(key = [7; 32], "call-1", group = [0xab; 16])`.
let hint = CallHint.hint(key: Data(repeating: 7, count: 32), callId: "call-1", groupId: Data(repeating: 0xab, count: 16))
print("hint=\(hint)")
check(CallHint.chat(hint: hint, callId: "call-1", key: Data(repeating: 7, count: 32), chatIds: ["00", chat]) == chat, "call hint → chat")
check(CallHint.chat(hint: hint, callId: "call-2", key: Data(repeating: 7, count: 32), chatIds: [chat]) == nil, "another call's hint")

// ADR-090 — Rust `call_invite::tests::call_proof_vector` (seed [9; 32], the
// preview's sender too): "call-1", chat [0xab; 16], audio, ts 1 760 000 000.
let callProof = [UInt8](Data(hex: "0000000068e778005aeb0413e7e368356525b7573fead07754e11ec35b2968f615b8e0202ca863b629fcf3114084997e62310a2155c78ad6365b386df4ae8da2d1c27470391ff40cfd1724385aa0c75b64fb78cd602fa1d991fdebf76b13c58ed702eac835e9f618")!)
let callAt = Date(timeIntervalSince1970: 1_760_000_000)
let group16 = Data(repeating: 0xab, count: 16)
check(CallProof.verify(callProof, callId: "call-1", groupId: group16, video: false, now: callAt)?.hex == sender, "Rust's call proof names its caller")
check(CallProof.verify(callProof, callId: "call-1", groupId: group16, video: true, now: callAt) == nil, "video, not audio: nothing")
check(CallProof.verify(callProof, callId: "call-2", groupId: group16, video: false, now: callAt) == nil, "another call: nothing")
check(CallProof.verify(callProof, callId: "call-1", groupId: group16, video: false, now: callAt + 600) == nil, "replayed later: nothing")
// Sealed as the server does (`push::seal_call_proof`): opens with the hint key only.
var padded = [UInt8(callProof.count)] + callProof
padded += [UInt8](repeating: 0, count: 205 - padded.count)
let box = try! AES.GCM.seal(Data(padded), using: SymmetricKey(data: Data(repeating: 7, count: 32)), authenticating: CallProof.aad)
check(CallProof.caller(sealed: box.combined!, key: Data(repeating: 7, count: 32), callId: "call-1", groupId: group16, video: false, now: callAt)?.hex == sender, "sealed proof opens")
check(CallProof.caller(sealed: box.combined!, key: Data(repeating: 8, count: 32), callId: "call-1", groupId: group16, video: false, now: callAt) == nil, "another phone's key: nothing")

print(failed == 0 ? "all passed" : "\(failed) failed")
exit(failed == 0 ? 0 : 1)
