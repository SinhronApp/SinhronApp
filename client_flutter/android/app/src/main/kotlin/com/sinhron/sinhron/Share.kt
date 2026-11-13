// ADR-060 — sharing into Sinhron from another app (Android side of
// `dev.sinhron/share`).
//
// ShareActivity is what the share menu starts (ACTION_SEND / SEND_MULTIPLE):
// it starts nothing of its own, hands the items to MainActivity in the
// app's own task (the shared engine never gets a second screen) and closes.
// MainActivity → ShareBridge copies each item into the cache
// (`share/<id>/`, HEIC / WebP → JPEG for the photo path) off the main
// thread, then Dart gets {id, text, files: [{path, name, mime, size}]}.
// Dart → `takeInitial()`, `finished(id)` (deletes the copies). Copies older
// than a day are swept when the engine attaches.

package com.sinhron.sinhron

import android.app.Activity
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/** The share menu's entry: forwards to MainActivity, never shows itself. */
class ShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val src = intent
        if (savedInstanceState == null && src != null &&
            (src.action == Intent.ACTION_SEND || src.action == Intent.ACTION_SEND_MULTIPLE)
        ) {
            val uris = ShareBridge.streams(src)
            val fwd = Intent(this, MainActivity::class.java).apply {
                action = ShareBridge.ACTION_SHARE_IN
                type = src.type
                putParcelableArrayListExtra(ShareBridge.EXTRA_URIS, ArrayList(uris))
                src.getCharSequenceExtra(Intent.EXTRA_TEXT)?.let { putExtra(Intent.EXTRA_TEXT, it.toString()) }
                src.getStringExtra(Intent.EXTRA_SUBJECT)?.let { putExtra(Intent.EXTRA_SUBJECT, it) }
                // The read grant goes along with the URIs in the clip.
                if (uris.isNotEmpty()) {
                    val clip = ClipData.newRawUri("", uris[0])
                    for (u in uris.drop(1)) clip.addItem(ClipData.Item(u))
                    clipData = clip
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            startActivity(fwd)
        }
        finish()
    }
}

object ShareBridge {
    const val ACTION_SHARE_IN = "com.sinhron.sinhron.SHARE_IN"
    const val EXTRA_URIS = "com.sinhron.sinhron.SHARE_URIS"

    /** Biggest single item copied (the app sends ≤95 MB; video is compressed first). */
    private const val MAX_COPY_BYTES = 2L * 1024 * 1024 * 1024

    private var channel: MethodChannel? = null

    /** Shares Dart hasn't taken yet (main thread only), oldest first. */
    private val pending = ArrayList<Map<String, Any>>()
    private val io = Executors.newSingleThreadExecutor()

