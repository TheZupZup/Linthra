package io.github.thezupzup.linthra

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

// Extends AudioServiceActivity (instead of the default FlutterActivity) so the
// single Flutter activity binds to the audio_service media session correctly.
// This is the activity audio_service expects to host the engine; using the
// plain FlutterActivity would leave the background service unable to attach.
//
// It also registers the SAF method channel that backs content-resolver folder
// scanning (see SafDocumentScanner) and a small connectivity channel used only
// by the download/cache mobile-data policy. Widgets never call Android APIs
// directly.
class MainActivity : AudioServiceActivity() {
    private var connectivityHandler: ConnectivityEventHandler? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SAF_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listAudioDocuments" -> {
                        val treeUri = call.argument<String>("treeUri")
                        if (treeUri == null) {
                            result.error("bad_args", "treeUri is required", null)
                        } else {
                            SafDocumentScanner(applicationContext)
                                .listAudioDocuments(treeUri, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        val connectivity = AndroidConnectivity(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CONNECTIVITY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "currentStatus" -> result.success(connectivity.currentStatus())
                    else -> result.notImplemented()
                }
            }
        connectivityHandler = ConnectivityEventHandler(connectivity)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, CONNECTIVITY_EVENTS)
            .setStreamHandler(connectivityHandler)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        connectivityHandler?.dispose()
        connectivityHandler = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    companion object {
        private const val SAF_CHANNEL = "io.github.thezupzup.linthra/saf"
        private const val CONNECTIVITY_CHANNEL = "io.github.thezupzup.linthra/connectivity"
        private const val CONNECTIVITY_EVENTS = "io.github.thezupzup.linthra/connectivity_status"
    }
}

private class AndroidConnectivity(context: Context) {
    private val manager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager

    fun currentStatus(): String {
        val cm = manager ?: return "unknown"
        val network = cm.activeNetwork ?: return "offline"
        val capabilities = cm.getNetworkCapabilities(network) ?: return "unknown"
        return statusFor(capabilities)
    }

    fun register(callback: ConnectivityManager.NetworkCallback) {
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        manager?.registerNetworkCallback(request, callback)
    }

    fun unregister(callback: ConnectivityManager.NetworkCallback) {
        manager?.unregisterNetworkCallback(callback)
    }

    private fun statusFor(capabilities: NetworkCapabilities): String {
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
        ) {
            return "wifi"
        }
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) {
            return "mobile"
        }
        return "unknown"
    }
}

private class ConnectivityEventHandler(
    private val connectivity: AndroidConnectivity,
) : EventChannel.StreamHandler {
    private var callback: ConnectivityManager.NetworkCallback? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        events.success(connectivity.currentStatus())
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                events.success(connectivity.currentStatus())
            }

            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities,
            ) {
                events.success(connectivity.currentStatus())
            }

            override fun onLost(network: Network) {
                events.success(connectivity.currentStatus())
            }

            override fun onUnavailable() {
                events.success("offline")
            }
        }
        callback = cb
        try {
            connectivity.register(cb)
        } catch (_: RuntimeException) {
            events.success("unknown")
        } catch (_: SecurityException) {
            events.success("unknown")
        }
    }

    override fun onCancel(arguments: Any?) {
        dispose()
    }

    fun dispose() {
        val cb = callback ?: return
        callback = null
        try {
            connectivity.unregister(cb)
        } catch (_: RuntimeException) {
            // Already unregistered or platform service unavailable.
        }
    }
}
