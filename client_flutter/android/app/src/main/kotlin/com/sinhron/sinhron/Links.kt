// ADR-043 — invite links into the app (Android side of `dev.sinhron/links`).
//
//   https://<server>/join#…   App Link (autoVerify; the server's assetlinks.json)
//   sinhron://join#…          the /join page's "Open in the app" button
//   https://<server>/i/<id>#… a short link (resolved in Rust); sinhron://i/<server>/<id>#… its page's button
//
// Dart → `takeInitial()` (a link that started the app before Dart listened);
// native → `link(url)`. Pending until Dart accepted it.

package com.sinhron.sinhron

import android.net.Uri
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

object LinksBridge {
    private var channel: MethodChannel? = null
    private var pending: String? = null

    fun attach(messenger: BinaryMessenger) {
        val ch = MethodChannel(messenger, "dev.sinhron/links")
        ch.setMethodCallHandler { call, result ->
            if (call.method != "takeInitial") return@setMethodCallHandler result.notImplemented()
            result.success(pending)
            pending = null
        }
        channel = ch
    }

    fun received(uri: Uri?) {
        if (uri == null || !isInvite(uri)) return
        val s = uri.toString()
        pending = s
        channel?.invokeMethod(
            "link",
            s,
            object : MethodChannel.Result {
                override fun success(r: Any?) {
                    if (pending == s) pending = null
                }
                override fun error(code: String, msg: String?, details: Any?) {}
                override fun notImplemented() {}
            },
        )
    }

    private fun isInvite(u: Uri): Boolean = when (u.scheme?.lowercase()) {
        "https" -> u.path == "/join" || u.path?.startsWith("/join/") == true || u.path?.startsWith("/i/") == true
        "sinhron" -> u.host?.lowercase() == "join" || u.host?.lowercase() == "i"
        else -> false
    }
}
