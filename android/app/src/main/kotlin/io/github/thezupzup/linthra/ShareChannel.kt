package io.github.thezupzup.linthra

import android.app.Activity
import android.content.Intent
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// Opens the Android system share sheet for a short piece of text. Fires a plain
// ACTION_SEND intent wrapped in a chooser — the standard AOSP share sheet, no
// Google Play Services and no permission required. The text is the only thing
// it touches; there is no recipient, account, or tracking.
//
// Bound to the hosting Activity (the chooser must launch from an activity
// context, not the application context). The Dart side (AndroidShareService)
// mirrors the channel name and the "shareText" method.
class ShareChannel(private val activity: Activity) {
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "shareText" -> {
                val text = call.argument<String>("text")
                if (text.isNullOrEmpty()) {
                    result.error("bad_args", "text is required", null)
                } else {
                    shareText(text, result)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun shareText(text: String, result: MethodChannel.Result) {
        try {
            val sendIntent = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, text)
            }
            // Wrap in a chooser so the user always sees the full share sheet
            // rather than a remembered default target.
            activity.startActivity(Intent.createChooser(sendIntent, null))
            result.success(true)
        } catch (e: Exception) {
            // No app to handle the share, or no activity to host the chooser.
            // The Dart side treats any failure as "not shared".
            result.error("share_failed", e.message, null)
        }
    }

    companion object {
        const val CHANNEL = "io.github.thezupzup.linthra/share"
    }
}
