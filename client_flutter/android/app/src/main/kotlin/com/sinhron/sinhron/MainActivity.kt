// Android entry point (ADR-040). FlutterFragmentActivity because
// `local_auth` needs one. Wires the native channels the Dart code shares with
// iOS: keychain (SecureStore), qrscan (QrScanActivity), push (UnifiedPush),
// callkit (call notifications), badge (Android draws badges from
// notifications — `set` does nothing), share (ADR-060, from ShareActivity),
// passwords (ADR-059, Credential Manager),
// update (self-update, ADR-058), privacy (audit storage-devices:8 / :19 —
// lib/core/screen_privacy.dart).

package com.sinhron.sinhron

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.view.WindowManager
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    companion object {
        /** In front right now (no system notification for messages then). */
        @Volatile
        var visible = false

        private val main = Handler(Looper.getMainLooper())

        /** This screen, so the end of a call can take it off the lock screen. */
        private var current: java.lang.ref.WeakReference<MainActivity>? = null

        /** A call ended: no longer shown over the lock screen. */
        fun callOver() = onMain { if (!CallBridge.live()) current?.get()?.overLock(false) }

        fun onMain(block: () -> Unit) {
            if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post(block)
        }

        private const val PREFS = "sinhron_push"

        fun askedNotifications(ctx: Context) =
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("asked_notifications", false)
    }

    private var pendingQr: MethodChannel.Result? = null
    private var screenshotChannel: MethodChannel? = null

    /** ADR-030 on Android 14+: the system tells us a screenshot was taken. */
    private val screenCapture: Any? =
        if (Build.VERSION.SDK_INT >= 34) Activity.ScreenCaptureCallback { screenshotChannel?.invokeMethod("shot", null) } else null
    private var pendingNotif: ((Boolean) -> Unit)? = null

    /** The 24 words are on the screen; App Lock hides the app in Recents;
     *  the app is in the background. */
    private var wordsShown = false
    private var hideRecents = false
    private var inBackground = false

    /** FLAG_SECURE (no screenshot, recording, screen share or Recents
     *  picture) while the words are shown — and, before Android 13 (no
     *  setRecentsScreenshotEnabled), while App Lock hides the app and it is
     *  in the background. */
    private fun applyPrivacy() {
        val secure = wordsShown || (hideRecents && inBackground && Build.VERSION.SDK_INT < 33)
        if (secure) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        if (Build.VERSION.SDK_INT >= 33) setRecentsScreenshotEnabled(!hideRecents)
    }

    private val qrLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        pendingQr?.success(r.data?.getStringExtra(QrScanActivity.EXTRA_TEXT))
        pendingQr = null
    }

    /** ADR-073 — "Sign in with Google" for the backup (BackupBridge.kt). */
    val driveAuthLauncher = registerForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { r ->
        BackupBridge.onAuthResult(this, r)
    }

    private val notifLauncher = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        pendingNotif?.invoke(granted)
        pendingNotif = null
    }

    /** Android 13+ asks; older versions allow notifications by default. */
    fun askNotifications(done: (Boolean) -> Unit) {
        if (Build.VERSION.SDK_INT < 33 || Notifications.allowed(this)) return done(true)
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean("asked_notifications", true).apply()
        pendingNotif = done
        notifLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        Notifications.ensureChannels(this)
        SecureStore.attach(this, messenger)
        // ADR-045 — which video codecs this phone encodes in hardware;
        // ADR-046 — how hot it is.
        MethodChannel(messenger, "dev.sinhron/media").setMethodCallHandler { call, result ->
            when (call.method) {
                "hardwareVideoEncoders" -> result.success(MediaCodecs.hardwareVideoEncoders())
                "thermalState" -> result.success(MediaCodecs.thermalState(applicationContext))
                // ADR-048 — a round video message: the centre square, side px.
                "squareVideo" -> {
                    val path = call.argument<String>("path")
                    if (path == null) result.success(null)
                    else VideoNotes.square(applicationContext, path, call.argument<Int>("side") ?: 480) { result.success(it) }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, "dev.sinhron/qrscan").setMethodCallHandler { call, result ->
            if (call.method != "scan") return@setMethodCallHandler result.notImplemented()
            if (pendingQr != null) return@setMethodCallHandler result.error("busy", "scanner already open", null)
            pendingQr = result
            qrLauncher.launch(Intent(this, QrScanActivity::class.java))
        }
        MethodChannel(messenger, "dev.sinhron/badge").setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermission" -> askNotifications { result.success(it) }
                "set" -> result.success(null)
                else -> result.notImplemented()
            }
        }
        screenshotChannel = MethodChannel(messenger, "dev.sinhron/screenshot")
        MethodChannel(messenger, "dev.sinhron/privacy").setMethodCallHandler { call, result ->
            when (call.method) {
                "wordsShown" -> {
                    wordsShown = call.argument<Boolean>("on") == true
                    applyPrivacy()
                    result.success(null)
                }
                "hideRecents" -> {
                    hideRecents = call.argument<Boolean>("on") == true
                    applyPrivacy()
                    result.success(null)
                }
                "copySecret" -> {
                    val clip = ClipData.newPlainText("Sinhron", call.argument<String>("text") ?: "")
                    // ClipDescription.EXTRA_IS_SENSITIVE (Android 13+): no
                    // preview, not in the keyboard's clipboard history.
                    clip.description.extras = PersistableBundle().apply {
                        putBoolean("android.content.extra.IS_SENSITIVE", true)
                    }
                    (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(clip)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        PasswordsBridge.attach(this, messenger)
        PushBridge.attach(this, messenger, this)
        Battery.attach(this, messenger, this)
        LinksBridge.attach(messenger)
        ShareBridge.attach(this, messenger)
        CallBridge.attach(this, messenger)
        ScreenShareBridge.attach(this, messenger)
        NetworkWatch.attach(this, messenger)
        // ADR-058 — the app updates itself from our server.
        AppUpdate.attach(this, messenger)
        // ADR-073 — the chat backup's Google sign-in.
        BackupBridge.attach(this, messenger)
    }

    /** The shared engine outlives this screen: hand its channels back to
     *  screen-less handlers, none pointing at this activity. */
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        super.cleanUpFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "dev.sinhron/qrscan").setMethodCallHandler(null)
        MethodChannel(messenger, "dev.sinhron/badge").setMethodCallHandler(null)
        MethodChannel(messenger, PasswordsBridge.CHANNEL).setMethodCallHandler(null)
        MethodChannel(messenger, "dev.sinhron/privacy").setMethodCallHandler(null)
        BackupBridge.detach(messenger)
        screenshotChannel = null
        SinhronApplication.attachHeadless(applicationContext, messenger)
    }

    /** The engine kept by SinhronApplication outlives this screen (and the
     *  app's connection with it). */
    override fun getCachedEngineId(): String? =
        if (FlutterEngineCache.getInstance().contains(SinhronApplication.ENGINE_ID)) SinhronApplication.ENGINE_ID else null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Bug 2026-10-19 (a Samsung A40): the screen used
        // its own engine unless "always connected" was on when the process
        // started. Switched on later, swiping Sinhron away destroyed that
        // engine — all of Dart — while the connection, which lives in the
        // Rust core and the process (kept by the service), stayed up: the
        // server delivered calls and messages into it for 14 minutes, nobody
        // read them. Now the screen always uses the shared engine, so the
        // app's code lives as long as its process (before super.onCreate:
        // it picks the engine).
        SinhronApplication.ensureEngine(this)
        super.onCreate(savedInstanceState)
        current = java.lang.ref.WeakReference(this)
        // Recreated after the process was killed: that share was handled.
        if (savedInstanceState == null || intent?.action != ShareBridge.ACTION_SHARE_IN) handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handle(intent)
    }

    override fun onStart() {
        super.onStart()
        if (Build.VERSION.SDK_INT >= 34) {
            registerScreenCaptureCallback(mainExecutor, screenCapture as Activity.ScreenCaptureCallback)
        }
    }

    override fun onStop() {
        super.onStop()
        CallBridge.appHidden(this)
        if (!CallBridge.live()) overLock(false)
        if (Build.VERSION.SDK_INT >= 34) {
            unregisterScreenCaptureCallback(screenCapture as Activity.ScreenCaptureCallback)
        }
    }

    override fun onResume() {
        super.onResume()
        visible = true
        inBackground = false
        if (hideRecents) applyPrivacy()
        Notifications.clearMessages(this)
        CallBridge.appVisible(this)
    }

    override fun onPause() {
        // Before super: the Recents picture is taken while pausing.
        inBackground = true
        if (hideRecents) applyPrivacy()
        super.onPause()
        visible = false
    }

    override fun onDestroy() {
        super.onDestroy()
        // The shared engine stays; only if it was missing did this screen's
        // own engine go with it (ADR-057: the next push starts the shared one).
        if (!FlutterEngineCache.getInstance().contains(SinhronApplication.ENGINE_ID)) {
            PushWake.engineGone()
            NotificationReplies.engineGone()
        }
    }

    private fun handle(i: Intent?) {
        when (i?.action) {
            Intent.ACTION_VIEW -> LinksBridge.received(i.data)
            // ADR-060 — not again when reopened from Recents.
            ShareBridge.ACTION_SHARE_IN ->
                if ((i.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) == 0) ShareBridge.received(this, i)
            Notifications.ACTION_OPEN_FROM_PUSH -> PushBridge.opened(i.getStringExtra(Notifications.EXTRA_CHAT_ID))
            Notifications.ACTION_ANSWER, Notifications.ACTION_SHOW_CALL -> {
                // Over the lock screen only while a call rings or is on
                // (audit storage-devices:4): such an intent from another
                // app, or a stale notification, gets the plain app; the flag
                // goes when the call ends (callOver, onStop).
                if (CallBridge.live()) overLock(true)
                val id = i.getStringExtra(Notifications.EXTRA_CALL_ID)
                if (i.action == Notifications.ACTION_ANSWER && id != null) CallBridge.answerTapped(this, id)
            }
        }
    }

    private fun overLock(on: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(on)
            setTurnScreenOn(on)
        }
    }
}
