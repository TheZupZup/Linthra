package io.github.thezupzup.linthra

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Extends AudioServiceActivity (instead of the default FlutterActivity) so the
// single Flutter activity binds to the audio_service media session correctly.
// This is the activity audio_service expects to host the engine; using the
// plain FlutterActivity would leave the background service unable to attach.
//
// It also registers the SAF method channel that backs content-resolver folder
// scanning (see SafDocumentScanner) and the folder *chooser*. The channel name
// is mirrored by MethodChannelSafDocumentLister / MethodChannelSafFolderPicker
// on the Dart side.
class MainActivity : AudioServiceActivity() {
    // The pending reply for an in-flight folder pick. A SAF chooser is a separate
    // activity, so the answer arrives asynchronously in onActivityResult; we hold
    // the channel reply until then. Only one pick can be in flight at a time.
    private var pendingFolderPickResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SAF_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Open the system folder chooser (ACTION_OPEN_DOCUMENT_TREE)
                    // and return the picked content:// tree URI — the scoped-
                    // storage-correct selection — *with its read grant persisted*.
                    // This is the fix for "no music found": file_picker's
                    // getDirectoryPath resolves the pick to a raw /storage path
                    // that dart:io cannot read under scoped storage, so the SAF
                    // walk was never reached. Returning the tree URI routes the
                    // scan through SafDocumentScanner instead.
                    "pickFolderTree" -> startFolderPick(result)
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
                    // Read a track's sidecar lyrics file (Song.lrc / Song.txt
                    // next to Song.mp3) from within the existing folder grant.
                    // Returns the text, or null when there's no such sidecar.
                    "readSidecarText" -> {
                        val uri = call.argument<String>("uri")
                        val extension = call.argument<String>("extension")
                        if (uri == null || extension == null) {
                            result.error(
                                "bad_args",
                                "uri and extension are required",
                                null,
                            )
                        } else {
                            result.success(
                                SafDocumentScanner(applicationContext)
                                    .readSidecarText(uri, extension),
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startFolderPick(result: MethodChannel.Result) {
        // Guard against overlapping picks: a second request while one is open
        // would orphan the first reply. Surface it rather than silently dropping.
        if (pendingFolderPickResult != null) {
            result.error(
                "pick_in_progress",
                "A folder pick is already in progress.",
                null,
            )
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            // Ask for a persistable read grant so the folder picked once can be
            // re-scanned after a restart (the removable-SD-card-after-reboot case)
            // without re-prompting. We take the grant in onActivityResult.
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
            )
        }
        try {
            pendingFolderPickResult = result
            startActivityForResult(intent, REQUEST_CODE_PICK_FOLDER)
        } catch (e: ActivityNotFoundException) {
            // No document-tree provider on this device (rare). Report it instead
            // of leaving the Dart future hanging.
            pendingFolderPickResult = null
            result.error("no_picker", "No folder chooser is available.", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_CODE_PICK_FOLDER) {
            // Not ours — let the engine forward it to plugins as usual.
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingFolderPickResult
        pendingFolderPickResult = null
        if (result == null) {
            // The activity was recreated mid-pick and the reply was lost; nothing
            // to deliver. Don't crash.
            return
        }
        val treeUri: Uri? = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (treeUri == null) {
            // User cancelled (or no URI came back). null == "no selection" on the
            // Dart side, which the controller treats as a cancelled pick.
            result.success(null)
            return
        }
        // Persist the read grant so a later scan/rescan still has access.
        // Best-effort: if the grant isn't persistable the URI still works this
        // session, and diagnostics will report the lost grant later.
        try {
            contentResolver.takePersistableUriPermission(
                treeUri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        } catch (e: SecurityException) {
            // Not persistable on this provider; the session grant still stands.
        }
        result.success(treeUri.toString())
    }

    companion object {
        private const val SAF_CHANNEL = "io.github.thezupzup.linthra/saf"

        // Arbitrary, app-local request code for the folder chooser. Kept within
        // 16 bits to stay compatible with how Activity dispatches results.
        private const val REQUEST_CODE_PICK_FOLDER = 0x5AF0
    }
}
