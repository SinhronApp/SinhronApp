// ADR-040 fallback — "always connected" for phones without a UnifiedPush
// distributor (no ntfy installed). A quiet foreground service keeps the app
// process alive; the Flutter engine is kept in FlutterEngineCache
// (SinhronApplication — every screen uses it since 2026-10-19, so it
// outlives the screen however the mode was switched on), and its server
// connection stays open — messages arrive at once and the app draws their
// notifications itself (it has them decrypted, so name and text, unless
// previews are off). Costs battery (less since 2026-10-18: a heartbeat every
// 120 s instead of 20 s while off screen, lib/core/background_connection.dart)
// and shows a permanent quiet notification. ADR-057: on by itself only when
// the phone has no other push (no Google push, no ntfy — `lib/core/push.dart`;
// with Google push working it stays off: the push wakes the app),
// back after the app is swiped away from recents (onTaskRemoved) and after a
// restart; Settings → Sounds & vibrations switches it.

package com.sinhron.sinhron

import android.app.AlarmManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import io.flutter.app.FlutterApplication
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.BinaryMessenger

class KeepAliveService : Service() {
    companion object {
        private const val PREFS = "sinhron_push"
        private const val KEY = "keep_alive"
        const val ACTION_RESTART = "com.sinhron.sinhron.KEEPALIVE_RESTART"

        fun enabled(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY, false)

        fun start(ctx: Context) {
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY, true).apply()
            try {
                ContextCompat.startForegroundService(ctx, Intent(ctx, KeepAliveService::class.java))
            } catch (_: Exception) {
                // Not allowed from the background: starts with the app next time.
            }
        }

        fun stop(ctx: Context) {
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY, false).apply()
            ctx.stopService(Intent(ctx, KeepAliveService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val type = if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING else 0
        try {
            ServiceCompat.startForeground(this, Notifications.ID_KEEPALIVE, Notifications.keepAlive(this), type)
        } catch (_: Exception) {
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    /** Swiped away from recents: some phones (Samsung among them) stop the
     *  service with the task. Come back in a second — from an alarm, the
     *  way Android lets a stopped service start again. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        if (!enabled(this)) return
        val again = PendingIntent.getBroadcast(
            this,
            0,
            Intent(this, KeepAliveBootReceiver::class.java).setAction(ACTION_RESTART),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val am = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val at = SystemClock.elapsedRealtime() + 1_000
        // Android 12+ starts a foreground service from the background only
        // from an exact alarm; without that permission the plain one (the
        // service is START_STICKY — the system brings it back too).
        if (Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms()) {
            am.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, again)
        } else {
            am.set(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, again)
        }
    }
}

/** Keeps one Flutter engine for the whole process (the screen's too), so
 *  closing the screen doesn't leave the app's connection without its code. */
class SinhronApplication : FlutterApplication() {
    companion object {
        const val ENGINE_ID = "main"

        /** The channels that work without a screen — registered before Dart
         *  starts (found on the emulator 2026-10-16: without the keychain
         *  channel the app booted into "Unlock Sinhron", key not found). */
        fun attachHeadless(ctx: Context, messenger: BinaryMessenger) {
            Notifications.ensureChannels(ctx)
            SecureStore.attach(ctx, messenger)
            PushBridge.attach(ctx, messenger, null)
            Battery.attach(ctx, messenger, null)
            CallBridge.attach(ctx, messenger)
            NetworkWatch.attach(ctx, messenger)
        }

        /** The shared engine — the one every screen uses (MainActivity),
         *  started with no screen if there is none yet ("always connected",
         *  or ADR-057 a push woke the app). Main thread. */
        fun ensureEngine(ctx: Context) {
            if (FlutterEngineCache.getInstance().contains(ENGINE_ID)) return
            val app = ctx.applicationContext
            val engine = FlutterEngine(app)
            attachHeadless(app, engine.dartExecutor.binaryMessenger)
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        }
    }

    override fun onCreate() {
        super.onCreate()
        // ADR-057 — before any push of this process is delivered.
        Fcm.initFromSaved(this)
        if (!KeepAliveService.enabled(this)) return
        ensureEngine(this)
        KeepAliveService.start(this)
    }
}

/** After a restart or an app update: [SinhronApplication.onCreate] already
 *  brought the engine and the service up (the process started for this
 *  broadcast); starting again is a no-op — kept in case the system delayed
 *  the start until the broadcast. Also the alarm after a swipe from recents
 *  ([KeepAliveService.onTaskRemoved]). Nothing when "always connected" is off. */
class KeepAliveBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (KeepAliveService.enabled(context)) KeepAliveService.start(context)
    }
}