    fun attach(activity: Context, messenger: BinaryMessenger) {
        val ctx = activity.applicationContext
        val ch = MethodChannel(messenger, "dev.sinhron/share")
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "takeInitial" -> result.success(pending.firstOrNull()?.also { pending.removeAt(0) })
                "finished" -> {
                    val id = call.arguments as? String
                    if (id != null) io.execute { dir(ctx, id)?.deleteRecursively() }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        channel = ch
        io.execute { sweep(ctx) }
        // Copied before this engine listened (a share that started the app).
        for (p in pending.toList()) deliver(p)
    }

    /** The items in a SEND / SEND_MULTIPLE intent. */
    @Suppress("DEPRECATION")
    fun streams(i: Intent): List<Uri> {
        val out = ArrayList<Uri>()
        if (i.action == Intent.ACTION_SEND_MULTIPLE) {
            i.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { out.addAll(it) }
        } else {
            (i.getParcelableExtra<android.os.Parcelable>(Intent.EXTRA_STREAM) as? Uri)?.let { out.add(it) }
        }
        val clip = i.clipData
        if (out.isEmpty() && clip != null) {
            for (k in 0 until clip.itemCount) clip.getItemAt(k).uri?.let { out.add(it) }
        }
        return out.distinct()
    }

    /** From MainActivity (ACTION_SHARE_IN): copy off the main thread, then hand over. */
    @Suppress("DEPRECATION")
    fun received(activity: Activity, i: Intent) {
        val ctx = activity.applicationContext
        val uris = i.getParcelableArrayListExtra<Uri>(EXTRA_URIS) ?: arrayListOf()
        val text = i.getStringExtra(Intent.EXTRA_TEXT) ?: ""
        val type = i.type
        val id = "a" + System.currentTimeMillis().toString(36) + (0..9999).random().toString(36)
        io.execute {
            val files = ArrayList<Map<String, Any>>()
            val folder = File(File(ctx.cacheDir, "share"), id)
            for ((n, u) in uris.withIndex()) {
                copy(ctx, u, type, folder, n)?.let { files.add(it) }
            }
            val share = mapOf("id" to id, "text" to text, "files" to files)
            MainActivity.onMain {
                pending.add(share)
                deliver(share)
            }
        }
    }

    private fun deliver(share: Map<String, Any>) {
        val ch = channel ?: return
        ch.invokeMethod(
            "share",
            share,
            object : MethodChannel.Result {
                override fun success(r: Any?) {
                    if (r == true) pending.remove(share)
                }
                override fun error(code: String, msg: String?, details: Any?) {}
                override fun notImplemented() {}
            },
        )
    }

    private fun dir(ctx: Context, id: String): File? {
        if (!id.matches(Regex("[a-z0-9]{1,40}"))) return null
        return File(File(ctx.cacheDir, "share"), id)
    }

    /** Copies left behind (the app was killed mid-share) go after a day. */
    private fun sweep(ctx: Context) {
        val root = File(ctx.cacheDir, "share")
        val old = System.currentTimeMillis() - 24 * 3600 * 1000L
        root.listFiles()?.forEach { if (it.lastModified() < old) it.deleteRecursively() }
    }

    /** One item into [folder]; null when it can't (or mustn't) be read. */
    private fun copy(ctx: Context, u: Uri, intentType: String?, folder: File, n: Int): Map<String, Any>? {
        // Only other apps' content: never a file:// path, never our own
        // providers (another app could point us at our own files).
        if (u.scheme != "content") return null
        val authority = u.authority ?: return null
        @Suppress("DEPRECATION")
        val owner = try { ctx.packageManager.resolveContentProvider(authority, 0)?.packageName } catch (_: Exception) { null }
        if (owner == ctx.packageName) return null
        val cr = ctx.contentResolver
        var name: String? = null
        var declared = -1L
        try {
            cr.query(u, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val si = c.getColumnIndex(OpenableColumns.SIZE)
                    if (ni >= 0 && !c.isNull(ni)) name = c.getString(ni)
                    if (si >= 0 && !c.isNull(si)) declared = c.getLong(si)
                }
            }
        } catch (_: Exception) {}
        if (declared > MAX_COPY_BYTES) return null
        var mime = (cr.getType(u) ?: intentType?.takeIf { !it.contains('*') } ?: "").lowercase()
        val base = safeName(name ?: u.lastPathSegment ?: "file$n")
        if (mime.isEmpty()) {
            mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(base.substringAfterLast('.', "").lowercase())
                ?: "application/octet-stream"
        }
        folder.mkdirs()
        var out = File(folder, "${n}_$base")
        try {
            cr.openInputStream(u)?.use { input ->
                out.outputStream().use { o ->
                    val buf = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val r = input.read(buf)
                        if (r < 0) break
                        total += r
                        if (total > MAX_COPY_BYTES) throw IllegalStateException("too large")
                        o.write(buf, 0, r)
                    }
                }
            } ?: return null
        } catch (_: Exception) {
            out.delete()
            return null
        }
        var outName = base
        // The photo path takes JPEG / PNG; other pictures become a JPEG
        // (GIFs stay files so they keep moving).
        if (mime.startsWith("image/") && mime !in setOf("image/jpeg", "image/png", "image/gif")) {
            val jpeg = File(folder, "${n}_${base.substringBeforeLast('.')}.jpg")
            if (toJpeg(out, jpeg)) {
                out.delete()
                out = jpeg
                outName = jpeg.name.removePrefix("${n}_")
                mime = "image/jpeg"
            }
        }
        return mapOf("path" to out.absolutePath, "name" to outName, "mime" to mime, "size" to out.length())
    }

    private fun toJpeg(src: File, dst: File): Boolean = try {
        val bmp: Bitmap? = if (Build.VERSION.SDK_INT >= 28) {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(src)) { d, info, _ ->
                // The core re-encodes at ≤2048 px anyway.
                val side = maxOf(info.size.width, info.size.height)
                if (side > 2048) d.setTargetSampleSize(maxOf(1, side / 2048))
                d.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
        } else {
            BitmapFactory.decodeFile(src.absolutePath)
        }
        if (bmp == null) false else {
            dst.outputStream().use { bmp.compress(Bitmap.CompressFormat.JPEG, 92, it) }
            bmp.recycle()
            true
        }
    } catch (_: Throwable) {
        dst.delete()
        false
    }

    private fun safeName(n: String): String {
        val s = n.substringAfterLast('/').replace(Regex("[\\\\:*?\"<>|\\u0000-\\u001f]"), "_").trim().trimStart('.')
        return (if (s.isEmpty()) "file" else s).take(120)
    }
}
