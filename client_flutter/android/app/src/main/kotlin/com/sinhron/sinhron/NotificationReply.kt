// ADR-066 — "Reply" on a message notification: the person types the answer
// in the notification and it goes without the app coming on screen.
//
// The text never leaves the phone except as the app's ordinary encrypted
// message: [ReplyReceiver] keeps it encrypted with the Keystore key
// (`SecureStore`, account "pending-replies") until Dart takes it — as a
// `reply` event when Dart runs (the screen's engine or the shared one), else
// Dart's `takeReplies` when the engine it starts here comes up. Dart sends it
// like a message typed in the chat (`lib/core/notification_reply.dart`) and
// answers `replyDone {id, outcome}`; the notification then goes (sent) or says
// "it will go once Sinhron connects" (queued, or no answer in time) / "not
// sent — open the chat" (failed).
//
// The receiver keeps the process running while it waits (goAsync, ≤ [WAIT_MS]):
// Android doesn't freeze a process with a receiver in progress.

package com.sinhron.sinhron

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.RemoteInput
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

object NotificationReplies {
    const val KEY_TEXT = "reply_text"
    const val EXTRA_TITLE = "reply_title"
    const val ACTION_REPLY = "com.sinhron.sinhron.REPLY"
    private const val ACCOUNT = "pending-replies"

    /** Under the receiver's ~60 s; Dart needs a few seconds to connect and send. */
    const val WAIT_MS = 25_000L

    /** Dart in the current engine listens for `reply`. */
    @Volatile
    var dartReady = false

    private val lock = Any()
    private val waiting = ConcurrentHashMap<String, CountDownLatch>()
    private val outcomes = ConcurrentHashMap<String, String>()

    private fun read(ctx: Context): JSONArray =
        try {
            SecureStore(ctx).read(ACCOUNT)?.let { JSONArray(it) } ?: JSONArray()
        } catch (_: Exception) {
            JSONArray()
        }

    private fun write(ctx: Context, list: JSONArray) {
        val store = SecureStore(ctx)
        if (list.length() == 0) store.delete(ACCOUNT) else store.write(ACCOUNT, list.toString())
    }

    fun add(ctx: Context, reply: JSONObject) = synchronized(lock) {
        write(ctx, read(ctx).put(reply))
    }

    private fun remove(ctx: Context, id: String) = synchronized(lock) {
        val list = read(ctx)
        val keep = JSONArray()
        for (i in 0 until list.length()) {
            val o = list.optJSONObject(i) ?: continue
            if (o.optString("id") != id) keep.put(o)
        }
        write(ctx, keep)
    }

    /** Dart started (in any engine): every reply waiting for it, forgotten here. */
    fun take(ctx: Context): List<Map<String, String>> = synchronized(lock) {
        dartReady = true
        val list = read(ctx)
        write(ctx, JSONArray())
        (0 until list.length()).mapNotNull { list.optJSONObject(it) }.map {
            mapOf("id" to it.optString("id"), "chatId" to it.optString("chatId"), "text" to it.optString("text"))
        }
    }

    /** Dart's `replyDone`. */
    fun done(id: String, outcome: String) {
        outcomes[id] = outcome
        waiting.remove(id)?.countDown()
    }

    /** The screen's engine is gone (no shared one): the next reply starts one. */
    fun engineGone() {
        dartReady = false
    }

    /** Hand [reply] to Dart now if it listens (it then forgets the stored copy). */
    private fun offer(ctx: Context, reply: JSONObject) {
        val app = ctx.applicationContext
        val id = reply.optString("id")
        MainActivity.onMain {
            val sent = dartReady && PushBridge.reply(
                mapOf("id" to id, "chatId" to reply.optString("chatId"), "text" to reply.optString("text")),
            ) { taken -> if (taken) remove(app, id) }
            if (!sent) SinhronApplication.ensureEngine(app)
        }
    }

    /** From [ReplyReceiver] (a background thread): store, hand over, wait. */
    fun handle(ctx: Context, chatId: String, title: String, text: String) {
        val id = UUID.randomUUID().toString()
        val reply = JSONObject().put("id", id).put("chatId", chatId).put("text", text)
        val latch = CountDownLatch(1)
        waiting[id] = latch
        add(ctx, reply)
        offer(ctx, reply)
        try {
            latch.await(WAIT_MS, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {}
        waiting.remove(id)
        when (outcomes.remove(id)) {
            "sent" -> Notifications.cancelChat(ctx, chatId)
            "failed" -> Notifications.chatMessage(ctx, chatId, title, ctx.getString(R.string.reply_failed), reply = false)
            // Queued in the chat, or still on its way / waiting here for Dart.
            else -> Notifications.chatMessage(ctx, chatId, title, ctx.getString(R.string.reply_later), reply = false)
        }
    }
}

/** The "Reply" action of a chat's notification (`Notifications.chatMessage`). */
class ReplyReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != NotificationReplies.ACTION_REPLY) return
        val chatId = intent.getStringExtra(Notifications.EXTRA_CHAT_ID) ?: return
        val title = intent.getStringExtra(NotificationReplies.EXTRA_TITLE) ?: context.getString(R.string.app_name)
        val text = RemoteInput.getResultsFromIntent(intent)
            ?.getCharSequence(NotificationReplies.KEY_TEXT)?.toString()?.trim().orEmpty()
        if (text.isEmpty()) {
            // Nothing typed: take the spinner off the notification.
            Notifications.cancelChat(context, chatId)
            return
        }
        val app = context.applicationContext
        val pending = goAsync()
        Thread {
            try {
                NotificationReplies.handle(app, chatId, title, text)
            } finally {
                pending.finish()
            }
        }.start()
    }
}
