import '../models/lyrics.dart';
import '../models/track.dart';
import 'lyrics_service.dart';

/// A [LyricsService] that delegates to several backends in order, returning the
/// first one that has lyrics for the track.
///
/// Each backend self-filters by the track's URI scheme (a Jellyfin service
/// ignores `subsonic:` tracks and vice versa), so for any given track at most
/// one backend does real work — the order is just "ask each until one answers".
/// A backend that *throws* (e.g. the owning server is offline) propagates, so
/// the UI can still tell "couldn't load" apart from "no lyrics". Resolves to
/// `null` when every backend declines, which the UI shows as the calm empty
/// state.
class CompositeLyricsService implements LyricsService {
  CompositeLyricsService(this._services);

  final List<LyricsService> _services;

  @override
  Future<Lyrics?> lyricsFor(Track track) async {
    for (final LyricsService service in _services) {
      final Lyrics? lyrics = await service.lyricsFor(track);
      if (lyrics != null) return lyrics;
    }
    return null;
  }
}
