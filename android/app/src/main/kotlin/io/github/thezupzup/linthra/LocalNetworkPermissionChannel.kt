package io.github.thezupzup.linthra

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Android 17's local network permission (ACCESS_LOCAL_NETWORK).
 *
 * An app targeting API 37 can no longer open connections to the local network
 * (a Jellyfin or Navidrome box at 192.168.x.x, a NAS, a Plex server reached
 * through a plex.direct name) until the user grants this runtime permission.
 * Dart sockets cannot raise the prompt themselves, so this channel reports the
 * state and asks for it when Dart decides the user is doing something that
 * needs it. Nothing here asks on its own, at startup or otherwise.
 *
 * The permission only exists on Android 17 and later, and is only enforced for
 * an app targeting 37, so everywhere else the answer is "notRequired" and
 * nothing is ever requested.
 */
class LocalNetworkPermissionChannel(private val activity: Activity) {
    private val context: Context = activity.applicationContext

    fun configure(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            handle(call, result)
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> result.success(status())
            "request" -> request(result)
            "openAppSettings" -> openAppSettings(result)
            else -> result.notImplemented()
        }
    }

    private fun isEnforced(): Boolean =
        Build.VERSION.SDK_INT >= ANDROID_17 &&
            context.applicationInfo.targetSdkVersion >= ANDROID_17

    private fun status(): String {
        if (!isEnforced()) return STATUS_NOT_REQUIRED
        if (activity.checkSelfPermission(PERMISSION) == PackageManager.PERMISSION_GRANTED) {
            return STATUS_GRANTED
        }
        val requested = context
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_REQUESTED, false)
        if (!requested) return STATUS_NOT_REQUESTED
        // After a denial Android keeps offering the dialog while it says a
        // rationale is due; once it stops, a request returns at once without
        // showing anything, and only the app's settings page can grant it.
        return if (activity.shouldShowRequestPermissionRationale(PERMISSION)) {
            STATUS_DENIED
        } else {
            STATUS_PERMANENTLY_DENIED
        }
    }

    private fun request(result: MethodChannel.Result) {
        val current = status()
        if (current == STATUS_NOT_REQUIRED || current == STATUS_GRANTED) {
            result.success(current)
            return
        }
        if (pendingResult != null) {
            result.error(
                "permission_in_progress",
                "A local network permission request is already in progress.",
                null,
            )
            return
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_REQUESTED, true)
            .apply()
        pendingResult = result
        activity.requestPermissions(arrayOf(PERMISSION), REQUEST_CODE_PERMISSION)
    }

    fun onRequestPermissionsResult(requestCode: Int): Boolean {
        if (requestCode != REQUEST_CODE_PERMISSION) return false
        val result = pendingResult
        pendingResult = null
        // Read the outcome back rather than trusting grantResults: a dialog
        // dismissed without an answer hands back an empty array, and the same
        // status() the Dart side polls keeps the two from disagreeing.
        result?.success(status())
        return true
    }

    private fun openAppSettings(result: MethodChannel.Result) {
        try {
            val intent = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", context.packageName, null),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            result.success(null)
        } catch (e: Exception) {
            result.error("settings_unavailable", "Android app settings are unavailable.", null)
        }
    }

    companion object {
        const val CHANNEL = "io.github.thezupzup.linthra/local_network"

        // Spelled out rather than taken from Manifest.permission so the check
        // reads the same on every compileSdk; the platform only knows the name
        // from Android 17 (API 37) on, which isEnforced() already requires.
        private const val PERMISSION = "android.permission.ACCESS_LOCAL_NETWORK"
        private const val ANDROID_17 = 37

        private const val PREFS = "linthra_local_network_permission"
        private const val KEY_REQUESTED = "local_network_permission_requested"

        private const val STATUS_NOT_REQUIRED = "notRequired"
        private const val STATUS_GRANTED = "granted"
        private const val STATUS_NOT_REQUESTED = "notRequested"
        private const val STATUS_DENIED = "denied"
        private const val STATUS_PERMANENTLY_DENIED = "permanentlyDenied"

        private const val REQUEST_CODE_PERMISSION = 0xA0D2

        // Process-scoped, like the music permission's reply: the permission
        // dialog can recreate the activity before the answer comes back.
        private var pendingResult: MethodChannel.Result? = null
    }
}
