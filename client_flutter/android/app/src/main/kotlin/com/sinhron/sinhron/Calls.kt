// ADR-040 — calls on Android: the Android side of `dev.sinhron/callkit`
// (`lib/features/calls/callkit_bridge.dart`), same contract and the same
// "claim" logic as iOS CallKit (ADR-039):
//   - a UnifiedPush call note shows the incoming-call notification at once
//     ("Sinhron"); the app starts, connects and gets the invite again; Dart's
//     reportIncoming claims it (name of the chat), and an Answer / Decline
//     tapped before that is handed over;
//   - unclaimed after UNCLAIMED_TIMEOUT_MS (the call ended) or dismissed by
//     Dart (blocked, a request, calls off) → the notification goes;
//   - startCall / an answered call keep a foreground service (microphone,
//     camera for video) so the call survives the app going to background;
//   - one ringing UI (owner, 2026-10-18 — the notification and the app's
//     screen both came up): the app's own screen while it's in front (even
//     for a call a push announced), the notification otherwise.
//     `reportIncoming` returns which (true = the notification); the app
//     coming to the front takes over (`onShowIncoming`), going to the
//     background hands the call back to the notification.

package com.sinhron.sinhron

import android.Manifest
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

object CallBridge {
    const val UNCLAIMED_TIMEOUT_MS = 45_000L

    private var channel: MethodChannel? = null
    private var appContext: Context? = null
    private val main = Handler(Looper.getMainLooper())

    /** Shown from a push, not yet claimed by Dart. */
    private val unclaimed = mutableSetOf<String>()
    private val pendingAnswer = mutableSetOf<String>()
    private val pendingEnd = mutableSetOf<String>()
    /** Claimed by Dart and still ringing here: call id → (name, video). */
    private val ringing = mutableMapOf<String, Pair<String, Boolean>>()
    /** A call is on (started or answered) until Dart ends it. */
    private var inCall = false

    /** A call rings or is on: only then the app shows over the lock screen. */
    fun live() = inCall || ringing.isNotEmpty() || unclaimed.isNotEmpty()

