package io.github.thezupzup.linthra

import android.content.Context
import android.content.Intent
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.ArrayDeque

/**
 * Walks a user-picked Storage Access Framework tree URI through the content
 * resolver and returns the audio documents under it (recursively), together
 * with secret-free counts the Dart diagnostics layer surfaces.
 *
 * This is the scoped-storage way to read a chosen folder: it uses only the
 * access the system granted when the user picked the tree, so it needs no
 * storage permission and never touches MANAGE_EXTERNAL_STORAGE. Filtering to
 * audio is intentionally generous (an "audio/" MIME type or a known
 * extension); the Dart layer re-filters by its own supported-types list,
 * keeping that list in one place.
 *
 * Resilience: an unreadable subfolder (a provider hiccup, a vanished entry on a
 * removable SD card) is counted and skipped rather than aborting the whole
 * walk, so one bad subtree can't zero out an otherwise-readable library. A
 * total access denial (a revoked grant) still surfaces as a SecurityException
 * so the user sees a clear "no access" message instead of a silent empty.
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

    /**
     * Whether the app currently holds a persisted *read* grant for [treeUri] —
     * the diagnostic that tells "no music found" apart from a lost folder grant
     * (e.g. after a reboot, or a removable SD card that was remounted).
     */
    fun hasPersistedPermission(treeUri: String): Boolean {
        val target = Uri.parse(treeUri)
        return context.contentResolver.persistedUriPermissions.any {
            it.uri == target && it.isReadPermission
        }
    }

    private fun walk(treeUri: Uri): Map<String, Any?> {
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

        val documents = ArrayList<Map<String, String?>>()
        var filesVisited = 0
        var foldersVisited = 0
        var readFailures = 0
        // The first entry is the selected root. A failure there is fatal (no
        // access at all), not a skippable subtree — surfacing it keeps a dead
        // root from looking like a successful empty scan that wipes the catalog.
        var isRoot = true
        val queue = ArrayDeque<String>()
        queue.add(DocumentsContract.getTreeDocumentId(treeUri))
        while (queue.isNotEmpty()) {
            val parentDocId = queue.poll()
            val childrenUri =
                DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocId)
            try {
                val cursor = context.contentResolver.query(
                    childrenUri,
                    arrayOf(
                        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                        DocumentsContract.Document.COLUMN_MIME_TYPE,
                    ),
                    null,
                    null,
                    null,
                )
                if (cursor == null) {
                    if (isRoot) {
                        // The selected folder itself can't be listed — a real
                        // failure, not an empty folder. Surface it.
                        throw IllegalStateException("root folder is not listable")
                    }
                    // The provider returned nothing for this subtree; count it
                    // as a read failure and move on.
                    readFailures++
                    isRoot = false
                    continue
                }
                // A listable folder (the root or a subfolder) — count it.
                foldersVisited++
                isRoot = false
                cursor.use { c ->
                    while (c.moveToNext()) {
                        val docId = c.getString(0) ?: continue
                        val name = c.getString(1) ?: continue
                        val mime = c.getString(2)
                        if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                            queue.add(docId)
                        } else {
                            filesVisited++
                            if (isAudio(mime, name)) {
                                val docUri = DocumentsContract.buildDocumentUriUsingTree(
                                    treeUri,
                                    docId,
                                )
                                // Read the file's audio tags (and cache its
                                // embedded cover art) so a local track indexes
                                // with a real title/artist/album/duration and
                                // shows its artwork like a server track. Best-
                                // effort: a file whose tags can't be read just
                                // omits them and the Dart mapper falls back to the
                                // display name; a file with no embedded cover keeps
                                // the calm placeholder.
                                val metadata = readMetadata(docUri)
                                documents.add(
                                    mapOf(
                                        "uri" to docUri.toString(),
                                        "name" to name,
                                        "mime" to mime,
                                        "title" to metadata["title"],
                                        "artist" to metadata["artist"],
                                        "albumArtist" to metadata["albumArtist"],
                                        "album" to metadata["album"],
                                        "track" to metadata["track"],
                                        "durationMs" to metadata["durationMs"],
                                        "artworkUri" to metadata["artworkUri"],
                                    ),
                                )
                            }
                        }
                    }
                }
            } catch (e: SecurityException) {
                // A total access denial must surface as a clear error, not a
                // silent empty — rethrow so listAudioDocuments reports it.
                throw e
            } catch (e: Exception) {
                if (isRoot) {
                    // A failure listing the selected root is fatal, not a
                    // skippable subtree — surface it instead of returning empty.
                    throw e
                }
                // One unreadable subtree shouldn't fail the whole scan.
                readFailures++
            }
        }
        return mapOf(
            "documents" to documents,
            "filesVisited" to filesVisited,
            "foldersVisited" to foldersVisited,
            "readFailures" to readFailures,
        )
    }

    private fun isAudio(mime: String?, name: String): Boolean {
        if (mime != null && mime.startsWith("audio/")) {
            return true
        }
        val lower = name.lowercase()
        return AUDIO_EXTENSIONS.any { lower.endsWith(it) }
    }

    /**
     * Reads the audio tags for one document through [MediaMetadataRetriever],
     * which works on a content:// URI under the existing tree grant — no extra
     * permission, no broad storage access. Returns the raw tag strings (title,
     * artist, album artist, album, track, duration in ms); the Dart side parses
     * the track ("3/12") and duration values.
     *
     * Deliberately total: any failure (a malformed file, an unreadable entry, a
     * codec the device can't open) returns an empty map so the walk keeps going
     * and the track still indexes from its display name. The retriever is always
     * released, even on failure, so no native handle leaks across a large scan.
     */
    private fun readMetadata(uri: Uri): Map<String, String?> {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(context, uri)
            mapOf(
                "title" to retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_TITLE,
                ),
                "artist" to retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_ARTIST,
                ),
                "albumArtist" to retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_ALBUMARTIST,
                ),
                "album" to retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_ALBUM,
                ),
                "track" to retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_CD_TRACK_NUMBER,
                ),
                "durationMs" to retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_DURATION,
                ),
                // A file:// URI to the embedded cover art, cached once. Its own
                // try/catch (inside cacheEmbeddedArtwork) means a missing or
                // unwritable cover never costs the tags read above.
                "artworkUri" to cacheEmbeddedArtwork(uri, retriever),
            )
        } catch (e: Exception) {
            emptyMap()
        } finally {
            try {
                retriever.release()
            } catch (e: Exception) {
                // Releasing a retriever that never opened can throw; ignore.
            }
        }
    }

    /**
     * Extracts this document's embedded cover art (ID3 APIC, FLAC picture, MP4
     * cover, …) once into Linthra's private cache and returns a file:// URI to
     * it, or null when the file has no embedded art — or it can't be read or
     * written. getEmbeddedPicture() reads through the same content-resolver data
     * source the tags came from, under the folder's existing SAF grant, so it
     * needs no extra permission and never touches a raw /storage path.
     *
     * Cheap and idempotent across re-scans: the cache file is named by a SHA-1 of
     * the content URI — a stable key that leaks neither the file's name nor its
     * on-disk path — so a cover already extracted on an earlier scan is reused
     * *without* pulling the (potentially large) image bytes out of the retriever
     * again, because the existence check runs before getEmbeddedPicture(). Bytes
     * are written to a temp file and atomically renamed, so an interrupted scan
     * can never leave a half-written cover that then fails to decode forever.
     *
     * Deliberately total: any failure returns null so the track simply keeps the
     * calm placeholder, and — crucially — never disturbs the audio tags read
     * alongside it. The cache lives under cacheDir, so the OS can reclaim it under
     * storage pressure; the next folder rescan transparently re-extracts.
     */
    private fun cacheEmbeddedArtwork(
        uri: Uri,
        retriever: MediaMetadataRetriever,
    ): String? {
        return try {
            val dir = File(context.cacheDir, ARTWORK_CACHE_DIR)
            val cacheFile = File(dir, artworkCacheKey(uri) + ".img")
            if (cacheFile.isFile && cacheFile.length() > 0L) {
                return Uri.fromFile(cacheFile).toString()
            }
            val picture = retriever.embeddedPicture
            if (picture == null || picture.isEmpty()) {
                return null
            }
            if (!dir.isDirectory && !dir.mkdirs()) {
                return null
            }
            val tmp = File.createTempFile("art", ".tmp", dir)
            try {
                tmp.writeBytes(picture)
                if (tmp.renameTo(cacheFile)) {
                    Uri.fromFile(cacheFile).toString()
                } else {
                    tmp.delete()
                    null
                }
            } catch (e: Exception) {
                tmp.delete()
                null
            }
        } catch (e: Exception) {
            null
        }
    }

    /** A stable, path-free cache key for [uri]'s cover: a SHA-1 hex of the URI. */
    private fun artworkCacheKey(uri: Uri): String {
        val digest = MessageDigest.getInstance("SHA-1")
        val bytes = digest.digest(uri.toString().toByteArray(Charsets.UTF_8))
        return bytes.joinToString("") { "%02x".format(it.toInt() and 0xFF) }
    }

    companion object {
        private val AUDIO_EXTENSIONS =
            listOf(".mp3", ".flac", ".m4a", ".aac", ".ogg", ".opus", ".wav")

        // Subfolder of cacheDir holding extracted embedded cover art. App-private
        // and OS-reclaimable; never contains a user file name or path.
        private const val ARTWORK_CACHE_DIR = "linthra_local_artwork"
    }
}
