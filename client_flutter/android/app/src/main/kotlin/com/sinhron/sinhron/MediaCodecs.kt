package com.sinhron.sinhron

import android.content.Context
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.os.Build
import android.os.PowerManager

/**
 * ADR-045 — the video codecs this phone encodes in hardware: "h264",
 * "h265" (most phones since ~2017), "vp8"; "av1" on new flagships (not used
 * yet — livekit_client 2.7.0 leaves AV1 unencrypted). A software encoder
 * doesn't count: it costs heat and battery on a call.
 */
object MediaCodecs {
    private val names = mapOf(
        "video/avc" to "h264",
        "video/hevc" to "h265",
        "video/x-vnd.on2.vp8" to "vp8",
        "video/av01" to "av1",
    )

    fun hardwareVideoEncoders(): List<String> = try {
        MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            .filter { it.isEncoder && isHardware(it) }
            .flatMap { info -> info.supportedTypes.mapNotNull { names[it.lowercase()] } }
            .distinct()
    } catch (e: Exception) {
        emptyList()
    }

    /**
     * ADR-046 — the phone's heat on iOS's scale (0 nominal, 1 fair,
     * 2 serious, 3 critical), so the call steps its best picture down as it
     * heats up. Android 10+ reports it; older phones say 0.
     */
    fun thermalState(context: Context): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return 0
        val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return 0
        return when (pm.currentThermalStatus) {
            PowerManager.THERMAL_STATUS_NONE -> 0
            PowerManager.THERMAL_STATUS_LIGHT -> 1
            PowerManager.THERMAL_STATUS_MODERATE -> 2
            else -> 3
        }
    }

    private fun isHardware(info: MediaCodecInfo): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) return info.isHardwareAccelerated
        val n = info.name.lowercase()
        return !(n.startsWith("omx.google.") || n.startsWith("c2.android.") || n.contains(".sw."))
    }
}
