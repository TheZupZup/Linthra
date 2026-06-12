import '../models/lyrics.dart';
import '../models/track.dart';
import 'lyrics_provider.dart';

/// The explicit "this source has no lyrics yet" placeholder.
///
/// Registering one (e.g. for Plex while its lyrics path is a follow-up) makes
/// the gap visible in the wiring and keeps that source's tracks on the calm
/// "no lyrics" state — resolved immediately, no I/O, never an error — instead
/// of falling through to another provider's backend by accident.
class NoLyricsProvider implements LyricsProvider {
  const NoLyricsProvider(this.sourceId);

  @override
  final String sourceId;

  @override
  Future<Lyrics?> lyricsFor(Track track) async => null;
}
