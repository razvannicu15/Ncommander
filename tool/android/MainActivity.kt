package ro.noraz.ncommander

import android.Manifest
import android.accounts.Account
import android.accounts.AccountManager
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
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Size
import androidx.core.content.FileProvider
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import com.google.android.gms.auth.GoogleAuthUtil
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.Scope
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
    private var channel: MethodChannel? = null
    private var pendingGoogle: MethodChannel.Result? = null
    private val rcGoogle = 4711
    private val rcPick = 4712
    private var pendingPick: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ncommander/native")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "hasAccess" -> result.success(hasAccess())
                    "protect" -> result.success(seal(call.arguments as ByteArray))
                    "unprotect" -> result.success(unseal(call.arguments as ByteArray))
                    "systemAccent" -> result.success(
                        if (Build.VERSION.SDK_INT >= 31) resources.getColor(android.R.color.system_accent1_500, theme) else null
                    )
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
                    "openUrl" -> {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(call.arguments as String)))
                        result.success(null)
                    }
                    "googleToken" -> googleToken(call.argument<String>("account") ?: "", call.argument<Boolean>("interactive") == true, result)
                    "googlePickAccount" -> {
                        // System account chooser: lets the user pick any Google account on the phone.
                        pendingPick?.success(null)
                        pendingPick = result
                        val i = AccountManager.newChooseAccountIntent(null, null, arrayOf("com.google"), null, null, null, null)
                        try {
                            @Suppress("DEPRECATION")
                            startActivityForResult(i, rcPick)
                        } catch (e: Exception) {
                            pendingPick = null
                            result.error("pick", e.message, null)
                        }
                    }
                    "googleClearToken" -> {
                        val t = call.arguments as String
                        pool.execute {
                            try { GoogleAuthUtil.clearToken(applicationContext, t) } catch (_: Exception) {}
                            main.post { result.success(null) }
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("err", e.message, null)
            }
        }
    }

    // ------------------------------------------------------- cloud sign-in

    private fun googleToken(account: String, interactive: Boolean, result: MethodChannel.Result) {
        val b = AuthorizationRequest.builder().setRequestedScopes(listOf(Scope("https://www.googleapis.com/auth/drive")))
        if (account.contains("@")) b.setAccount(Account(account, "com.google"))
        Identity.getAuthorizationClient(this).authorize(b.build())
            .addOnSuccessListener { r ->
                if (r.hasResolution()) {
                    if (!interactive) {
                        result.success(null)
                        return@addOnSuccessListener
                    }
                    try {
                        pendingGoogle?.success(null)
                        pendingGoogle = result
                        @Suppress("DEPRECATION")
                        startIntentSenderForResult(r.pendingIntent!!.intentSender, rcGoogle, null, 0, 0, 0, null)
                    } catch (e: Exception) {
                        pendingGoogle = null
                        result.error("auth", e.message, null)
                    }
                } else {
                    result.success(r.accessToken)
                }
            }
            .addOnFailureListener { e -> result.error("auth", e.message ?: "Google", null) }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == rcPick) {
            val r = pendingPick ?: return
            pendingPick = null
            r.success(if (resultCode == RESULT_OK) data?.getStringExtra(AccountManager.KEY_ACCOUNT_NAME) else null)
            return
        }
        if (requestCode != rcGoogle) return
        val res = pendingGoogle ?: return
        pendingGoogle = null
        try {
            val r = Identity.getAuthorizationClient(this).getAuthorizationResultFromIntent(data)
            res.success(r.accessToken)
        } catch (e: Exception) {
            res.error("auth", e.message ?: "cancelled", null)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val d = intent.data ?: return
        if (d.scheme == "ncommander") channel?.invokeMethod("redirect", d.toString())
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
            "image" -> imageThumb(path, size)
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
        val sq = if (kind == "apk") bmp else centerCrop(bmp, size)
        sq.compress(if (kind == "apk") Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG, 82, out)
        return out.toByteArray()
    }

    /** Uses the EXIF preview when there is one: fast even for 50 MP photos. */
    private fun imageThumb(path: String, size: Int): Bitmap? {
        if (Build.VERSION.SDK_INT >= 29) {
            try {
                return ThumbnailUtils.createImageThumbnail(File(path), Size(size, size), null)
            } catch (_: Exception) {
            }
        }
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, o)
        if (o.outWidth <= 0) return null
        var s = 1
        while (o.outWidth / (s * 2) >= size && o.outHeight / (s * 2) >= size) s *= 2
        return BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = s })
    }

    private fun videoThumb(path: String, size: Int): Bitmap? =
        if (Build.VERSION.SDK_INT >= 29) ThumbnailUtils.createVideoThumbnail(File(path), Size(size, size), null)
        else @Suppress("DEPRECATION") ThumbnailUtils.createVideoThumbnail(path, MediaStore.Images.Thumbnails.MINI_KIND)

    /** Square, small: keeps the bytes sent to Flutter tiny. */
    private fun centerCrop(b: Bitmap, size: Int): Bitmap {
        val side = minOf(b.width, b.height)
        if (side <= 0) return b
        val x = (b.width - side) / 2
        val y = (b.height - side) / 2
        val c = Bitmap.createBitmap(b, x, y, side, side)
        return if (side > size) Bitmap.createScaledBitmap(c, size, size, true) else c
    }

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

    // Saved passwords and tokens are encrypted with a key kept in the Android Keystore.
    private fun secretKey(): SecretKey {
        val alias = "ncommander_secrets"
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val g = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        g.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return g.generateKey()
    }

    private fun seal(data: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, secretKey())
        return c.iv + c.doFinal(data)
    }

    private fun unseal(data: ByteArray): ByteArray? = try {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, data.copyOfRange(0, 12)))
        c.doFinal(data.copyOfRange(12, data.size))
    } catch (e: Exception) {
        null
    }
}
