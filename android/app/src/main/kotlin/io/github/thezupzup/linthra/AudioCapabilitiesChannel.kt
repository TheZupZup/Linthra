package io.github.thezupzup.linthra

import android.media.MediaCodecList
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/**
 * Reports which audio decoders this device has, for the diagnostics report (#674).
 *
 * The question a silent-playback report needs answered is "could this device
 * decode that format at all, and with what?". This answers it directly:
 *
 *  * the SDK level and ABIs (Fire OS reports a build id, not a version, in
 *    `Platform.operatingSystemVersion`, so the Dart side cannot tell API 25 from
 *    API 30 on its own);
 *  * the platform decoders registered for FLAC, by codec name;
 *  * whether the bundled libFLAC fallback (Media3's FLAC module) loaded;
 *  * yes/no for a few other common formats.
 *
 * Only codec names, MIME types, the SDK integer and ABI names leave the device:
 * nothing about the user, their library or their servers. Linthra's player
 * uses the platform decoder when one handles FLAC and the fallback otherwise,
 * so these facts are enough to say which path FLAC takes on this device.
 *
 * Read-only and side-effect free. Only APIs from API 21 or earlier are used, so
 * it is safe on Linthra's API 24 minimum. The codec-list query can take a
 * noticeable moment on old devices (it parses the vendor codec XML the first
 * time), so it runs on [PlatformChannelWorker] rather than the platform thread,
 * on its own thread: the shared channel worker also runs SAF library scans,
 * and a long scan must not hold up the diagnostics report behind it. It runs
 * only when the diagnostics report is built, never during playback, and never
 * walks the music library.
 */
class AudioCapabilitiesChannel(
    private val worker: PlatformChannelWorker = PlatformChannelWorker(CODEC_QUERY),
) {
    fun configure(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getAudioCapabilities" ->
                    worker.submit(
                        work = { collect() },
                        onSuccess = { result.success(it) },
                        // The class name only: an exception message is free
                        // text and is not needed to diagnose anything here.
                        onFailure = {
                            result.error("audio_capabilities", it.javaClass.simpleName, null)
                        },
                    )
                else -> result.notImplemented()
            }
        }
    }

    private fun collect(): Map<String, Any> {
        val decoders = audioDecodersByMimeType()
        return mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "supportedAbis" to Build.SUPPORTED_ABIS.toList(),
            "flacPlatformDecoders" to (decoders[FLAC] ?: emptyList<String>()),
            "flacFallbackAvailable" to flacFallbackAvailable(),
            "platformDecoderMimeTypes" to
                REPORTED_MIME_TYPES.filter { decoders[it]?.isNotEmpty() == true },
        )
    }

    /** Decoder names per reported MIME type, from one pass over the codec list. */
    private fun audioDecodersByMimeType(): Map<String, List<String>> {
        val byType = HashMap<String, MutableList<String>>()
        for (info in MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos) {
            if (info.isEncoder) continue
            for (type in info.supportedTypes) {
                val mimeType = type.lowercase()
                if (mimeType in REPORTED_MIME_TYPES) {
                    byType.getOrPut(mimeType) { mutableListOf() }.add(info.name)
                }
            }
        }
        return byType
    }

    /**
     * Whether the bundled libflacJNI.so loads. This is the check Media3's
     * `FlacLibrary.isAvailable()` makes (a `System.loadLibrary` of the same name,
     * from this APK's own native library directory, never a path) before it
     * uses the fallback. Calling it directly keeps Media3's unstable API out of
     * app code. "No" means FLAC on a device without a platform decoder fails
     * with an unsupported-format error rather than playing.
     */
    private fun flacFallbackAvailable(): Boolean =
        try {
            System.loadLibrary(FLAC_JNI_LIBRARY)
            true
        } catch (e: UnsatisfiedLinkError) {
            false
        } catch (e: SecurityException) {
            false
        }

    companion object {
        const val CHANNEL = "io.github.thezupzup.linthra/audio_capabilities"

        // Separate from PlatformChannelWorker's shared executor, which queues
        // SAF scans. One daemon thread: the query is short and rare, and a
        // second report while one is running just waits for it.
        private val CODEC_QUERY: Executor =
            Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "linthra-audio-capabilities").apply { isDaemon = true }
            }

        private const val FLAC = "audio/flac"

        // Media3's FlacLibrary loads this name; built by
        // third_party/media3_decoder_flac/src/main/jni/CMakeLists.txt.
        private const val FLAC_JNI_LIBRARY = "flacJNI"

        // FLAC in detail (#674); the rest as a yes/no so a report about another
        // format shows at a glance whether the platform can decode it at all.
        private val REPORTED_MIME_TYPES = listOf(
            FLAC,
            "audio/mpeg",
            "audio/mp4a-latm",
            "audio/opus",
            "audio/vorbis",
            "audio/alac",
            "audio/raw",
        )
    }
}
