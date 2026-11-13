// Tech-debt 4.2 on Android — the QR scanner behind `dev.sinhron/qrscan`
// (`lib/core/qr_scan.dart`): CameraX preview + ZXing core decoding. No ML Kit,
// no Google Play Services. Returns the text (EXTRA_TEXT) or nothing when the
// person closes it or refuses the camera.

package com.sinhron.sinhron

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class QrScanActivity : ComponentActivity() {
    companion object {
        const val EXTRA_TEXT = "text"
    }

    private val analysis = Executors.newSingleThreadExecutor()
    private val done = AtomicBoolean(false)
    private lateinit var preview: PreviewView

    private val askCamera = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) startCamera() else finishWith(null)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        preview = PreviewView(this)
        val close = TextView(this).apply {
            text = getString(R.string.qr_close)
            setTextColor(Color.WHITE)
            textSize = 17f
            setPadding(48, 48, 48, 48)
            // Readable over any picture (on the emulator: white on a white sky).
            setBackgroundColor(0x99000000.toInt())
            setOnClickListener { finishWith(null) }
        }
        val hint = TextView(this).apply {
            text = getString(R.string.qr_hint)
            setTextColor(Color.WHITE)
            textSize = 15f
            gravity = Gravity.CENTER
            setPadding(48, 48, 48, 96)
            setBackgroundColor(0x99000000.toInt())
        }
        setContentView(
            FrameLayout(this).apply {
                setBackgroundColor(Color.BLACK)
                addView(preview)
                addView(close, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.START))
                addView(hint, FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM))
            },
        )
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            startCamera()
        } else {
            askCamera.launch(Manifest.permission.CAMERA)
        }
    }

    private fun startCamera() {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            val provider = future.get()
            val p = Preview.Builder().build().also { it.surfaceProvider = preview.surfaceProvider }
            val reader = MultiFormatReader().apply {
                setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE)))
            }
            val a = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            a.setAnalyzer(analysis) { image -> decode(image, reader) }
            provider.unbindAll()
            provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, p, a)
        }, ContextCompat.getMainExecutor(this))
    }

    private fun decode(image: ImageProxy, reader: MultiFormatReader) {
        try {
            if (done.get()) return
            val plane = image.planes[0] // Y — luminance is all a QR needs
            val buf = plane.buffer
            val bytes = ByteArray(buf.remaining()).also { buf.get(it) }
            val source = PlanarYUVLuminanceSource(
                bytes, plane.rowStride, image.height, 0, 0, image.width, image.height, false,
            )
            val text = reader.decodeWithState(BinaryBitmap(HybridBinarizer(source))).text
            if (done.compareAndSet(false, true)) runOnUiThread { finishWith(text) }
        } catch (_: NotFoundException) {
            // no code in this frame
        } catch (_: Exception) {
        } finally {
            reader.reset()
            image.close()
        }
    }

    private fun finishWith(text: String?) {
        if (text != null) setResult(Activity.RESULT_OK, Intent().putExtra(EXTRA_TEXT, text)) else setResult(Activity.RESULT_CANCELED)
        finish()
    }

    override fun onDestroy() {
        super.onDestroy()
        analysis.shutdown()
    }
}
