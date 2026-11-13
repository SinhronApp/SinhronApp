package com.sinhron.sinhron

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** The native half of "Report a problem" (owner, 2026-10-22): what the push
 *  and call receivers did while the app may not have been running — the
 *  part the Dart journal (lib/core/diag_log.dart) can't see. One line per
 *  event, "ISO-time text", in `files/diag-native.log` (the app's
 *  Application Support directory); cut to its newer half past 128 KB.
 *  Never message text, names or keys. */
object DiagNative {
    private const val FILE = "diag-native.log"
    private const val MAX_BYTES = 128 * 1024

    private val time = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }

    @Synchronized
    fun log(ctx: Context, text: String) {
        try {
            val f = File(ctx.filesDir, FILE)
            f.appendText("${time.format(Date())} [android] $text\n")
            if (f.length() > MAX_BYTES) {
                val lines = f.readLines()
                f.writeText(lines.drop(lines.size / 2).joinToString("\n", postfix = "\n"))
            }
        } catch (_: Exception) {
            // A journal must never break a push.
        }
    }
}
