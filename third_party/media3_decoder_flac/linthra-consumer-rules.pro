# Linthra's keep rules for the vendored Media3 FLAC module.
#
# Media3 finds this module only by reflection: DefaultRenderersFactory loads
# LibflacAudioRenderer by name when extension renderers are on, and
# DefaultExtractorsFactory asks FlacLibrary whether the native library loaded.
# Media3's own consumer rules keep those members but not the classes, which
# leaves the fallback relying on R8 tracing a constant Class.forName string. Keep
# them outright, so shrinking can never quietly remove the FLAC fallback and put
# old devices back into silent playback (#674).
-keep class androidx.media3.decoder.flac.LibflacAudioRenderer {
  <init>(android.os.Handler, androidx.media3.exoplayer.audio.AudioRendererEventListener, androidx.media3.exoplayer.audio.AudioSink);
}
-keep class androidx.media3.decoder.flac.FlacLibrary {
  public static boolean isAvailable();
}
