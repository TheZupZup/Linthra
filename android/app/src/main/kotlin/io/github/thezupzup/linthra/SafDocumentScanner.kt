package io.github.thezupzup.linthra

import android.content.Context
import android.content.Intent
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

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
 *
 * Threading: the walk is blocking and proportional to the library, so it runs
 * on [PlatformChannelWorker]'s background thread rather than on the platform
 * thread Flutter calls the channel handler on (#346). The cheap calls
 * ([hasPersistedPermission], [readSidecarText]) still answer inline.
 */
class SafDocumentScanner(
    private val context: Context,
    private val worker: PlatformChannelWorker = PlatformChannelWorker(),
) {
    /**
     * Lists audio documents under [treeUri], reporting back through [result].
     *
     * The walk runs on [PlatformChannelWorker]'s background thread, and [result]
     * is encoded and answered there too, so a real library — thousands of
     * content-resolver queries plus a [MediaMetadataRetriever] open per file —
     * never blocks the UI (#346). This returns as soon as the work is queued.
     *
     * Starting a scan supersedes any earlier one: the older walk stops at its
     * next file instead of making this one wait out a scan the user already
     * moved on from. The flag that does it is process-scoped (see [currentScan])
     * because the worker thread it frees is, so this holds across a scanner
     * rebuilt with a recreated activity.
     */
    fun listAudioDocuments(treeUri: String, result: MethodChannel.Result) {
        // Supersede whatever was queued or running before answering this one.
        val cancelled = AtomicBoolean(false)
        currentScan.getAndSet(cancelled)?.set(true)

        worker.submit(
            work = { walk(Uri.parse(treeUri), cancelled) },
            onSuccess = { documents -> result.success(documents) },
            onFailure = { error ->
                // A revoked or never-granted tree is a clear "no access"; every
                // other failure stays a generic read error, so no provider
                // message (which could carry a path) reaches the Dart side.
                if (error is ScanSuperseded) {
                    // Only ever reached by a scan a newer one replaced, and the
                    // Dart side drops a superseded response on every path
                    // (LibraryController's generation guard), so this reports
                    // what happened rather than pretending the folder failed.
                    result.error(
                        "saf_superseded",
                        "A newer scan replaced this one.",
                        null,
                    )
                } else if (error is SecurityException) {
                    result.error(
                        "saf_permission",
                        "No access to the selected folder.",
                        null,
                    )
                } else {
                    result.error(
                        "saf_failed",
                        "Failed to read the selected folder.",
                        null,
                    )
                }
            },
        )
    }

    /**
     * Stops the walk that is queued or running, if any, without starting one.
     *
     * [listAudioDocuments] already supersedes its predecessor, which covers a
     * user picking a different folder. It does not cover abandoning the scan
     * outright: forgetting the folder, or switching to the device-wide
     * MediaStore library. Those only invalidate the Dart-side result, so
     * without this the abandoned walk keeps opening a MediaMetadataRetriever
     * and extracting artwork for the rest of a library nobody is waiting for,
     * competing with the MediaStore traversal that just started for the same
     * content-resolver I/O.
     *
     * Cheap (one atomic swap), so it answers on the calling thread. Safe to
     * call when nothing is running: there is simply no flag to trip.
     */
    fun cancelScan() {
        currentScan.getAndSet(null)?.set(true)
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

    private fun walk(treeUri: Uri, cancelled: AtomicBoolean): Map<String, Any?> {
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
            // Checked here and once more per entry below, so a superseded walk
            // stops within one file's work rather than one folder's.
            if (cancelled.get()) throw ScanSuperseded()
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
                        // Also checked per entry, not only per folder: the
                        // common shape is one flat Music folder holding every
                        // track, so the outer loop runs once and a per-folder
                        // check alone would not interrupt anything. This is the
                        // loop that opens a MediaMetadataRetriever per file.
                        if (cancelled.get()) throw ScanSuperseded()
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
                                        "disc" to metadata["disc"],
                                        "durationMs" to metadata["durationMs"],
                                        "artworkUri" to metadata["artworkUri"],
                                    ),
                                )
                            }
                        }
                    }
                }
            } catch (e: ScanSuperseded) {
                // Cancellation is not a read failure. Without this clause the
                // per-entry check in the cursor loop above lands in the generic
                // catch, is counted as one unreadable subtree, and the walk
                // carries on to answer a partial success. The Dart side would
                // then decode a response of thousands of entries only to discard
                // it, while the scan the user is actually waiting for keeps
                // queueing. Rethrow so the worker answers the small
                // saf_superseded error instead.
                throw e
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
     * artist, album artist, album, track, disc, duration in ms); the Dart side
     * parses the track ("3/12"), disc ("1/2") and duration values.
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
                // The disc number of a multi-disc album. One key covers the
                // common tag forms, because the platform extractors map their
                // own spelling onto it: ID3v2 TPOS, Vorbis/FLAC DISCNUMBER and
                // MP4 "disk". The value keeps whatever the tagger wrote ("1",
                // "1/2", "02"), and the Dart side parses it like "track".
                "disc" to retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_DISC_NUMBER,
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

    /** Raised inside [walk] when a newer scan superseded this one. */
    private class ScanSuperseded : Exception()

    companion object {
        /**
         * The cancellation flag of the walk currently queued or running, if any.
         *
         * Scans share one worker thread, so a second one waits for the first.
         * That is right while both are wanted and wrong the moment the first is
         * not: a user who picks a different folder mid-scan would otherwise
         * watch the new one sit "loading" for however long the abandoned walk
         * still had to run. Superseding sets this flag, the walk notices at its
         * next file, and the thread frees up for the selection the user
         * actually made.
         *
         * Process-scoped, deliberately, because the thread it frees is:
         * [PlatformChannelWorker]'s executor outlives any one activity, so a
         * flag that did not would stop cancelling exactly when the activity is
         * recreated mid-scan ("Don't keep activities", a low-memory reclaim
         * while the audio service keeps the process alive, a config change
         * outside the manifest's list; the same recreation `MainActivity`'s
         * pending folder pick already has to survive). The new activity's
         * scanner would hold an empty flag, the obsolete walk would keep the
         * worker thread, and the folder the user just picked would wait it out.
         *
         * Only ever read and written through [AtomicReference.getAndSet] here,
         * so two scans racing from different threads still hand off cleanly.
         */
        private val currentScan = AtomicReference<AtomicBoolean?>(null)

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
