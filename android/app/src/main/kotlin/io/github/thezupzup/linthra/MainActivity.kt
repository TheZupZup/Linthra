package io.github.thezupzup.linthra

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Extends AudioServiceActivity (instead of the default FlutterActivity) so the
// single Flutter activity binds to the audio_service media session correctly.
// This is the activity audio_service expects to host the engine; using the
// plain FlutterActivity would leave the background service unable to attach.
//
// It also registers the SAF method channel that backs content-resolver folder
// scanning (see SafDocumentScanner). The channel name is mirrored by
// MethodChannelSafDocumentLister on the Dart side.
class MainActivity : AudioServiceActivity() {
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
                    "hasPersistedPermission" -> {
                        val treeUri = call.argument<String>("treeUri")
                        if (treeUri == null) {
                            result.error("bad_args", "treeUri is required", null)
                        } else {
                            result.success(
                                SafDocumentScanner(applicationContext)
                                    .hasPersistedPermission(treeUri),
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        private const val SAF_CHANNEL = "io.github.thezupzup.linthra/saf"
    }
}
