import '../models/lyrics.dart';
import '../models/track.dart';
import '../sources/local/local_lyrics_reader.dart';
import '../sources/music_provider.dart';
import 'lyrics_provider.dart';
import 'lyrics_text_parser.dart';

/// The [LyricsProvider] for on-device tracks: it reads lyrics from a sidecar
/// file sitting next to the audio — `Song.lrc` (synced) or `Song.txt` (plain)
/// beside `Song.mp3` — located through a [LocalLyricsReader] (the Android
/// binding finds the sibling SAF document under the folder's existing grant;
/// desktop reads the neighbouring file).
///
/// Which tracks reach this class is the [LyricsResolver]'s job: a track is
/// routed here only when `MusicProviders.forTrackUri` says the on-device
/// source owns it. That registry is the single place that knows every remote
/// scheme, so this class keeps no "schemes that aren't mine" blacklist of its
/// own — the kind of list that went stale when `plex:` arrived and would have
/// sent Plex tracks to the sidecar reader.
///
/// Local lyrics are deliberately *best-effort and silent*: unlike the remote
/// providers (which throw so the UI can say "couldn't load"), a missing or
/// unreadable sidecar resolves to `null` → the calm "no lyrics" state. A read
/// failure never surfaces an error and never leaks the file's name or path.
/// `.lrc` is preferred over `.txt` so a track with both shows synced lyrics.
class LocalLyricsProvider implements LyricsProvider {
  const LocalLyricsProvider(this._reader);

  final LocalLyricsReader _reader;

  @override
  String get sourceId => MusicProviders.local.sourceId;

  @override
  Future<Lyrics?> lyricsFor(Track track) async {
    // Prefer a synced `.lrc`; fall back to a plain `.txt`.
    final Lyrics? synced =
        await _read(track.uri, 'lrc', LyricsTextParser.parseLrc);
    if (synced != null) return synced;
    return _read(track.uri, 'txt', LyricsTextParser.parsePlain);
  }

  /// Reads the sidecar with [extension] and runs [parse] on it, returning the
  /// resulting non-empty [Lyrics] or `null`. Any reader error is swallowed (fail
  /// silently → "no lyrics"); the reader's own contract is to not throw, but the
  /// guard means a misbehaving binding can't break the lyrics screen either.
  Future<Lyrics?> _read(
    String uri,
    String extension,
    Lyrics? Function(String) parse,
  ) async {
    String? text;
    try {
      text = await _reader.readSidecar(uri, extension);
    } catch (_) {
      return null;
    }
    if (text == null) return null;
    final Lyrics? lyrics = parse(text);
    return (lyrics != null && lyrics.isNotEmpty) ? lyrics : null;
  }
}
