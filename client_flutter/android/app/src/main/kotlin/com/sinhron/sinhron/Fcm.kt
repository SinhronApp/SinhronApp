// ADR-057 — Google push (FCM) on phones with Google services: the one way
// to wake a phone whose owner swiped Sinhron away and installed nothing
// else (2026-10-18: a call didn't ring).
//
// No google-services.json in the APK and no Google Gradle plugin: the
// server hands its Firebase project's ids over `GET /v1/push/info` and Dart
// passes them to [Fcm.configure]; the default FirebaseApp is set up from
// them (now and, saved, on every later process start — SinhronApplication).
// One APK works with any operator's Firebase project, or none: without it
// nothing here runs and the app falls back to ntfy / "always connected".
//
// What arrives is one data field `s`: the server's small JSON padded and
// sealed with AES-256-GCM under [key] — 32 random bytes this phone made and
// registered with its token (`server/src/fcm.rs`). Google never sees what
// it carried, nor whether it was a message or a call. The app then wakes
// its own connection ([PushWake]) and shows the real thing.

package com.sinhron.sinhron

import android.content.Context
import android.content.pm.PackageManager
import android.util.Base64
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.json.JSONObject

object Fcm {
    private const val PREFS = "sinhron_push"
    private const val KEY_OPTIONS = "fcm_options"
    private const val KEY_TOKEN = "fcm_token"
    private const val KEY_KEY = "fcm_key"
    /** The same as the server's `fcm::AAD`. */
    private val AAD = "sinhron-fcm-v1".toByteArray()
    /** A call push older than this rang for nothing — the caller gave up. */
    private const val CALL_MAX_AGE_S = 120L

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Google Play services on this phone (FCM needs them). */
    fun available(ctx: Context): Boolean = try {
        ctx.packageManager.getApplicationInfo("com.google.android.gms", 0).enabled
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }

    /** The token as the server stores it (`fcm:` + Google's), or null. */
    fun token(ctx: Context): String? = prefs(ctx).getString(KEY_TOKEN, null)?.let { "fcm:$it" }

    /** This phone's push key, hex — made once. */
    fun key(ctx: Context): String {
        prefs(ctx).getString(KEY_KEY, null)?.let { return it }
        val k = ByteArray(32).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
        prefs(ctx).edit().putString(KEY_KEY, k).apply()
        return k
    }

    private fun options(json: JSONObject): FirebaseOptions? {
        val project = json.optString("project_id")
        val app = json.optString("app_id")
        val apiKey = json.optString("api_key")
        val sender = json.optString("sender_id")
        if (project.isEmpty() || app.isEmpty() || apiKey.isEmpty() || sender.isEmpty()) return null
        return FirebaseOptions.Builder()
            .setProjectId(project)
            .setApplicationId(app)
            .setApiKey(apiKey)
            .setGcmSenderId(sender)
            .build()
    }

    /** Process start: bring FirebaseApp up from the saved ids (so a push
     *  that starts the process is delivered). True when it is up. */
    fun initFromSaved(ctx: Context): Boolean {
        if (FirebaseApp.getApps(ctx).isNotEmpty()) return true
        val saved = prefs(ctx).getString(KEY_OPTIONS, null) ?: return false
        if (!available(ctx)) return false
        val opts = try {
            options(JSONObject(saved))
        } catch (_: Exception) {
            null
        } ?: return false
        return try {
            FirebaseApp.initializeApp(ctx, opts)
            true
        } catch (_: Exception) {
            false
        }
    }

    /** The server's Firebase ids (null: the server has no FCM) → set up and
     *  fetch the token; [done] gets it (`fcm:…`) or null. Ids of another
     *  project than the running one apply from the next process start. */
    fun configure(ctx: Context, ids: Map<String, Any?>?, done: (String?) -> Unit) {
        val app = ctx.applicationContext
        if (ids == null || !available(app)) {
            DiagNative.log(app, if (ids == null) "fcm: off (the server has no Google push)" else "fcm: off (no Google Play services)")
            forget(app)
            return done(null)
        }
        val json = JSONObject(ids.filterValues { it is String })
        if (options(json) == null) {
            DiagNative.log(app, "fcm: off (the server's Firebase ids are incomplete)")
            return done(null)
        }
        val before = prefs(app).getString(KEY_OPTIONS, null)
        if (before != json.toString()) {
            prefs(app).edit().putString(KEY_OPTIONS, json.toString()).apply()
            if (before != null) {
                // Another project: its token is no good here.
                prefs(app).edit().remove(KEY_TOKEN).apply()
            }
        }
        if (!initFromSaved(app)) {
            DiagNative.log(app, "fcm: Firebase did not start")
            return done(null)
        }
        try {
            val fm = FirebaseMessaging.getInstance()
            fm.isAutoInitEnabled = true
            fm.token.addOnCompleteListener { t ->
                val token = if (t.isSuccessful) t.result else null
                // Status 223: a failed token was silent (the old saved one
                // stayed) — the report now says which.
                if (token != null) {
                    if (token != prefs(app).getString(KEY_TOKEN, null)) DiagNative.log(app, "fcm: token ok (new)")
                    saveToken(app, token, report = false)
                } else {
                    DiagNative.log(app, "fcm: token failed (${t.exception?.javaClass?.simpleName}: ${t.exception?.message?.take(80)})")
                }
                done(token?.let { "fcm:$it" })
            }
        } catch (e: Exception) {
            DiagNative.log(app, "fcm: token failed (${e.javaClass.simpleName})")
            done(null)
        }
    }

