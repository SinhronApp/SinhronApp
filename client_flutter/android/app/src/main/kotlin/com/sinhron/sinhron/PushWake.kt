// ADR-057 — a push woke the phone: open the app's own connection for a few
// seconds, so it fetches what came, draws "name: text" (it has the message
// decrypted) and, for a call, gets the invite (the caller's name; Decline
// reaches them). Then Dart closes the connection again
// (`lib/core/push_wake.dart`) and the server goes back to pushing.
//
// The Flutter engine: the shared one SinhronApplication keeps (the screen
// uses it too, since 2026-10-19), started here with no screen if the
// process has none yet. Dart asks `takeWake` once it is up (a wake that came
// while it was starting), afterwards gets `wake`, and answers `wakeDone`.
//
// The FCM thread waits for that (≤ [WAIT_MS]): while it waits the process
// counts as running a service, so Android doesn't freeze it mid-fetch.

package com.sinhron.sinhron

import android.content.Context
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

object PushWake {
    /** FCM gives a high-priority message ~20 s; the app needs ~3–6, a
     *  cold engine start more — status 223: at 9 s a killed app often
     *  showed the plain "New message" instead of the decrypted preview. */
    const val WAIT_MS = 15_000L

    /** Dart in the current engine listens for `wake`. */
    @Volatile
    private var dartReady = false

    /** A wake that came while Dart was starting. */
    @Volatile
    private var pending = false

    /** Dart drew a message notification since the last wake. */
    @Volatile
    private var shown = false

    @Volatile
    private var latch: CountDownLatch? = null

    /** Dart started (in any engine): was there a wake for it? */
    fun take(): Boolean {
        dartReady = true
        val p = pending
        pending = false
        return p
    }

    /** Dart fetched what there was (or gave up). [handled]: a message
     *  reached it (bug 2026-10-19 — with the connection already open it
     *  usually came down the socket before the push: the app drew it, or
     *  chose not to for a muted chat; no plain "New message" on top). */
    fun done(handled: Boolean = false) {
        if (handled) shown = true
        latch?.countDown()
    }

    /** Dart drew a notification itself (PushBridge `showMessage`). */
    fun shown() {
        shown = true
    }

    /** The screen's engine is gone (no shared one): the next wake starts one. */
    fun engineGone() {
        dartReady = false
    }

    /** Wake the connection; wait ≤ [waitMs] (never on the main thread).
     *  True when the app drew a message notification meanwhile. */
    fun wake(ctx: Context, waitMs: Long): Boolean {
        val l = CountDownLatch(1)
        latch = l
        shown = false
        val app = ctx.applicationContext
        MainActivity.onMain {
            if (dartReady && PushBridge.wake()) return@onMain
            pending = true
            SinhronApplication.ensureEngine(app)
        }
        if (waitMs > 0) {
            try {
                l.await(waitMs, TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {}
        }
        return shown
    }
}
