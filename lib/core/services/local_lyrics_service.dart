import '../models/lyrics.dart';
import '../models/track.dart';
import '../sources/local/local_lyrics_reader.dart';
import 'lyrics_service.dart';
import 'lyrics_text_parser.dart';

/// A [LyricsService] for on-device tracks: it reads lyrics from a sidecar file
/// sitting next to the audio — `Song.lrc` (synced) or `Song.txt` (plain) beside
/// `Song.mp3` — located through a [LocalLyricsReader] (the Android binding finds
/// the sibling SAF document under the folder's existing grant; desktop reads the
/// neighbouring file). It slots into the same [CompositeLyricsService] seam as
/// the remote services, so local lyrics behave like provider lyrics in the UI.
///
/// Only on-device tracks are claimed: a Jellyfin (`jellyfin:`) or Subsonic
/// (`subsonic:`) track returns `null` so its own service answers — mirroring how
/// each remote service self-filters by URI scheme, and reusing the same
/// remote-scheme set as `LocalPlayableUriResolver`.
///
/// Local lyrics are deliberately *best-effort and silent*: unlike the remote
/// services (which throw so the UI can say "couldn't load"), a missing or
/// unreadable sidecar resolves to `null` → the calm "no lyrics" state. A read
/// failure never surfaces an error and never leaks the file's name or path.
/// `.lrc` is preferred over `.txt` so a track with both shows synced lyrics.
class LocalLyricsService implements LyricsService {
  const LocalLyricsService(this._reader);

  final LocalLyricsReader _reader;

  /// Remote schemes whose tracks this on-device service must not claim, leaving
  /// them to their own services. Kept in step with `LocalPlayableUriResolver`.
  static const Set<String> _remoteSchemes = <String>{'jellyfin', 'subsonic'};

  @override
  Future<Lyrics?> lyricsFor(Track track) async {
    if (!_isLocal(track.uri)) return null;
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

  /// Whether [uri] is an on-device track (anything that isn't a known remote
  /// scheme — a `content://` SAF document or a file path/URI), matching
  /// `LocalPlayableUriResolver.handles`.
  static bool _isLocal(String uri) {
    final Uri? parsed = Uri.tryParse(uri);
    final String scheme = parsed?.scheme.toLowerCase() ?? '';
    return !_remoteSchemes.contains(scheme);
  }
}
