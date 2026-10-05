package io.github.thezupzup.linthra

import java.io.File
import java.security.MessageDigest

/**
 * The file names the SAF scan caches embedded covers under (#742).
 *
 * A cover used to be cached under a SHA-1 of its document URI alone, and only
 * extracted when that file did not exist yet. Re-tagging a cover in place
 * keeps the document id, so the old cover was served for good, and another
 * song saved over the same path inherited the previous song's cover. So the
 * name now also carries the file's size and last-modified time, as the folder
 * listing reports them: any rewrite of the file moves one of them, misses the
 * cache, and extracts the cover again. The desktop cache keys on path, size and
 * mtime for the same reason.
 *
 * Every version of one document's cover starts with [documentPrefix], so the
 * versions before the current one can be found and dropped. A name never
 * carries the URI, the file name or its path, only hashes of them.
 *
 * Plain Kotlin with no Android types, so it is tested on the JVM.
 */
internal object SafArtworkCacheKey {
    /** What every cached version of [documentUri]'s cover is named starting with. */
    fun documentPrefix(documentUri: String): String = sha1Hex(documentUri)

    /**
     * The cache file name for [documentUri]'s cover as the file is now, given
     * the size and last-modified time its provider reported (either may be
     * null when the provider does not say).
     *
     * With neither known there is nothing to tell a changed file by, so the
     * name is the URI-only one covers had before (#742), and a provider that
     * reports neither keeps the covers it already has.
     */
    fun fileName(documentUri: String, sizeBytes: Long?, lastModifiedMs: Long?): String {
        val prefix = documentPrefix(documentUri)
        if (sizeBytes == null && lastModifiedMs == null) return "$prefix$EXTENSION"
        val version = sha1Hex("${sizeBytes ?: ""}\u0000${lastModifiedMs ?: ""}")
        return "$prefix-$version$EXTENSION"
    }

    const val EXTENSION = ".img"

    private fun sha1Hex(text: String): String {
        val bytes = MessageDigest.getInstance("SHA-1").digest(text.toByteArray(Charsets.UTF_8))
        return bytes.joinToString("") { "%02x".format(it.toInt() and 0xFF) }
    }
}

/**
 * The SAF scan's cache of embedded covers, in [dir]: one file per document, for
 * the version of the file it was extracted from (see [SafArtworkCacheKey]).
 *
 * One instance per walk. Dropping a document's older versions needs to know
 * which files are there, and the directory is listed once, the first time
 * that comes up, rather than once per file of a large library.
 *
 * Not thread-safe; a walk runs on one thread.
 */
internal class SafArtworkCache(private val dir: File) {
    /** The cover file names in [dir], by [SafArtworkCacheKey.documentPrefix]. */
    private var namesByDocument: MutableMap<String, MutableSet<String>>? = null

    /**
     * The cover cached for [documentUri] as the file is now, or null when none
     * is: never extracted, reclaimed by the OS, or extracted from an earlier
     * version of the file.
     */
    fun cached(documentUri: String, sizeBytes: Long?, lastModifiedMs: Long?): File? {
        val file = File(dir, SafArtworkCacheKey.fileName(documentUri, sizeBytes, lastModifiedMs))
        return if (file.isFile && file.length() > 0L) file else null
    }

    /**
     * Drops whatever is cached for [documentUri] other than its cover as the
     * file is now: covers of earlier versions of a file re-tagged in place, or
     * of another song saved over the same document, and the URI-only file a
     * cover was cached under before versions existed. None of those is this
     * file's cover any more, and nothing else would ever remove them.
     */
    fun dropOtherVersions(documentUri: String, sizeBytes: Long?, lastModifiedMs: Long?) {
        val keep = SafArtworkCacheKey.fileName(documentUri, sizeBytes, lastModifiedMs)
        val names = index()[SafArtworkCacheKey.documentPrefix(documentUri)] ?: return
        val iterator = names.iterator()
        while (iterator.hasNext()) {
            val name = iterator.next()
            if (name == keep) continue
            if (File(dir, name).delete() || !File(dir, name).exists()) iterator.remove()
        }
    }

    /**
     * Stores [picture] as [documentUri]'s cover for the file as it is now, and
     * returns the cached file, or null when it could not be written.
     *
     * Written to a temporary file and renamed into place, so an interrupted
     * scan never leaves a half-written cover that then fails to decode.
     */
    fun store(
        documentUri: String,
        sizeBytes: Long?,
        lastModifiedMs: Long?,
        picture: ByteArray,
    ): File? {
        if (!dir.isDirectory && !dir.mkdirs()) return null
        val name = SafArtworkCacheKey.fileName(documentUri, sizeBytes, lastModifiedMs)
        val target = File(dir, name)
        val tmp = File.createTempFile("art", ".tmp", dir)
        try {
            tmp.writeBytes(picture)
            if (!tmp.renameTo(target)) {
                tmp.delete()
                return null
            }
        } catch (e: Exception) {
            tmp.delete()
            return null
        }
        namesByDocument
            ?.getOrPut(SafArtworkCacheKey.documentPrefix(documentUri)) { mutableSetOf() }
            ?.add(name)
        return target
    }

    private fun index(): MutableMap<String, MutableSet<String>> {
        namesByDocument?.let { return it }
        val index = HashMap<String, MutableSet<String>>()
        for (name in dir.list() ?: emptyArray()) {
            if (!name.endsWith(SafArtworkCacheKey.EXTENSION)) continue
            // The prefix is a SHA-1 hex: 40 characters, then "-" or ".img".
            if (name.length < PREFIX_LENGTH) continue
            index.getOrPut(name.substring(0, PREFIX_LENGTH)) { mutableSetOf() }.add(name)
        }
        namesByDocument = index
        return index
    }

    private companion object {
        const val PREFIX_LENGTH = 40
    }
}
