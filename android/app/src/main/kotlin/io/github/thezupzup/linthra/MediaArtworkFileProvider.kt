package io.github.thezupzup.linthra

import android.content.Intent
import android.net.Uri
import android.os.ParcelFileDescriptor
import androidx.core.content.FileProvider
import java.io.FileNotFoundException

/**
 * FileProvider for Navidrome/Subsonic media-session cover art that also grants
 * the platform media consumers temporary **read** access to each cover URI.
 *
 * Why this exists: the platform media session loads `MediaItem.artUri` in the
 * consumer's *own* process (Android Auto's, SystemUI's for the lock screen,
 * Bluetooth AVRCP), not Linthra's. The provider is `exported="false"`, so those
 * processes get a permission denial and the cover never shows — even though
 * `audio_service` already decoded the same URI in *Linthra's* process to embed
 * the bitmap. So when Linthra opens a cover here (which `audio_service` does at
 * metadata-publish time, just before the metadata — carrying the very same URI —
 * is delivered to those consumers), we grant each consumer read access to that
 * exact URI. By the time the consumer reads it, the grant is already in place.
 *
 * Privacy/security: the grant is **read-only** and only ever for these cover
 * URIs, which are credential-free album art with SHA-256 filenames — no
 * username, password, token, salt, server URL, or auth query is ever exposed.
 * The provider stays `exported="false"`; nothing is world-readable. Granting is
 * best-effort and never touches playback. It runs *only* when a cover from this
 * provider is opened, so it never runs for Jellyfin (`http`) or local (`file`)
 * artwork, which are not served here.
 */
class MediaArtworkFileProvider : FileProvider() {
    // FileProvider.openFile returns a nullable ParcelFileDescriptor?, so the
    // override must match (Kotlin rejects narrowing it to non-null).
    @Throws(FileNotFoundException::class)
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        grantReadToMediaConsumers(uri)
        return super.openFile(uri, mode)
    }

    private fun grantReadToMediaConsumers(uri: Uri) {
        val ctx = context ?: return
        for (consumer in MEDIA_CONSUMER_PACKAGES) {
            try {
                ctx.grantUriPermission(
                    consumer,
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            } catch (_: Exception) {
                // Best-effort: a consumer that isn't installed (or a grant that
                // fails) just means that surface can't read this one cover. It
                // never affects playback and never leaks anything.
            }
        }
    }

    private companion object {
        /**
         * The platform components that render MediaSession album art in their own
         * process and therefore need read access to the cover `content://` URI.
         * Kept to the well-known media hosts; an un-installed one is skipped.
         */
        val MEDIA_CONSUMER_PACKAGES = listOf(
            "com.google.android.projection.gearhead", // Android Auto (phone)
            "com.android.systemui", // lock screen / notification shade
            "com.android.bluetooth", // Bluetooth AVRCP metadata
        )
    }
}
