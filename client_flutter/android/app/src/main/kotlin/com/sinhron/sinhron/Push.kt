// ADR-040 — UnifiedPush ↔ Flutter (`lib/core/push.dart`), the Android side of
// channel `dev.sinhron/push` (same contract as iOS `PushBridge`):
//   register()   ask for notifications (Android 13+), then register with the
//                phone's UnifiedPush distributor (ntfy); true when allowed.
//   status()     "authorized" | "denied" | "notDetermined" | "noDistributor"
//   voipToken()  the endpoint (Android has one for messages and calls)
//   takeOpened() opened from a notification? (chat id when it was a chat's)
//   keepAlive(on)  ADR-040 fallback without ntfy: a foreground service
//                  keeps the app (and its connection) running
//   showMessage(chatId, title, body)  in that mode Dart asks for the
//                  notification of a message it received
//   ntfyInstalled() / openNtfy()  Settings tells the person which server to
//                  set in ntfy (it starts on ntfy.sh, which ours refuses)
//   reconnect()    a fresh registration after that: ntfy keeps an old one on
//                  the server it was made on; true when there is a distributor
//   fcmConfigure(ids?)  ADR-057 — the server's Firebase ids (null: none) →
//                  Google push; the token (`fcm:…`) or null
//   takeWake() / wakeDone(handled)  ADR-057 — `PushWake.kt` (handled: a
//                  message reached the app — no plain "New message")
//   takeReplies() / replyDone(id, outcome)  ADR-066 — `NotificationReply.kt`;
//                  → reply {id, chatId, text} (Dart answers true = taken)
//   → token / voipToken {token, sandbox: false, p256dh?, auth?, key?},
//     tokenRemoved, opened {chatId?}, wake
//
// The token is the phone's push route: Google's (`fcm:…`, with this phone's
// key — ADR-057) when the server has Firebase and the phone Google services,
// else the ntfy endpoint (an https URL on the operator's ntfy; the server
// POSTs a tiny JSON there, `server/src/unifiedpush.rs`). Both draw the
// notification here. Google first: it needs no app installed and Android
// keeps it working for every app; ntfy stays for phones without Google.

package com.sinhron.sinhron

import android.app.Activity
import android.content.Context
import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.unifiedpush.android.connector.FailedReason
import org.unifiedpush.android.connector.PushService
import org.unifiedpush.android.connector.UnifiedPush
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage

object PushBridge {
    private const val PREFS = "sinhron_push"
    private const val KEY_ENDPOINT = "endpoint"
    private const val KEY_P256DH = "p256dh"
    private const val KEY_AUTH = "auth"
    private const val KEY_BLOCKED = "blocked"
    /** ntfy — the same package on Google Play and F-Droid. */
    private const val NTFY = "io.heckel.ntfy"
    private var channel: MethodChannel? = null
    private var pendingOpen = false
    private var pendingChat: String? = null

    /** ADR-071 (amended) — identity keys blocked on this phone, from the
     *  app's notification context (`lib/core/notification_context.dart`). */
    fun saveBlocked(ctx: Context, json: String) {
        val list = try {
            val a = JSONObject(json).optJSONArray("blocked")
            (0 until (a?.length() ?: 0)).map { a!!.getString(it).lowercase() }
        } catch (_: Exception) {
            return
        }
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putStringSet(KEY_BLOCKED, list.toSet()).apply()
    }

    /** Is [identityHex] (a call push's caller) blocked here? */
    fun isBlocked(ctx: Context, identityHex: String): Boolean =
        identityHex.isNotEmpty() &&
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getStringSet(KEY_BLOCKED, emptySet())!!
                .contains(identityHex.lowercase())

