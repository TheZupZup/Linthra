package io.github.thezupzup.linthra

import android.content.Context
import android.content.Intent
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.ArrayDeque
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

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

    /**
     * Lists audio documents under [treeUri], reporting back through [result].
     *
     * The walk does blocking content-resolver queries and a per-file
     * [MediaMetadataRetriever] read (plus embedded-artwork extraction), so on a
     * large library it can take many seconds. The method-channel handler runs on
     * the platform main thread, so doing the walk inline would freeze the UI —
     * the bug this guards against. The walk therefore runs on a background
     * executor, and the reply is posted back to the main thread, which is where
     * Flutter requires [MethodChannel.Result] to be answered. The walk itself
     * (and the result it produces) is unchanged.
     */
    fun listAudioDocuments(treeUri: String, result: MethodChannel.Result) {
        scanExecutor.execute {
            try {
                val documents = walk(Uri.parse(treeUri))
                mainHandler.post { result.success(documents) }
            } catch (e: SecurityException) {
                mainHandler.post {
                    result.error("saf_permission", "No access to the selected folder.", null)
                }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("saf_failed", "Failed to read the selected folder.", null)
                }
            }
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

    /**
     * Reads the text of a sidecar lyrics file sitting next to the audio document
     * at [audioUri] — `Song.lrc` / `Song.txt` beside `Song.mp3` — and returns
     * it, or null when there's no such sibling or it can't be read.
     *
     * The audio URI is a tree-based document URI (built by the walk via
     * buildDocumentUriUsingTree), so the sibling is reached under the *same*
     * folder grant: swap the file's extension in the document id and rebuild the
     * document URI within the tree. This needs no extra permission and never
     * touches a raw /storage path. [extension] is the bare suffix ("lrc", "txt").
     *
     * Deliberately total: any failure (a non-tree URI, an opaque provider whose
     * ids aren't path-like, a missing file, an oversized or unreadable stream)
     * returns null so the Dart side falls back to "no lyrics" — never an error,
     * and never a leaked file name or path.
     */
    fun readSidecarText(audioUri: String, extension: String): String? {
        return try {
            val uri = Uri.parse(audioUri)
            val authority = uri.authority ?: return null
            val documentId = DocumentsContract.getDocumentId(uri)
            val siblingId = swapExtension(documentId, extension) ?: return null
            val treeId = DocumentsContract.getTreeDocumentId(uri)
            val treeUri = DocumentsContract.buildTreeDocumentUri(authority, treeId)
            val siblingUri =
                DocumentsContract.buildDocumentUriUsingTree(treeUri, siblingId)
            readText(siblingUri)
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Replaces the extension of the last path segment of a (path-like) document
     * id with [extension], e.g. `primary:Music/Song.mp3` -> `primary:Music/Song.lrc`.
     * A segment with no extension simply gains one. Returns null only for an
     * empty id. Opaque ids (cloud providers) yield a sibling id that won't
     * resolve, which surfaces as "no lyrics" — acceptable for non-local sources.
     */
    private fun swapExtension(documentId: String, extension: String): String? {
        if (documentId.isEmpty()) return null
        val slash = documentId.lastIndexOf('/')
        val dot = documentId.lastIndexOf('.')
        return if (dot > slash && dot > 0) {
            documentId.substring(0, dot) + "." + extension
        } else {
            "$documentId.$extension"
        }
    }

    /**
     * Reads [uri]'s bytes as UTF-8 text under the existing tree grant, or null
     * when it can't be opened (no such sibling) or exceeds [MAX_SIDECAR_BYTES]
     * (a real lyrics file is tiny; an oversized one is more likely a mis-matched
     * document than lyrics). The stream is always closed.
     */
    private fun readText(uri: Uri): String? {
        return try {
            context.contentResolver.openInputStream(uri)?.use { stream ->
                val buffer = ByteArrayOutputStream()
                val chunk = ByteArray(8192)
                var total = 0
                while (true) {
                    val read = stream.read(chunk)
                    if (read < 0) break
                    total += read
                    if (total > MAX_SIDECAR_BYTES) return null
                    buffer.write(chunk, 0, read)
                }
                String(buffer.toByteArray(), Charsets.UTF_8)
            }
        } catch (e: Exception) {
            null
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
        // A single background thread for the (potentially long) folder walk, so a
        // large-library scan never runs on the platform main thread and freezes
        // the UI. Process-wide and serialized — one scan at a time, matching the
        // previous (main-thread) behaviour minus the freeze — and a daemon thread
        // so it never keeps the process alive on its own.
        private val scanExecutor: ExecutorService =
            Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "linthra-saf-scan").apply { isDaemon = true }
            }

        // Posts the method-channel reply back to the main thread, where Flutter
        // requires MethodChannel.Result to be answered.
        private val mainHandler = Handler(Looper.getMainLooper())

        private val AUDIO_EXTENSIONS =
            listOf(".mp3", ".flac", ".m4a", ".aac", ".ogg", ".opus", ".wav")

        // Subfolder of cacheDir holding extracted embedded cover art. App-private
        // and OS-reclaimable; never contains a user file name or path.
        private const val ARTWORK_CACHE_DIR = "linthra_local_artwork"

        // Cap on a sidecar lyrics file we'll read into memory. Real .lrc/.txt
        // lyrics are a few KB; a larger match is more likely a wrong document
        // than lyrics, so it's ignored (-> "no lyrics") rather than loaded.
        private const val MAX_SIDECAR_BYTES = 1 * 1024 * 1024
    }
}
