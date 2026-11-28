import '../../native/api/subsonic.dart' as rust;
import '../../native/linthra_bridge.dart';
import 'subsonic_api.dart';
import 'subsonic_exception.dart';

export '../../native/api/subsonic.dart'
    show SubsonicLyricLine, SubsonicOutcome, SubsonicRead, SubsonicReply;

/// Reads a Subsonic server's answer in the Rust core
/// (native/linthra_core/src/subsonic/): the `subsonic-response` envelope and
/// whatever [what] asks for. The requests themselves still go out from Dart.
Future<rust.SubsonicReply> readSubsonicAnswer(
  List<int> body,
  rust.SubsonicRead what,
) async {
  await LinthraBridgeLoader.ensureReady();
  return rust.readSubsonic(body: body, what: what);
}

/// [reply], or the friendly error it stands for: not a Subsonic answer at
/// all, or the Subsonic error inside it ([errorFor] maps its code).
rust.SubsonicReply okOrThrow(
  rust.SubsonicReply reply,
  SubsonicException Function(int? code) errorFor,
) =>
    switch (reply.outcome) {
      rust.SubsonicOutcome.ok => reply,
      rust.SubsonicOutcome.failed => throw errorFor(reply.errorCode),
      rust.SubsonicOutcome.notSubsonic => throw SubsonicException.notSubsonic(),
    };

SubsonicServerInfo serverInfoOf(rust.SubsonicReply reply) => SubsonicServerInfo(
      apiVersion: reply.version,
      type: reply.serverType,
      serverVersion: reply.serverVersion,
    );

SubsonicArtistDto artistDto(rust.SubsonicArtist a) => SubsonicArtistDto(
      id: a.id,
      name: a.name,
      albumCount: a.albumCount,
      coverArt: a.coverArt,
    );

SubsonicAlbumDto albumDto(rust.SubsonicAlbum a) => SubsonicAlbumDto(
      id: a.id,
      name: a.name,
      artist: a.artist,
      songCount: a.songCount,
      year: a.year,
      dateCreated: DateTime.tryParse(a.created ?? ''),
      coverArt: a.coverArt,
    );

SubsonicSongDto songDto(rust.SubsonicSong s) => SubsonicSongDto(
      id: s.id,
      title: s.title,
      album: s.album,
      albumId: s.albumId,
      artist: s.artist,
      track: s.track,
      durationSeconds: s.durationSeconds,
      dateCreated: DateTime.tryParse(s.created ?? ''),
      coverArt: s.coverArt,
    );

SubsonicPlaylistDto playlistDto(rust.SubsonicNamed p) =>
    SubsonicPlaylistDto(id: p.id, name: p.name);
