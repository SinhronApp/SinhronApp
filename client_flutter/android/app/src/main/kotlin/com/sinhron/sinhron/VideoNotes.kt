package com.sinhron.sinhron

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.Presentation
import androidx.media3.effect.TextureOverlay
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import com.google.common.collect.ImmutableList
import java.io.File

/**
 * ADR-048 — a round video message: the centre square of a camera clip,
 * scaled to `side` px, black outside the inscribed circle, re-encoded by the
 * hardware H.264 encoder (~1 Mbit/s) into an .mp4 in the cache dir. `null` on
 * any failure — the app then tries once more and otherwise sends nothing
 * (never the uncropped clip — owner, 2026-10-19, privacy). The caller deletes
 * both files once the clip is in memory.
 * Runs on the main thread (Transformer needs a Looper); the work itself is
 * on Media3's own threads.
 */
@OptIn(markerClass = [UnstableApi::class])
object VideoNotes {
    fun square(context: Context, input: String, side: Int, done: (String?) -> Unit) {
        val out = File(context.cacheDir, "vnote-${System.nanoTime()}.mp4")
        try {
            val item = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(input))))
                .setEffects(
                    Effects(
                        emptyList(),
                        listOf(
                            Presentation.createForWidthAndHeight(side, side, Presentation.LAYOUT_SCALE_TO_FIT_WITH_CROP),
                            // After the square: only what the recorder saw
                            // in the round preview, not the corners.
                            OverlayEffect(ImmutableList.of<TextureOverlay>(BitmapOverlay.createStaticBitmapOverlay(cornerMask(side)))),
                        ),
                    ),
                )
                .build()
            val encoders = DefaultEncoderFactory.Builder(context.applicationContext)
                .setRequestedVideoEncoderSettings(VideoEncoderSettings.Builder().setBitrate(1_000_000).build())
                .build()
            Transformer.Builder(context.applicationContext)
                .setVideoMimeType(MimeTypes.VIDEO_H264)
                .setEncoderFactory(encoders)
                .addListener(object : Transformer.Listener {
                    override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                        done(out.path)
                    }

                    override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                        out.delete()
                        done(null)
                    }
                })
                .build()
                .start(item, out.path)
        } catch (e: Exception) {
            out.delete()
            done(null)
        }
    }

    /** Opaque black over a `side`×`side` frame except its inscribed circle. */
    fun cornerMask(side: Int): Bitmap {
        val bmp = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        canvas.drawColor(Color.BLACK)
        val hole = Paint(Paint.ANTI_ALIAS_FLAG).apply { xfermode = PorterDuffXfermode(PorterDuff.Mode.CLEAR) }
        canvas.drawCircle(side / 2f, side / 2f, side / 2f, hole)
        return bmp
    }
}