    fun saveToken(ctx: Context, token: String, report: Boolean = true) {
        val changed = prefs(ctx).getString(KEY_TOKEN, null) != token
        prefs(ctx).edit().putString(KEY_TOKEN, token).apply()
        if (changed && report) PushBridge.routeChanged(ctx)
    }

    /** The server stopped offering FCM (or Google services went): stop. */
    private fun forget(ctx: Context) {
        if (prefs(ctx).getString(KEY_TOKEN, null) == null) return
        prefs(ctx).edit().remove(KEY_TOKEN).remove(KEY_OPTIONS).apply()
        try {
            if (FirebaseApp.getApps(ctx).isNotEmpty()) {
                FirebaseMessaging.getInstance().isAutoInitEnabled = false
                FirebaseMessaging.getInstance().deleteToken()
            }
        } catch (_: Exception) {}
        PushBridge.routeChanged(ctx)
    }

    /** Open the sealed body `s` — null when it isn't ours (wrong key,
     *  tampered, not base64). */
    fun open(ctx: Context, sealed: String): JSONObject? = try {
        val raw = Base64.decode(sealed, Base64.DEFAULT)
        val hex = prefs(ctx).getString(KEY_KEY, null) ?: return null
        val key = ByteArray(32) { i -> hex.substring(i * 2, i * 2 + 2).toInt(16).toByte() }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, raw, 0, 12))
        c.updateAAD(AAD)
        JSONObject(String(c.doFinal(raw, 12, raw.size - 12), Charsets.UTF_8).trim())
    } catch (_: Exception) {
        null
    }

    /** A call push that waited in Google's queue past the ring. */
    fun stale(json: JSONObject): Boolean {
        val ts = json.optLong("ts", 0)
        return ts > 0 && System.currentTimeMillis() / 1000 - ts > CALL_MAX_AGE_S
    }
}

/** Google delivers here (manifest: MESSAGING_EVENT), on a worker thread,
 *  with the app possibly not running at all. */
class SinhronFcmService : FirebaseMessagingService() {
    /** Google dropped pushes it could not deliver in time (the phone was
     *  unreachable for long, or too many waited). */
    override fun onDeletedMessages() {
        DiagNative.log(this, "fcm: Google dropped waiting pushes")
    }

    override fun onNewToken(token: String) {
        DiagNative.log(this, "fcm: new token")
        Fcm.saveToken(this, token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val json = message.data["s"]?.let { Fcm.open(this, it) }
        if (json == null) {
            DiagNative.log(this, "fcm: push not opened (no key yet, or not ours) priority=${message.priority}")
            return
        }
        val t = json.optString("t")
        DiagNative.log(this, "fcm: push $t (priority ${message.priority}/${message.originalPriority}, visible=${MainActivity.visible})")
        when (t) {
            "msg" -> {
                if (MainActivity.visible) return
                // The app connects and draws "name: text" itself; if it
                // can't in time, the plain "New message" (as with ntfy).
                val shown = PushWake.wake(this, PushWake.WAIT_MS)
                DiagNative.log(this, "fcm: msg — app drew it: $shown")
                if (!shown && !MainActivity.visible) Notifications.newMessage(this, json.optInt("n", 0))
            }
            // ADR-071 (amended) — a message request: the app connects and
            // decides (someone blocked → nothing; else one quiet "New message
            // request"). No plain "New message" if it can't: it may be them.
            "req" -> {
                if (MainActivity.visible) return
                PushWake.wake(this, PushWake.WAIT_MS)
            }
            "call" -> {
                val id = json.optString("id")
                if (id.isEmpty() || Fcm.stale(json)) {
                    val age = System.currentTimeMillis() / 1000 - json.optLong("ts", 0)
                    DiagNative.log(this, "fcm: call dropped — ${if (id.isEmpty()) "no id" else "stale, ${age}s old (phone clock?)"}")
                    return
                }
                // Never ring for someone blocked on this phone (the server
                // puts the caller's key inside the sealed body; Google can't
                // read it). Calls from an older app still come this way.
                if (PushBridge.isBlocked(this, json.optString("c"))) {
                    DiagNative.log(this, "fcm: call from someone blocked — not ringing")
                    return
                }
                DiagNative.log(this, "fcm: call ${id.take(8)} — ringing")
                // Ring at once (full screen); the woken connection brings the
                // invite — the caller's name, Decline that reaches them.
                MainActivity.onMain { CallBridge.incomingFromPush(applicationContext, id, json.optBoolean("v", false)) }
                PushWake.wake(this, PushWake.WAIT_MS)
            }
        }
    }
}