    /** [activity] null: the engine runs without a screen ("always
     *  connected", after a restart) — everything but asking for permission. */
    fun attach(context: Context, messenger: BinaryMessenger, activity: MainActivity?) {
        val ctx = context.applicationContext
        val ch = MethodChannel(messenger, "dev.sinhron/push")
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "register" -> if (activity == null) result.success(false) else activity.askNotifications { granted ->
                    if (!granted) {
                        result.success(false)
                    } else {
                        registerWithDistributor(activity)
                        sendRoute(activity)
                        result.success(UnifiedPush.getDistributors(activity).isNotEmpty() || Fcm.token(activity) != null)
                    }
                }
                "status" -> result.success(status(ctx))
                "ntfyInstalled" -> result.success(ctx.packageManager.getLaunchIntentForPackage(NTFY) != null)
                "openNtfy" -> {
                    val open = ctx.packageManager.getLaunchIntentForPackage(NTFY)
                    open?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)?.let { ctx.startActivity(it) }
                    result.success(open != null)
                }
                "reconnect" -> if (activity == null) result.success(false) else {
                    UnifiedPush.unregister(activity)
                    saveEndpoint(activity, null)
                    registerWithDistributor(activity)
                    result.success(UnifiedPush.getDistributors(activity).isNotEmpty())
                }
                "voipToken" -> result.success(route(ctx))
                "fcmConfigure" -> {
                    @Suppress("UNCHECKED_CAST")
                    val ids = call.argument<Map<String, Any?>>("ids")
                    Fcm.configure(ctx, ids) { token ->
                        MainActivity.onMain {
                            result.success(token)
                            sendRoute(ctx)
                        }
                    }
                }
                "takeWake" -> result.success(PushWake.take())
                "wakeDone" -> {
                    PushWake.done(call.argument<Boolean>("handled") == true)
                    result.success(null)
                }
                "takeOpened" -> {
                    result.success(if (pendingOpen) (pendingChat ?: "") else null)
                    pendingOpen = false
                    pendingChat = null
                }
                "keepAlive" -> {
                    if (call.argument<Boolean>("on") == true) KeepAliveService.start(ctx) else KeepAliveService.stop(ctx)
                    result.success(null)
                }
                "clearChat" -> {
                    // Status 223 — read here or on my other device.
                    Notifications.cancelChat(ctx, call.argument<String>("chatId") ?: "")
                    result.success(null)
                }
                "showMessage" -> {
                    // ADR-057 — the real one replaces a plain "New message".
                    PushWake.shown()
                    Notifications.cancelNewMessage(ctx)
                    Notifications.chatMessage(
                        ctx,
                        call.argument<String>("chatId") ?: "",
                        call.argument<String>("title") ?: ctx.getString(R.string.app_name),
                        call.argument<String>("body") ?: ctx.getString(R.string.new_message),
                        reply = call.argument<Boolean>("reply") == true,
                        quiet = call.argument<Boolean>("quiet") == true,
                    )
                    result.success(null)
                }
                // ADR-071 (amended) — the same context the iPhone's extension
                // gets; here only who is blocked matters (a call push from
                // them doesn't ring).
                "setNotificationContext" -> {
                    saveBlocked(ctx, call.argument<String>("json") ?: "")
                    result.success(null)
                }
                "takeReplies" -> result.success(NotificationReplies.take(ctx))
                "replyDone" -> {
                    NotificationReplies.done(call.argument<String>("id") ?: "", call.argument<String>("outcome") ?: "failed")
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        channel = ch
    }

    private fun status(ctx: Context): String = when {
        !Notifications.allowed(ctx) -> if (MainActivity.askedNotifications(ctx)) "denied" else "notDetermined"
        UnifiedPush.getDistributors(ctx).isEmpty() && Fcm.token(ctx) == null -> "noDistributor"
        else -> "authorized"
    }

    private fun registerWithDistributor(activity: Activity) {
        if (UnifiedPush.getAckDistributor(activity) != null || UnifiedPush.getSavedDistributor(activity) != null) {
            UnifiedPush.register(activity)
            return
        }
        UnifiedPush.tryUseDefaultDistributor(activity) { ok -> if (ok) UnifiedPush.register(activity) }
    }

