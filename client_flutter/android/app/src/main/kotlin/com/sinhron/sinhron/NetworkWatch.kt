// Battery 2026-10-18 — tells Dart (channel `dev.sinhron/network`, method
// `changed`) when the phone's default network changes (Wi-Fi ↔ mobile, Wi-Fi
// back after a drop). The server connection's socket belongs to the network
// that went away; with the long background heartbeat (120 s) it would take
// up to two minutes to notice, so the app reconnects at once instead
// (`watchNetworkChanges` in lib/core/background_connection.dart →
// `netNetworkChanged`). Attached with the engine, so it works with no screen
// ("always connected", ADR-040) too.

package com.sinhron.sinhron

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

object NetworkWatch {
    private var channel: MethodChannel? = null
    private var registered = false
    /** The default network last seen (kept after it's lost, so the next one
     *  counts as a change). */
    private var current: Network? = null

    fun attach(context: Context, messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, "dev.sinhron/network").also { ch ->
            // Status 183 — is a VPN on? Calls then take the reserve path.
            ch.setMethodCallHandler { call, result ->
                if (call.method == "vpnActive") result.success(vpnActive(context)) else result.notImplemented()
            }
        }
        if (registered) return
        val cm = context.applicationContext.getSystemService(ConnectivityManager::class.java) ?: return
        try {
            cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    val previous = current
                    current = network
                    // The first callback only says what the network is now.
                    if (previous != null && previous != network) {
                        MainActivity.onMain { channel?.invokeMethod("changed", null) }
                    }
                }
            })
            registered = true
        } catch (_: Exception) {
            // No callback (a restricted profile): the heartbeat still notices.
        }
    }

    /** Status 183 — the default network runs through a VPN. */
    fun vpnActive(context: Context): Boolean = try {
        val cm = context.applicationContext.getSystemService(ConnectivityManager::class.java)
        val caps = cm?.getNetworkCapabilities(cm.activeNetwork)
        caps?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN) == true
    } catch (_: Exception) {
        false
    }
}
