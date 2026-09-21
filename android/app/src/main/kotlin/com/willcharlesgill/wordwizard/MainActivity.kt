package com.willcharlesgill.wordwizard

import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The dictionary arrives as an install-time asset pack (see
        // ../../../../dictionary_pack) and sqlite can't read inside an APK,
        // so the first launch streams it out to app storage. Streamed in
        // chunks on a background thread — never loaded whole — with
        // progress sent back so the Dart side can show a bar; the Flutter
        // asset route (rootBundle.load) held all 470 MB in memory at once.
        val dictionary = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "word_wizard/dictionary")
        dictionary.setMethodCallHandler { call, result ->
            when (call.method) {
                // Nowhere to open it in place on Android; it has to be copied.
                "locate" -> result.success(null)
                "install" -> {
                    val dest = call.argument<String>("dest")
                    if (dest == null) {
                        result.error("bad_args", "dest missing", null)
                        return@setMethodCallHandler
                    }
                    val main = Handler(Looper.getMainLooper())
                    thread(name = "dictionary-install") {
                        try {
                            val target = File(dest)
                            target.parentFile?.mkdirs()
                            val partial = File("$dest.part")
                            var copied = 0L
                            var lastReported = -1
                            assets.open(DICTIONARY_ASSET).use { input ->
                                // AssetInputStream.available() is the asset's full
                                // uncompressed length, compressed or not (openFd
                                // would refuse a compressed one).
                                val total = input.available().toLong()
                                FileOutputStream(partial).use { output ->
                                    val buffer = ByteArray(1 shl 20)
                                    while (true) {
                                        val n = input.read(buffer)
                                        if (n < 0) break
                                        output.write(buffer, 0, n)
                                        copied += n
                                        if (total > 0) {
                                            val percent = (copied * 100 / total).toInt()
                                            if (percent != lastReported) {
                                                lastReported = percent
                                                main.post { dictionary.invokeMethod("progress", percent / 100.0) }
                                            }
                                        }
                                    }
                                    output.fd.sync()
                                }
                            }
                            if (!partial.renameTo(target)) {
                                throw java.io.IOException("could not move ${partial.name} into place")
                            }
                            main.post { result.success(copied) }
                        } catch (e: Exception) {
                            main.post { result.error("install_failed", e.message, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        // The Reader tab's clipboard access. Flutter's own Clipboard API only
        // returns plain text, and every read of the clip's *contents* makes
        // Android 12+ show a "pasted from your clipboard" toast — so this
        // channel exposes the clip's description (its timestamp, which is
        // free to check and toast-free) and, only when that says something
        // new is there, the HTML flavour alongside the text.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "word_wizard/clipboard")
            .setMethodCallHandler { call, result ->
                val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                when (call.method) {
                    "describe" -> {
                        val description = clipboard.primaryClipDescription
                        val hasText = clipboard.hasPrimaryClip() &&
                            description != null && description.hasMimeType("text/*")
                        val timestamp =
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) description?.timestamp else null
                        result.success(mapOf("hasText" to hasText, "timestamp" to timestamp))
                    }
                    "read" -> {
                        val item = clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)
                        result.success(
                            mapOf(
                                "text" to item?.coerceToText(this)?.toString(),
                                "html" to item?.htmlText,
                            )
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        /// The file's name inside the asset pack.
        private const val DICTIONARY_ASSET = "dictionary.db"
    }
}