    fun attach(context: Context, messenger: BinaryMessenger) {
        appContext = context.applicationContext
        val ch = MethodChannel(messenger, "dev.sinhron/callkit")
        ch.setMethodCallHandler { call, result ->
            val ctx = appContext ?: return@setMethodCallHandler result.success(false)
            val id = call.argument<String>("call_id") ?: ""
            val name = call.argument<String>("peer_name") ?: ctx.getString(R.string.app_name)
            val video = call.argument<Boolean>("video") ?: false
            when (call.method) {
                "startCall" -> {
                    inCall = true
                    CallService.start(ctx, name, video)
                    result.success(true)
                }
                "reportIncoming" -> result.success(reportIncoming(ctx, id, name, video))
                // Answered in the app's call screen: the full-screen
                // "incoming call" notification goes (owner, 2026-10-16 — it
                // stayed up over the live call); `startCall` follows once
                // the call connects.
                "answerCall" -> {
                    ringing.remove(id)
                    Notifications.cancelCall(ctx)
                    result.success(true)
                }
                // Status 223 — answered / declined on another of my devices:
                // the ring stops the same way (it rang on 45 s, and came back
                // when the app went to the background).
                "endCall", "endedElsewhere" -> {
                    ringing.remove(id)
                    unclaimed.remove(id)
                    forget(id)
                    Notifications.cancelCall(ctx)
                    CallService.stop(ctx)
                    inCall = false
                    MainActivity.callOver()
                    result.success(true)
                }
                "dismiss" -> {
                    if (unclaimed.remove(id)) Notifications.cancelCall(ctx)
                    forget(id)
                    MainActivity.callOver()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        channel = ch
    }

    /** True: the notification shows the call; false: the app's screen rings it. */
    private fun reportIncoming(ctx: Context, id: String, name: String, video: Boolean): Boolean {
        unclaimed.remove(id)
        if (pendingEnd.remove(id)) {
            // Declined on the notification before the app had the invite.
            Notifications.cancelCall(ctx)
            channel?.invokeMethod("onEnd", mapOf("call_id" to id))
            return true
        }
        if (pendingAnswer.remove(id)) {
            Notifications.cancelCall(ctx)
            inCall = true
            CallService.start(ctx, name, video)
            channel?.invokeMethod("onAccept", mapOf("call_id" to id))
            return true
        }
        ringing[id] = name to video
        // In the app the Flutter screen rings (a push's notification goes);
        // outside it, the notification (with the chat's name now).
        if (MainActivity.visible) {
            Notifications.cancelCall(ctx)
            return false
        }
        Notifications.incomingCall(ctx, id, name, video)
        return true
    }

    /** The app came to the front: its own screen takes over a ringing call. */
    fun appVisible(ctx: Context) {
        if (ringing.isEmpty()) return
        Notifications.cancelCall(ctx)
        for (id in ringing.keys) channel?.invokeMethod("onShowIncoming", mapOf("call_id" to id))
    }

    /** The app went to the background while a call rang in it: the notification again. */
    fun appHidden(ctx: Context) {
        for ((id, call) in ringing) Notifications.incomingCall(ctx, id, call.first, call.second)
    }

    /** A call note from UnifiedPush: ring now, wait for the app to claim it. */
    fun incomingFromPush(ctx: Context, id: String, video: Boolean) {
        if (id in ringing || id in unclaimed) return
        unclaimed.add(id)
        // The app is open: it rings the call itself once it has the invite.
        if (!MainActivity.visible) Notifications.incomingCall(ctx, id, ctx.getString(R.string.app_name), video)
        main.postDelayed({
            if (unclaimed.remove(id)) {
                Notifications.cancelCall(ctx)
                forget(id)
                MainActivity.callOver()
            }
        }, UNCLAIMED_TIMEOUT_MS)
    }

    /** "Answer" on the notification (MainActivity got the intent). */
    fun answerTapped(ctx: Context, id: String) {
        Notifications.cancelCall(ctx)
        if (id in ringing && channel != null) {
            ringing.remove(id)
            channel?.invokeMethod("onAccept", mapOf("call_id" to id))
        } else {
            pendingAnswer.add(id) // delivered when Dart claims it
        }
    }

    /** "Decline" on the notification. */
    fun declineTapped(ctx: Context, id: String) {
        Notifications.cancelCall(ctx)
        if (id in ringing && channel != null) {
            ringing.remove(id)
            MainActivity.onMain { channel?.invokeMethod("onEnd", mapOf("call_id" to id)) }
        } else if (unclaimed.remove(id)) {
            // The app may still claim it in this process: decline then.
            pendingEnd.add(id)
        }
        MainActivity.callOver()
    }

    private fun forget(id: String) {
        pendingAnswer.remove(id)
        pendingEnd.remove(id)
    }
}

/** "Decline" without opening the app. */
class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(Notifications.EXTRA_CALL_ID) ?: return
        if (intent.action == Notifications.ACTION_DECLINE) CallBridge.declineTapped(context, id)
    }
}

/** Keeps a call's microphone (and camera) working with the app in background. */
class CallService : Service() {
    companion object {
        private const val EXTRA_NAME = "name"
        private const val EXTRA_VIDEO = "video"

        fun start(ctx: Context, name: String, video: Boolean) {
            val i = Intent(ctx, CallService::class.java).putExtra(EXTRA_NAME, name).putExtra(EXTRA_VIDEO, video)
            try {
                ContextCompat.startForegroundService(ctx, i)
            } catch (_: Exception) {
                // Not allowed from the background on this Android: the call
                // still works while the app is open.
            }
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, CallService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /** The camera joined this call (a video call, or turned on mid-call):
     *  kept until the call ends — the service never drops back to mic only. */
    private var camera = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val name = intent?.getStringExtra(EXTRA_NAME) ?: getString(R.string.app_name)
        // Called again when the camera comes on mid-call (owner, 2026-10-18:
        // "the camera must not close when the call is minimised"): Android 14
        // gives a background app the camera only through a foreground
        // service of the camera type, started while the app is in front.
        camera = camera || (intent?.getBooleanExtra(EXTRA_VIDEO, false) ?: false)
        var mic = 0
        var cam = 0
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            if (granted(Manifest.permission.RECORD_AUDIO)) mic = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            if (camera && granted(Manifest.permission.CAMERA)) cam = ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        }
        val note = Notifications.ongoingCall(this, name, camera)
        try {
            ServiceCompat.startForeground(this, Notifications.ID_ONGOING, note, mic or cam)
        } catch (_: Exception) {
            // The camera type refused (started from the background): keep the
            // voice at least.
            try {
                ServiceCompat.startForeground(this, Notifications.ID_ONGOING, note, mic)
            } catch (_: Exception) {
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    private fun granted(p: String) = ContextCompat.checkSelfPermission(this, p) == PackageManager.PERMISSION_GRANTED
}
