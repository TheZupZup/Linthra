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
    // Opts the window into the panel's native refresh rate (90/120/144 Hz where
    // available) while foregrounded, and hands the rate back to the system under
    // battery saver. Lazy so it binds to this activity once, on first resume.
    private val displayRefreshRate by lazy { DisplayRefreshRate(this) }

    override fun onResume() {
        super.onResume()
        displayRefreshRate.onResume()
    }

    override fun onPause() {
        displayRefreshRate.onPause()
        super.onPause()
    }

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

        val treeUri: Uri? = if (resultCode == Activity.RESULT_OK) data?.data else null

        // Take the persistable read grant first, before touching the reply. This
        // happens whenever a folder came back, independently of whether the Dart
        // reply still lives: if the host activity was recreated while the chooser
        // was in front, the result is delivered to a *new* MainActivity instance,
        // and persisting here means the grant is never lost even in that case.
        // Best-effort: if the grant isn't persistable the URI still works this
        // session, and diagnostics will report the lost grant later.
        if (treeUri != null) {
            try {
                contentResolver.takePersistableUriPermission(
                    treeUri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            } catch (e: SecurityException) {
                // Not persistable on this provider; the session grant still stands.
            }
        }

        // Deliver the outcome to the waiting Dart future. Because the reply is held
        // in a process-scoped holder (see the companion object), a MainActivity
        // recreated mid-pick still finds and completes it here — so the picker
        // always settles to a selection (the tree URI) or a cancel (null), and the
        // Settings card never stays stuck loading. If the whole engine was torn
        // down with the activity, the Dart isolate that awaited this reply is gone
        // too: completing the (now-detached) reply is a harmless no-op, and the
        // restarted UI starts from a clean, non-loading state.
        val result = pendingFolderPickResult
        pendingFolderPickResult = null
        result?.success(treeUri?.toString())
    }

    companion object {
        // The pending reply for an in-flight folder pick. A SAF chooser is a
        // separate activity, so the answer arrives asynchronously in
        // onActivityResult; we hold the channel reply until then.
        //
        // Process-scoped (not an activity field) on purpose: while the chooser is
        // in front the host activity can be destroyed and recreated ("Don't keep
        // activities", a low-memory reclaim, or a config change outside the
        // manifest's configChanges list). onActivityResult is then dispatched to
        // the new instance; an instance field would already be null there and the
        // reply would be dropped, hanging the Dart future. Keeping it here lets the
        // recreated activity complete the same reply. It is always cleared once a
        // result arrives, and dies with the process, so it does not outlive the
        // pick. Only one pick can be in flight at a time.
        private var pendingFolderPickResult: MethodChannel.Result? = null

        private const val SAF_CHANNEL = "io.github.thezupzup.linthra/saf"

        // Arbitrary, app-local request code for the folder chooser. Kept within
        // 16 bits to stay compatible with how Activity dispatches results.
        private const val REQUEST_CODE_PICK_FOLDER = 0x5AF0
    }
}
