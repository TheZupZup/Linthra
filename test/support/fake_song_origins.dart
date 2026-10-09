import 'dart:async';

import 'package:linthra/core/services/song_origins.dart';

/// A [SongOrigins] whose signed-in origins a test sets by scheme, for
/// switching servers (#795).
class FakeSongOrigins implements SongOrigins {
  FakeSongOrigins({
    Map<String, String?>? signedIn,
    Map<String, String>? legacy,
  })  : signedIn = <String, String?>{...?signedIn},
        legacyOrigins = <String, String>{...?legacy};

  /// The origin signed in now, by scheme (`subsonic:`). Absent or null:
  /// signed out.
  final Map<String, String?> signedIn;

  /// What older references of each scheme were settled to.
  final Map<String, String> legacyOrigins;

  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// Signs [scheme] in to [origin] (null: out), and says so.
  void signIn(String scheme, String? origin) {
    signedIn[scheme] = origin;
    _changes.add(null);
  }

  @override
  bool binds(String trackUri) => boundSongScheme(trackUri) != null;

  @override
  String? current(String trackUri) {
    final String? scheme = boundSongScheme(trackUri);
    return scheme == null ? null : signedIn[scheme];
  }

  @override
  String? legacy(String trackUri) {
    final String? scheme = boundSongScheme(trackUri);
    return scheme == null ? null : legacyOrigins[scheme];
  }

  @override
  Stream<void> get changes => _changes.stream;

  Future<void> close() => _changes.close();
}
