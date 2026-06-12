import '../models/lyrics.dart';
import '../models/track.dart';
import '../sources/music_provider.dart';
import 'lyrics_diagnostics.dart';
import 'lyrics_provider.dart';
import 'lyrics_service.dart';

/// Routes a lyrics lookup to the [LyricsProvider]s registered for the source
/// that owns the track.
///
/// The owner is decided by [MusicProviders.forTrackUri] — the same `scheme:`
/// registry playback resolution and the capability matrix key off — so lyrics
/// routing can never drift from how the rest of the app classifies a track.
/// Providers registered for that source are asked in registration order and
/// the first one with lyrics wins (a same-source fallback chain: e.g. a
/// sidecar-file reader ahead of a future embedded-tag reader). Providers for
/// *other* sources are never consulted: source ids are scheme-scoped, so a
/// `plex:` rating key must never be looked up against a Jellyfin server or a
/// sidecar reader.
///
/// Missing lyrics are not an error: a source with no registered provider, a
/// [NoLyricsProvider] placeholder, or every provider declining all resolve to
/// `null` — the UI's calm "No lyrics available" state. A provider that
/// *throws* (its server is offline, the session expired) propagates, so the UI
/// can still tell "couldn't load" apart from "no lyrics"; the failure is
/// logged by type only (never the message) through [LyricsDiagnostics].
///
/// Lookups happen on demand, off the playback path: a slow provider can delay
/// the lyrics panel, never the audio.
class LyricsResolver implements LyricsService {
  const LyricsResolver(this._providers);

  /// The honest empty resolver: no providers registered, every track resolves
  /// to "no lyrics". The default binding for tests and local-only use.
  static const LyricsResolver none = LyricsResolver(<LyricsProvider>[]);

  final List<LyricsProvider> _providers;

  @override
  Future<Lyrics?> lyricsFor(Track track) async {
    final String sourceId = MusicProviders.forTrackUri(track.uri).sourceId;
    bool consulted = false;
    for (final LyricsProvider provider in _providers) {
      if (provider.sourceId != sourceId) continue;
      consulted = true;
      final String name = provider.runtimeType.toString();
      final Lyrics? lyrics;
      try {
        lyrics = await provider.lyricsFor(track);
      } catch (error) {
        _log(sourceId, name, LyricsDiagnostics.failed(error), track);
        rethrow;
      }
      if (lyrics != null) {
        _log(sourceId, name, LyricsDiagnostics.found(lyrics.isSynced), track);
        return lyrics;
      }
    }
    _log(sourceId, consulted ? 'declined' : 'unregistered',
        LyricsDiagnostics.none, track);
    return null;
  }

  static void _log(String source, String provider, String outcome, Track t) {
    LyricsDiagnostics.lookedUp(
      source: source,
      provider: provider,
      outcome: outcome,
      trackId: t.id,
    );
  }
}
