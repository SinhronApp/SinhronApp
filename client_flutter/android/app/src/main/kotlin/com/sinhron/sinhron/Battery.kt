// ADR-057 — the phone's battery saver must not put Sinhron to sleep, or
// calls don't ring. Channel `dev.sinhron/battery`:
//   status()        {exempt, samsung, gms}: battery optimisation off for
//                   Sinhron? a Samsung (its own "sleeping apps" lists)?
//                   Google services (FCM) there?
//   askExempt({samsungHint})  the system "Let the app always run in
//                   background?" dialog (once, on first run — Dart decides
//                   when); on a Samsung first a plain-words note with a
//                   button to "Never sleeping apps" (it waits under the
//                   system dialog)
//   openSamsung()   Samsung's "Never sleeping apps" list; if this One UI
//                   has no such screen, its battery screen; else the app's
//                   own settings page (Battery → Unrestricted). True when
//                   something opened.
//   openApp()       the app's settings page (notifications refused for good)

package com.sinhron.sinhron

import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

object Battery {
    fun exempt(ctx: Context): Boolean =
        (ctx.getSystemService(Context.POWER_SERVICE) as PowerManager).isIgnoringBatteryOptimizations(ctx.packageName)

    fun samsung(): Boolean = Build.MANUFACTURER.equals("samsung", ignoreCase = true)

    fun attach(ctx: Context, messenger: BinaryMessenger, activity: MainActivity?) {
        val app = ctx.applicationContext
        MethodChannel(messenger, "dev.sinhron/battery").setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(mapOf("exempt" to exempt(app), "samsung" to samsung(), "gms" to Fcm.available(app)))
                "askExempt" -> {
                    if (activity != null && call.argument<Boolean>("samsungHint") == true && samsung()) samsungNote(activity)
                    result.success(activity != null && askExempt(activity))
                }
                "openSamsung" -> result.success(openSamsung(activity ?: app))
                "openApp" -> result.success(start(activity ?: app, Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${app.packageName}"))))
                else -> result.notImplemented()
            }
        }
    }

    /** We spread as an APK, not through Google Play: asking directly is fine. */
    @SuppressLint("BatteryLife")
    private fun askExempt(ctx: Context): Boolean {
        if (exempt(ctx)) return true
        return start(ctx, Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${ctx.packageName}")))
    }

    private fun samsungNote(activity: MainActivity) {
        android.app.AlertDialog.Builder(activity)
            .setTitle(R.string.samsung_title)
            .setMessage(R.string.samsung_text)
            .setPositiveButton(R.string.samsung_open) { _, _ -> openSamsung(activity) }
            .setNegativeButton(R.string.samsung_later, null)
            .show()
    }

    private fun openSamsung(ctx: Context): Boolean {
        val lool = "com.samsung.android.lool"
        val tries = listOf(
            // One UI 3+: Settings → Battery → Background usage limits →
            // Never sleeping apps (activity_type 2; 0/1 are the sleeping lists).
            Intent("com.samsung.android.sm.ACTION_OPEN_CHECKABLE_LISTACTIVITY").setPackage(lool).putExtra("activity_type", 2),
            Intent().setComponent(ComponentName(lool, "com.samsung.android.sm.battery.ui.BatteryActivity")),
            Intent().setComponent(ComponentName(lool, "com.samsung.android.sm.ui.battery.BatteryActivity")),
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${ctx.packageName}")),
        )
        return tries.any { start(ctx, it) }
    }

    private fun start(ctx: Context, i: Intent): Boolean = try {
        if (ctx !is android.app.Activity) i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(i)
        true
    } catch (_: Exception) {
        false
    }
}
