package ro.noraz.ncommander

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.graphics.pdf.PdfRenderer
import android.media.MediaMetadataRetriever
import android.media.MediaScannerConnection
import android.media.ThumbnailUtils
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.StatFs
import android.os.storage.StorageManager
import android.provider.MediaStore
import android.provider.Settings
import android.util.Size
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

/** Storage access, volumes, open/share intents, media scan and thumbnails for Ncommander. */
class MainActivity : FlutterActivity() {
    private val pool = Executors.newFixedThreadPool(3)
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ncommander/native").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "hasAccess" -> result.success(hasAccess())
                    "requestAccess" -> {
                        requestAccess()
                        result.success(null)
                    }
                    "volumes" -> result.success(volumes())
                    "space" -> {
                        val s = StatFs(call.arguments as String)
                        result.success(listOf(s.totalBytes, s.availableBytes))
                    }
                    "open" -> {
                        val path = call.argument<String>("path")!!
                        val mime = call.argument<String>("mime") ?: "*/*"
                        val chooser = call.argument<Boolean>("chooser") == true
                        result.success(open(path, mime, chooser))
                    }
                    "share" -> {
                        share(call.argument<List<String>>("paths")!!, call.argument<String>("mime") ?: "*/*")
                        result.success(null)
                    }
                    "scan" -> {
                        @Suppress("UNCHECKED_CAST")
                        val paths = (call.arguments as List<String>).toTypedArray()
                        if (paths.isNotEmpty()) MediaScannerConnection.scanFile(applicationContext, paths, null, null)
                        result.success(null)
                    }
                    "thumb" -> {
                        val path = call.argument<String>("path")!!
                        val kind = call.argument<String>("kind")!!
                        val size = call.argument<Int>("size") ?: 128
                        pool.execute {
                            val bytes = try { thumb(path, kind, size) } catch (_: Throwable) { null }
                            main.post { result.success(bytes) }
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("err", e.message, null)
            }
        }
    }

    // ------------------------------------------------------------- access

    private fun hasAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= 30) Environment.isExternalStorageManager()
        else checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED

    private fun requestAccess() {
        if (Build.VERSION.SDK_INT >= 30) {
            try {
                startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName")))
            } catch (_: Exception) {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            }
        } else {
            requestPermissions(arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.WRITE_EXTERNAL_STORAGE), 7)
        }
    }

    // ------------------------------------------------------------ volumes

    private fun volumes(): List<Map<String, Any>> {
        val out = mutableListOf<Map<String, Any>>()
        val seen = mutableSetOf<String>()
        val sm = getSystemService(Context.STORAGE_SERVICE) as StorageManager
        for (v in sm.storageVolumes) {
            if (v.state != Environment.MEDIA_MOUNTED && v.state != Environment.MEDIA_MOUNTED_READ_ONLY) continue
            val path = volumePath(v) ?: continue
            if (!seen.add(path)) continue
            out.add(volumeMap(path, v.getDescription(this) ?: path, v.isRemovable, v.isPrimary))
        }
        if (out.isEmpty()) {
            val p = Environment.getExternalStorageDirectory().absolutePath
            out.add(volumeMap(p, "", false, true))
        }
        return out
    }

    private fun volumePath(v: android.os.storage.StorageVolume): String? {
        if (Build.VERSION.SDK_INT >= 30) return v.directory?.absolutePath
        return try {
            v.javaClass.getMethod("getPath").invoke(v) as? String
        } catch (_: Exception) {
            null
        }
    }

    private fun volumeMap(path: String, label: String, removable: Boolean, primary: Boolean): Map<String, Any> {
        var total = 0L
        var free = 0L
        try {
            val s = StatFs(path)
            total = s.totalBytes
            free = s.availableBytes
        } catch (_: Exception) {
        }
        return mapOf("path" to path, "label" to label, "removable" to removable, "primary" to primary, "total" to total, "free" to free)
    }

    // ------------------------------------------------------------ intents

    private fun uriFor(path: String): Uri = FileProvider.getUriForFile(this, "$packageName.files", File(path))

    private fun open(path: String, mime: String, chooser: Boolean): Boolean {
        val uri = uriFor(path)
        val i = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        }
        return try {
            startActivity(if (chooser) Intent.createChooser(i, null) else i)
            true
        } catch (_: ActivityNotFoundException) {
            if (!chooser && mime != "*/*") open(path, "*/*", true) else false
        }
    }

    private fun share(paths: List<String>, mime: String) {
        val uris = ArrayList(paths.map { uriFor(it) })
        val i = if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).apply { putExtra(Intent.EXTRA_STREAM, uris[0]) }
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).apply { putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris) }
        }
        i.type = mime
        val clip = ClipData.newRawUri(null, uris[0])
        for (k in 1 until uris.size) clip.addItem(ClipData.Item(uris[k]))
        i.clipData = clip
        i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        startActivity(Intent.createChooser(i, null))
    }

    // --------------------------------------------------------- thumbnails

    private fun thumb(path: String, kind: String, size: Int): ByteArray? {
        val bmp: Bitmap? = when (kind) {
            "video" -> videoThumb(path, size)
            "audio" -> MediaMetadataRetriever().let { r ->
                try {
                    r.setDataSource(path)
                    r.embeddedPicture?.let { decodeScaled(it, size) }
                } finally {
                    r.release()
                }
            }
            "pdf" -> pdfThumb(path, size)
            "apk" -> apkIcon(path, size)
            else -> null
        }
        bmp ?: return null
        val out = ByteArrayOutputStream()
        bmp.compress(if (kind == "apk") Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG, 85, out)
        return out.toByteArray()
    }

    private fun videoThumb(path: String, size: Int): Bitmap? =
        if (Build.VERSION.SDK_INT >= 29) ThumbnailUtils.createVideoThumbnail(File(path), Size(size, size), null)
        else @Suppress("DEPRECATION") ThumbnailUtils.createVideoThumbnail(path, MediaStore.Images.Thumbnails.MINI_KIND)

    private fun decodeScaled(data: ByteArray, size: Int): Bitmap? {
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, o)
        var s = 1
        while (o.outWidth / (s * 2) >= size && o.outHeight / (s * 2) >= size) s *= 2
        return BitmapFactory.decodeByteArray(data, 0, data.size, BitmapFactory.Options().apply { inSampleSize = s })
    }

    private fun pdfThumb(path: String, size: Int): Bitmap? {
        val fd = ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
        fd.use {
            PdfRenderer(it).use { r ->
                if (r.pageCount == 0) return null
                r.openPage(0).use { p ->
                    val scale = size.toFloat() / maxOf(p.width, p.height)
                    val w = maxOf(1, (p.width * scale).toInt())
                    val h = maxOf(1, (p.height * scale).toInt())
                    val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                    bmp.eraseColor(Color.WHITE)
                    p.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    return bmp
                }
            }
        }
    }

    private fun apkIcon(path: String, size: Int): Bitmap? {
        val pm = packageManager
        val info = pm.getPackageArchiveInfo(path, 0) ?: return null
        val app = info.applicationInfo ?: return null
        app.sourceDir = path
        app.publicSourceDir = path
        return drawableToBitmap(app.loadIcon(pm), size)
    }

    private fun drawableToBitmap(d: Drawable, size: Int): Bitmap {
        if (d is BitmapDrawable && d.bitmap != null) return Bitmap.createScaledBitmap(d.bitmap, size, size, true)
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        d.setBounds(0, 0, size, size)
        d.draw(c)
        return bmp
    }

    override fun onDestroy() {
        pool.shutdownNow()
        super.onDestroy()
    }
}
