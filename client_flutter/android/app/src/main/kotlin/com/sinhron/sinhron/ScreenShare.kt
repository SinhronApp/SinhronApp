// ADR-061 — showing the screen in a call: the Android side of
// `dev.sinhron/screen_share` (`lib/features/calls/call_screen_share.dart`).
//
// Android 14 rules for MediaProjection: the person agrees first (the system
// dialog — flutter_webrtc's `requestCapturePermission`), then a foreground
// service of type mediaProjection must be running, and only then may the
// capture start. So Dart calls `start` between the two and waits for the
// service to be in the foreground before it creates the screen track.
// The service's notification says "You're sharing your screen" with a Stop
// button (→ `onStop` to Dart, which unpublishes the track and calls `stop`).

package com.sinhron.sinhron

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

object ScreenShareBridge {
    const val ACTION_STOP = "com.sinhron.sinhron.SCREEN_SHARE_STOP"
    private const val READY_TIMEOUT_MS = 3_000L

    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())

    /** `start` waiting for the service to reach the foreground. */
    private var pending: MethodChannel.Result? = null
    private val timeout = Runnable { answer(false) }

    fun attach(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        val ch = MethodChannel(messenger, "dev.sinhron/screen_share")
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    answer(false) // a start still waiting is superseded
                    pending = result
                    main.postDelayed(timeout, READY_TIMEOUT_MS)
                    try {
                        // Status 223 (crash on "Show screen"): not
                        // startForegroundService — a service started that
                        // way that fails startForeground or is stopped
                        // first makes Android kill the whole app. The app
                        // is on screen here, so a plain start is allowed.
                        app.startService(Intent(app, ScreenShareService::class.java))
                    } catch (_: Exception) {
                        answer(false)
                    }
                }
                "stop" -> {
                    answer(false)
                    app.stopService(Intent(app, ScreenShareService::class.java))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        channel = ch
    }

    /** The service is in the foreground (or couldn't get there). */
    fun answer(ok: Boolean) {
        main.removeCallbacks(timeout)
        val r = pending ?: return
        pending = null
        r.success(ok)
    }

    /** "Stop" on the notification. */
    fun stopTapped() {
        main.post { channel?.invokeMethod("onStop", null) }
    }
}

class ScreenShareStopReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ScreenShareBridge.ACTION_STOP) ScreenShareBridge.stopTapped()
    }
}

/** Runs while the screen is shown — required by Android for MediaProjection. */
class ScreenShareService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION else 0
        try {
            ServiceCompat.startForeground(this, ID, notification(), type)
            ScreenShareBridge.answer(true)
        } catch (_: Exception) {
            // No consent yet (Android 14 refuses the type) or not allowed now.
            ScreenShareBridge.answer(false)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun notification(): Notification {
        Notifications.ensureChannels(this)
        val stop = PendingIntent.getBroadcast(
            this,
            40,
            Intent(this, ScreenShareStopReceiver::class.java).setAction(ScreenShareBridge.ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val open = PendingIntent.getActivity(
            this,
            41,
            Intent(this, MainActivity::class.java).apply {
                action = Notifications.ACTION_SHOW_CALL
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, Notifications.CH_ONGOING)
            .setSmallIcon(R.drawable.ic_stat_sinhron)
            .setContentTitle(getString(R.string.screen_share_on))
            .setContentText(getString(R.string.screen_share_text))
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(0, getString(R.string.screen_share_stop), stop)
            .build()
    }

    companion object {
        private const val ID = 7_061
    }
}
