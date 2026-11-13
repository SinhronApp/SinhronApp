// ADR-040 — notifications drawn by Sinhron itself (no Google services):
// "New message" when a UnifiedPush note arrives, the incoming-call
// notification (full screen on the lock screen, Answer / Decline), and the
// ongoing-call one that keeps a call alive in the background.
//
// Like iOS (ADR-038/039): no text, no chat, no caller from the server — the
// caller's name appears once the app has the invite.
//
// ADR-066 — a chat's notification opens that chat, and may carry "Reply"
// (`NotificationReply.kt`).

package com.sinhron.sinhron

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.app.RemoteInput
import androidx.core.content.ContextCompat

object Notifications {
    const val CH_MESSAGES = "messages"
    /** ADR-071 (amended) — "New message request": no sound, no pop-up. */
    const val CH_REQUESTS = "requests"
    const val CH_CALLS = "calls"
    const val CH_ONGOING = "ongoing_call"
    const val ID_MESSAGE = 1
    const val ID_CALL = 2
    const val ID_ONGOING = 3
    const val ID_KEEPALIVE = 4
    const val CH_KEEPALIVE = "keep_alive"
    const val EXTRA_CHAT_ID = "chat_id"

    const val ACTION_OPEN_FROM_PUSH = "com.sinhron.sinhron.OPEN_FROM_PUSH"
    const val ACTION_SHOW_CALL = "com.sinhron.sinhron.SHOW_CALL"
    const val ACTION_ANSWER = "com.sinhron.sinhron.ANSWER"
    const val ACTION_DECLINE = "com.sinhron.sinhron.DECLINE"
    const val EXTRA_CALL_ID = "call_id"

