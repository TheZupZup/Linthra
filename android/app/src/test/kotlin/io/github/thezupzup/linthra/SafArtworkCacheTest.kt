package io.github.thezupzup.linthra

import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

// #742: the SAF scan cached a file's embedded cover under its document URI
// alone, so a cover re-tagged in place, or another song saved over the same
// document, kept serving the cover extracted first.
class SafArtworkCacheTest {
    private val song =
        "content://com.android.externalstorage.documents/tree/primary%3AMusic/" +
            "document/primary%3AMusic%2FAlbum%2F01%20Song.flac"
    private val other =
        "content://com.android.externalstorage.documents/tree/primary%3AMusic/" +
            "document/primary%3AMusic%2FAlbum%2F02%20Other.flac"

    private lateinit var dir: File

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("saf_artwork").toFile()
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
    }

    private fun names(): Set<String> = (dir.list() ?: emptyArray()).toSet()

    @Test
    fun theKeyIsStableForTheSameFile() {
        assertEquals(
            SafArtworkCacheKey.fileName(song, 4_000_000L, 1_700_000_000_000L),
            SafArtworkCacheKey.fileName(song, 4_000_000L, 1_700_000_000_000L),
        )
    }

    @Test
    fun aRewriteMovesTheKey() {
        val before = SafArtworkCacheKey.fileName(song, 4_000_000L, 1_700_000_000_000L)
        // Re-tagged: the tag block grew, and the file was written again.
        assertNotEquals(before, SafArtworkCacheKey.fileName(song, 4_000_512L, 1_700_000_000_000L))
        assertNotEquals(before, SafArtworkCacheKey.fileName(song, 4_000_000L, 1_700_000_900_000L))
        // Another document is never the same key either.
        assertNotEquals(before, SafArtworkCacheKey.fileName(other, 4_000_000L, 1_700_000_000_000L))
    }

    @Test
    fun aSizeAndATimeThatSwapPlacesAreNotTheSameFile() {
        assertNotEquals(
            SafArtworkCacheKey.fileName(song, 12L, 34L),
            SafArtworkCacheKey.fileName(song, 34L, 12L),
        )
        assertNotEquals(
            SafArtworkCacheKey.fileName(song, 12L, null),
            SafArtworkCacheKey.fileName(song, null, 12L),
        )
    }

    @Test
    fun withNoStampTheNameIsTheOneCoversHadBefore() {
        // A provider that reports neither keeps the covers it already had.
        assertEquals(
            "b2bfbf897371c103433e7ba7bdce4ea6cbb5f1bf.img",
            SafArtworkCacheKey.fileName("content://example/doc", null, null),
        )
    }

    @Test
    fun everyVersionOfADocumentSharesItsPrefixAndNoNameCarriesThePath() {
        val prefix = SafArtworkCacheKey.documentPrefix(song)
        for (name in listOf(
            SafArtworkCacheKey.fileName(song, null, null),
            SafArtworkCacheKey.fileName(song, 1L, 2L),
            SafArtworkCacheKey.fileName(song, 3L, null),
        )) {
            assertTrue(name, name.startsWith(prefix))
            assertTrue(name, name.endsWith(".img"))
            assertFalse(name, name.contains("Song"))
            assertFalse(name, name.contains("Music"))
        }
        assertFalse(SafArtworkCacheKey.fileName(other, 1L, 2L).startsWith(prefix))
    }

    @Test
    fun aCoverIsServedForTheFileItWasExtractedFrom() {
        val cache = SafArtworkCache(dir)
        assertNull(cache.cached(song, 100L, 1L))

        val stored = cache.store(song, 100L, 1L, byteArrayOf(1, 2, 3))

        assertNotNull(stored)
        val again = SafArtworkCache(dir).cached(song, 100L, 1L)
        assertEquals(stored, again)
        assertArrayEquals(byteArrayOf(1, 2, 3), again!!.readBytes())
    }

    @Test
    fun aFileRetaggedInPlaceMissesAndItsOldCoverGoes() {
        val first = SafArtworkCache(dir)
        val oldCover = first.store(song, 100L, 1L, byteArrayOf(1))!!
        val otherCover = first.store(other, 200L, 1L, byteArrayOf(9))!!

        // The next walk, after the cover was replaced in the file.
        val next = SafArtworkCache(dir)
        assertNull(next.cached(song, 120L, 5L))
        next.dropOtherVersions(song, 120L, 5L)
        val newCover = next.store(song, 120L, 5L, byteArrayOf(2))!!

        assertNotEquals(oldCover, newCover)
        assertFalse(oldCover.exists())
        assertArrayEquals(byteArrayOf(2), next.cached(song, 120L, 5L)!!.readBytes())
        assertTrue("another document's cover is left alone", otherCover.exists())
        assertEquals(setOf(newCover.name, otherCover.name), names())
    }

    @Test
    fun aCoverRemovedFromTheFileTakesTheCachedOneWithIt() {
        val oldCover = SafArtworkCache(dir).store(song, 100L, 1L, byteArrayOf(1))!!

        val next = SafArtworkCache(dir)
        assertNull(next.cached(song, 90L, 5L))
        next.dropOtherVersions(song, 90L, 5L)

        assertFalse(oldCover.exists())
        assertTrue(names().isEmpty())
    }

    @Test
    fun theCoverCachedBeforeVersionsExistedIsDroppedOnce() {
        // What an earlier version left: the URI-only name.
        val legacy = File(dir, SafArtworkCacheKey.fileName(song, null, null))
        legacy.writeBytes(byteArrayOf(7))

        val cache = SafArtworkCache(dir)
        assertNull(cache.cached(song, 100L, 1L))
        cache.dropOtherVersions(song, 100L, 1L)
        cache.store(song, 100L, 1L, byteArrayOf(8))

        assertFalse(legacy.exists())
        assertEquals(setOf(SafArtworkCacheKey.fileName(song, 100L, 1L)), names())
    }

    @Test
    fun anEmptyCacheFileIsNotACover() {
        File(dir, SafArtworkCacheKey.fileName(song, 100L, 1L)).writeBytes(ByteArray(0))

        assertNull(SafArtworkCache(dir).cached(song, 100L, 1L))
    }

    @Test
    fun aDirectoryThatIsNotThereYetIsCreatedOnTheFirstStore() {
        val missing = File(dir, "linthra_local_artwork")
        val cache = SafArtworkCache(missing)

        cache.dropOtherVersions(song, 100L, 1L)
        val stored = cache.store(song, 100L, 1L, byteArrayOf(5))

        assertNotNull(stored)
        assertTrue(stored!!.isFile)
        // Nothing half-written is left behind.
        assertEquals(setOf(stored.name), (missing.list() ?: emptyArray()).toSet())
    }
}