    fun endpoint(ctx: Context): String? =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_ENDPOINT, null)

    /** The endpoint and its Web Push keys (RFC 8291 — the server encrypts
     *  what it sends; ADR-040 part 3). */
    fun saveEndpoint(ctx: Context, url: String?, p256dh: String? = null, auth: String? = null) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().apply {
            if (url == null) {
                remove(KEY_ENDPOINT)
                remove(KEY_P256DH)
                remove(KEY_AUTH)
            } else {
                putString(KEY_ENDPOINT, url)
                putString(KEY_P256DH, p256dh)
                putString(KEY_AUTH, auth)
            }
        }.apply()
        routeChanged(ctx)
    }

    /** The route the server should push to, as `token` / `voipToken`
     *  arguments: Google's token when there is one, else the ntfy endpoint. */
    private fun route(ctx: Context): Map<String, Any?>? {
        Fcm.token(ctx)?.let { return mapOf("token" to it, "sandbox" to false, "key" to Fcm.key(ctx)) }
        val url = endpoint(ctx) ?: return null
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return mapOf(
            "token" to url,
            "sandbox" to false,
            "p256dh" to prefs.getString(KEY_P256DH, null),
            "auth" to prefs.getString(KEY_AUTH, null),
        )
    }

    /** A new token / endpoint, or one gone: tell Dart (no route left — take
     *  the old one off the server). */
    fun routeChanged(ctx: Context) {
        if (route(ctx) != null) sendRoute(ctx) else MainActivity.onMain { channel?.invokeMethod("tokenRemoved", null) }
    }

    /** One route serves messages and calls: both kinds go to the server. */
    private fun sendRoute(ctx: Context) {
        val args = route(ctx) ?: return
        MainActivity.onMain {
            channel?.invokeMethod("token", args)
            channel?.invokeMethod("voipToken", args)
        }
    }

    /** ADR-057 — ask Dart to wake its connection; false with no Dart. */
    fun wake(): Boolean {
        val ch = channel ?: return false
        ch.invokeMethod("wake", null)
        return true
    }

    fun opened(chatId: String? = null) {
        pendingOpen = true
        pendingChat = chatId
        MainActivity.onMain {
            channel?.invokeMethod("opened", mapOf("chatId" to chatId), object : MethodChannel.Result {
                // ADR-066 — Dart has it (or keeps it for its `takeOpened`):
                // not handed over a second time.
                override fun success(r: Any?) {
                    if (pendingChat == chatId) {
                        pendingOpen = false
                        pendingChat = null
                    }
                }
                override fun error(code: String, msg: String?, details: Any?) {}
                override fun notImplemented() {}
            })
        }
    }

    /** ADR-066 — a reply for Dart; [taken] true once Dart has it. False: no Dart. */
    fun reply(args: Map<String, String>, taken: (Boolean) -> Unit): Boolean {
        val ch = channel ?: return false
        ch.invokeMethod("reply", args, object : MethodChannel.Result {
            override fun success(r: Any?) = taken(r == true)
            override fun error(code: String, msg: String?, details: Any?) = taken(false)
            override fun notImplemented() = taken(false)
        })
        return true
    }
}

/** Receives UnifiedPush events from the distributor (manifest: PUSH_EVENT). */
class SinhronPushService : PushService() {
    override fun onNewEndpoint(endpoint: PushEndpoint, instance: String) {
        if (!endpoint.temporary) {
            PushBridge.saveEndpoint(this, endpoint.url, endpoint.pubKeySet?.pubKey, endpoint.pubKeySet?.auth)
        }
    }

    override fun onMessage(message: PushMessage, instance: String) {
        // The server encrypts every push to this phone's keys (RFC 8291); a
        // plaintext one came from someone who only knows the endpoint URL —
        // e.g. a fake "incoming call". Ignore it.
        if (!message.decrypted) {
            DiagNative.log(this, "ntfy: push not encrypted — ignored")
            return
        }
        val json = try {
            JSONObject(String(message.content, Charsets.UTF_8))
        } catch (_: Exception) {
            return
        }
        DiagNative.log(this, "ntfy: push ${json.optString("t")} (visible=${MainActivity.visible})")
        when (json.optString("t")) {
            "msg" -> if (!MainActivity.visible) Notifications.newMessage(this, json.optInt("n", 0))
            // ADR-071 (amended) — a message request: no "New message" here
            // (it may be from someone blocked); the app connects, sees who
            // wrote and decides.
            "req" -> if (!MainActivity.visible) PushWake.wake(this, 0)
            "call" -> {
                val id = json.optString("id")
                // Never ring for someone blocked on this phone.
                if (id.isNotEmpty() && !PushBridge.isBlocked(this, json.optString("c"))) {
                    CallBridge.incomingFromPush(this, id, json.optBoolean("v", false))
                }
            }
        }
    }

    override fun onRegistrationFailed(reason: FailedReason, instance: String) {}

    override fun onUnregistered(instance: String) {
        PushBridge.saveEndpoint(this, null)
    }
}