    fun ensureChannels(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CH_MESSAGES, ctx.getString(R.string.ch_messages), NotificationManager.IMPORTANCE_HIGH),
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_CALLS, ctx.getString(R.string.ch_calls), NotificationManager.IMPORTANCE_HIGH).apply {
                setSound(
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
                    AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE).build(),
                )
                enableVibration(true)
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_ONGOING, ctx.getString(R.string.ch_ongoing), NotificationManager.IMPORTANCE_LOW),
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_REQUESTS, ctx.getString(R.string.ch_requests), NotificationManager.IMPORTANCE_LOW),
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_KEEPALIVE, ctx.getString(R.string.ch_keepalive), NotificationManager.IMPORTANCE_MIN),
        )
    }

    fun allowed(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun activity(
        ctx: Context,
        action: String,
        callId: String? = null,
        request: Int,
        chatId: String? = null,
    ): PendingIntent {
        val i = Intent(ctx, MainActivity::class.java).apply {
            this.action = action
            callId?.let { putExtra(EXTRA_CALL_ID, it) }
            chatId?.let { putExtra(EXTRA_CHAT_ID, it) }
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        return PendingIntent.getActivity(ctx, request, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /** "New message" — one notification, replaced by the next (badge = [unread]). */
    fun newMessage(ctx: Context, unread: Int) {
        if (!allowed(ctx)) return
        ensureChannels(ctx)
        val n = NotificationCompat.Builder(ctx, CH_MESSAGES)
            .setSmallIcon(R.drawable.ic_stat_sinhron)
            .setContentTitle(ctx.getString(R.string.app_name))
            .setContentText(ctx.getString(R.string.new_message))
            .setNumber(unread)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(activity(ctx, ACTION_OPEN_FROM_PUSH, request = 10))
            .build()
        NotificationManagerCompat.from(ctx).notify(ID_MESSAGE, n)
    }

    /** ADR-057 — the app drew the message itself: drop the plain one. */
    fun cancelNewMessage(ctx: Context) = NotificationManagerCompat.from(ctx).cancel(ID_MESSAGE)

    fun clearMessages(ctx: Context) {
        val nm = NotificationManagerCompat.from(ctx)
        nm.cancel(ID_MESSAGE)
        nm.cancel(TAG_CHAT, 0) // chat notifications are tagged per chat below
        nm.activeNotifications.filter { it.tag?.startsWith(TAG_CHAT) == true }.forEach { nm.cancel(it.tag, it.id) }
    }

    private const val TAG_CHAT = "chat:"

    /** ADR-040 fallback ("always connected", no ntfy): the app has the
     *  decrypted message, so the notification can say who and what — or
     *  just "New message" when previews are off (decided in Dart). One per
     *  chat; a tap opens that chat. */
    fun chatMessage(ctx: Context, chatId: String, title: String, body: String, reply: Boolean = false, quiet: Boolean = false) {
        if (!allowed(ctx)) return
        ensureChannels(ctx)
        // ADR-071 (amended) — [quiet]: a message request, on its silent channel.
        val b = NotificationCompat.Builder(ctx, if (quiet) CH_REQUESTS else CH_MESSAGES)
            .setSmallIcon(R.drawable.ic_stat_sinhron)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(if (quiet) NotificationCompat.PRIORITY_LOW else NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(activity(ctx, ACTION_OPEN_FROM_PUSH, request = chatId.hashCode(), chatId = chatId))
        // ADR-066 — decided in Dart: not with "show nothing", App Lock, a
        // request or someone blocked.
        if (reply && chatId.isNotEmpty()) b.addAction(replyAction(ctx, chatId, title))
        NotificationManagerCompat.from(ctx).notify(TAG_CHAT + chatId, 0, b.build())
    }

    /** ADR-066 — the reply went: the chat's notification goes. */
    fun cancelChat(ctx: Context, chatId: String) = NotificationManagerCompat.from(ctx).cancel(TAG_CHAT + chatId, 0)

    /** ADR-066 — "Reply" with a text field; only after the phone is unlocked. */
    private fun replyAction(ctx: Context, chatId: String, title: String): NotificationCompat.Action {
        val input = RemoteInput.Builder(NotificationReplies.KEY_TEXT)
            .setLabel(ctx.getString(R.string.reply_placeholder))
            .build()
        val i = Intent(ctx, ReplyReceiver::class.java).apply {
            action = NotificationReplies.ACTION_REPLY
            putExtra(EXTRA_CHAT_ID, chatId)
            putExtra(NotificationReplies.EXTRA_TITLE, title)
        }
        // Mutable: the system adds the typed text (an explicit, unexported receiver).
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
        val pi = PendingIntent.getBroadcast(ctx, 0x5200 + chatId.hashCode(), i, flags)
        return NotificationCompat.Action.Builder(R.drawable.ic_stat_sinhron, ctx.getString(R.string.reply), pi)
            .addRemoteInput(input)
            .setAllowGeneratedReplies(false)
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_REPLY)
            .setShowsUserInterface(false)
            .setAuthenticationRequired(true)
            .build()
    }

    /** The quiet notification of the "always connected" service. */
    fun keepAlive(ctx: Context) =
        NotificationCompat.Builder(ctx, CH_KEEPALIVE)
            .also { ensureChannels(ctx) }
            .setSmallIcon(R.drawable.ic_stat_sinhron)
            .setContentTitle(ctx.getString(R.string.app_name))
            .setContentText(ctx.getString(R.string.keepalive_text))
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setContentIntent(activity(ctx, ACTION_OPEN_FROM_PUSH, request = 40))
            .build()

    /** Incoming call: full screen on the lock screen, Answer / Decline. */
    fun incomingCall(ctx: Context, callId: String, name: String, video: Boolean) {
        if (!allowed(ctx)) return
        ensureChannels(ctx)
        val decline = PendingIntent.getBroadcast(
            ctx, 21,
            Intent(ctx, CallActionReceiver::class.java).apply {
                action = ACTION_DECLINE
                putExtra(EXTRA_CALL_ID, callId)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val answer = activity(ctx, ACTION_ANSWER, callId, 22)
        val caller = Person.Builder().setName(name).setImportant(true).build()
        val n = NotificationCompat.Builder(ctx, CH_CALLS)
            .setSmallIcon(R.drawable.ic_stat_sinhron)
            .setContentTitle(name)
            .setContentText(ctx.getString(if (video) R.string.incoming_video else R.string.incoming_audio))
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setOngoing(true)
            .setAutoCancel(false)
            .setTimeoutAfter(CallBridge.UNCLAIMED_TIMEOUT_MS)
            .setFullScreenIntent(activity(ctx, ACTION_SHOW_CALL, callId, 23), true)
            .setStyle(NotificationCompat.CallStyle.forIncomingCall(caller, decline, answer))
            .build()
        NotificationManagerCompat.from(ctx).notify(ID_CALL, n)
    }

    fun cancelCall(ctx: Context) = NotificationManagerCompat.from(ctx).cancel(ID_CALL)

    /** The notification of the foreground service that keeps a call running. */
    fun ongoingCall(ctx: Context, name: String, video: Boolean) =
        NotificationCompat.Builder(ctx, CH_ONGOING)
            .also { ensureChannels(ctx) }
            .setSmallIcon(R.drawable.ic_stat_sinhron)
            .setContentTitle(name)
            .setContentText(ctx.getString(if (video) R.string.ongoing_video else R.string.ongoing_audio))
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setContentIntent(activity(ctx, ACTION_SHOW_CALL, request = 30))
            .build()
}
