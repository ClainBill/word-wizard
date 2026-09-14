package com.willcharlesgill.wordwizard

import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
}
