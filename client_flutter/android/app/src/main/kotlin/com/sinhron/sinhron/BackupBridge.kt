package com.sinhron.sinhron

import android.content.Context
import android.net.ConnectivityManager
import androidx.activity.result.ActivityResult
import androidx.activity.result.IntentSenderRequest
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.Scope
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** ADR-073 — the chat backup on Android lives in Google Drive's app data
 *  folder (hidden in Drive, only this app sees it). The Drive calls are in
 *  Dart (lib/core/backup/cloud_store.dart, `DriveStore`); here only the one
 *  "Sign in with Google" — an access token for `drive.appdata` — and whether
 *  the network is metered (the daily backup waits for Wi-Fi).
 *
 *  Channel `dev.sinhron/backup`:
 *   - `driveToken {interactive}` → token, or null (not signed in / closed);
 *     non-interactive never shows anything and stays null after sign-out;
 *   - `driveSignOut` → forget it here (the backup stops);
 *   - `metered` → true on mobile data. */
object BackupBridge {
    const val CHANNEL = "dev.sinhron/backup"
    private const val SCOPE = "https://www.googleapis.com/auth/drive.appdata"
    private const val PREFS = "sinhron_backup"
    private const val KEY_CONNECTED = "drive_connected"

    private var pending: MethodChannel.Result? = null

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun connected(ctx: Context) = prefs(ctx).getBoolean(KEY_CONNECTED, false)
    private fun setConnected(ctx: Context, on: Boolean) = prefs(ctx).edit().putBoolean(KEY_CONNECTED, on).apply()

    fun attach(activity: MainActivity, messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "driveToken" -> token(activity, call.argument<Boolean>("interactive") == true, result)
                "driveSignOut" -> {
                    setConnected(activity, false)
                    result.success(true)
                }
                "metered" -> {
                    val cm = activity.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                    result.success(cm.isActiveNetworkMetered)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun detach(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(null)
    }

    private fun token(activity: MainActivity, interactive: Boolean, result: MethodChannel.Result) {
        // Signed out on purpose (or never in): no silent token.
        if (!interactive && !connected(activity)) return result.success(null)
        val request = AuthorizationRequest.builder().setRequestedScopes(listOf(Scope(SCOPE))).build()
        Identity.getAuthorizationClient(activity).authorize(request)
            .addOnSuccessListener { auth ->
                val intent = auth.pendingIntent
                if (auth.hasResolution() && intent != null) {
                    if (!interactive) return@addOnSuccessListener result.success(null)
                    if (pending != null) return@addOnSuccessListener result.error("busy", "sign-in already open", null)
                    pending = result
                    activity.driveAuthLauncher.launch(IntentSenderRequest.Builder(intent.intentSender).build())
                } else {
                    setConnected(activity, auth.accessToken != null)
                    result.success(auth.accessToken)
                }
            }
            .addOnFailureListener { e ->
                DiagNative.log(activity, "backup: google authorization failed (${e.javaClass.simpleName})")
                result.success(null)
            }
    }

    /** The account picker / consent screen came back. */
    fun onAuthResult(activity: MainActivity, r: ActivityResult) {
        val result = pending ?: return
        pending = null
        try {
            val data = r.data ?: throw IllegalStateException("no result")
            val auth = Identity.getAuthorizationClient(activity).getAuthorizationResultFromIntent(data)
            setConnected(activity, auth.accessToken != null)
            result.success(auth.accessToken)
        } catch (e: Exception) {
            DiagNative.log(activity, "backup: google sign-in closed (${e.javaClass.simpleName})")
            result.success(null)
        }
    }
}
