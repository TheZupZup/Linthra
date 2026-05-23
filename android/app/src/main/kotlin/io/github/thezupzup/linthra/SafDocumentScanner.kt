package io.github.thezupzup.linthra

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque

/**
 * Walks a user-picked Storage Access Framework tree URI through the content
 * resolver and returns the audio documents under it (recursively) as
 * `{uri, name}` maps.
 *
 * This is the scoped-storage way to read a chosen folder: it uses only the
 * access the system granted when the user picked the tree, so it needs no
 * storage permission and never touches MANAGE_EXTERNAL_STORAGE. Filtering to
 * audio is intentionally generous (an "audio/" MIME type or a known
 * extension); the Dart layer re-filters by its own supported-types list,
 * keeping that list in one place.
 */
class SafDocumentScanner(private val context: Context) {

    /** Lists audio documents under [treeUri], reporting back through [result]. */
    fun listAudioDocuments(treeUri: String, result: MethodChannel.Result) {
        try {
            result.success(walk(Uri.parse(treeUri)))
        } catch (e: SecurityException) {
            result.error("saf_permission", "No access to the selected folder.", null)
        } catch (e: Exception) {
            result.error("saf_failed", "Failed to read the selected folder.", null)
        }
    }

    private fun walk(treeUri: Uri): List<Map<String, String>> {
        // Persist the grant when possible so a folder picked once can still be
        // scanned after a restart; harmless (and ignored) when not persistable.
        try {
            context.contentResolver.takePersistableUriPermission(
                treeUri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        } catch (e: SecurityException) {
            // The grant wasn't persistable; traversal still works this session.
        }

        val out = ArrayList<Map<String, String>>()
        val queue = ArrayDeque<String>()
        queue.add(DocumentsContract.getTreeDocumentId(treeUri))
        while (queue.isNotEmpty()) {
            val parentDocId = queue.poll()
            val childrenUri =
                DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocId)
            context.contentResolver.query(
                childrenUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                ),
                null,
                null,
                null,
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    val docId = cursor.getString(0) ?: continue
                    val name = cursor.getString(1) ?: continue
                    val mime = cursor.getString(2)
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        queue.add(docId)
                    } else if (isAudio(mime, name)) {
                        val docUri =
                            DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                        out.add(mapOf("uri" to docUri.toString(), "name" to name))
                    }
                }
            }
        }
        return out
    }

    private fun isAudio(mime: String?, name: String): Boolean {
        if (mime != null && mime.startsWith("audio/")) {
            return true
        }
        val lower = name.lowercase()
        return AUDIO_EXTENSIONS.any { lower.endsWith(it) }
    }

    companion object {
        private val AUDIO_EXTENSIONS =
            listOf(".mp3", ".flac", ".m4a", ".aac", ".ogg", ".opus", ".wav")
    }
}
