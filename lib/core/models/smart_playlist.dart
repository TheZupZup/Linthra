import 'package:flutter/foundation.dart';

/// The kinds of automatic "smart mix" Linthra builds from on-device signals.
///
/// Each kind is derived from data the app already has — library timestamps,
/// playback history, favourites, the offline cache, or just the catalog — so a
/// mix needs no manual curation and works across local, Jellyfin, and
/// Navidrome/Subsonic tracks wherever that data exists.
enum SmartPlaylistKind {
  recentlyAdded,
  recentlyPlayed,
  mostPlayed,
  favorites,
  downloaded,
  random,
  neverPlayed;

  /// The stable id used in routing (`kind.name`).
  String get id => name;

  /// Parses a routing [id] back to a kind, or `null` for an unknown value so a
  /// stale/forward link can show a friendly "not found" rather than crash.
  static SmartPlaylistKind? fromId(String? id) {
    for (final SmartPlaylistKind kind in SmartPlaylistKind.values) {
      if (kind.id == id) return kind;
    }
    return null;
  }
}

/// A single automatic mix: its [kind] plus the title/description the UI shows.
///
/// Carries no tracks — those are resolved on demand by `SmartPlaylistResolver`
/// from the live catalog and on-device signals, so a mix is always current and
/// never persists track ids or any secret.
@immutable
class SmartPlaylist {
  const SmartPlaylist({
    required this.kind,
    required this.title,
    required this.description,
  });

  final SmartPlaylistKind kind;
  final String title;
  final String description;

  String get id => kind.id;

  /// The canonical mix for [kind], with its app-facing copy.
  factory SmartPlaylist.forKind(SmartPlaylistKind kind) {
    switch (kind) {
      case SmartPlaylistKind.recentlyAdded:
        return const SmartPlaylist(
          kind: SmartPlaylistKind.recentlyAdded,
          title: 'Recently added',
          description: 'New in your library',
        );
      case SmartPlaylistKind.recentlyPlayed:
        return const SmartPlaylist(
          kind: SmartPlaylistKind.recentlyPlayed,
          title: 'Recently played',
          description: 'Jump back in',
        );
      case SmartPlaylistKind.mostPlayed:
        return const SmartPlaylist(
          kind: SmartPlaylistKind.mostPlayed,
          title: 'Most played',
          description: 'The songs you reach for',
        );
      case SmartPlaylistKind.favorites:
        return const SmartPlaylist(
          kind: SmartPlaylistKind.favorites,
          title: 'Favorites',
          description: 'Tracks you’ve liked',
        );
      case SmartPlaylistKind.downloaded:
        return const SmartPlaylist(
          kind: SmartPlaylistKind.downloaded,
          title: 'Downloaded',
          description: 'Available offline',
        );
      case SmartPlaylistKind.random:
        return const SmartPlaylist(
          kind: SmartPlaylistKind.random,
          title: 'Random mix',
          description: 'A fresh shuffle every time',
        );
      case SmartPlaylistKind.neverPlayed:
        return const SmartPlaylist(
          kind: SmartPlaylistKind.neverPlayed,
          title: 'Never played',
          description: 'Hidden gems you haven’t heard yet',
        );
    }
  }

  /// Every mix, in the order shown in the "Smart mixes" section.
  static List<SmartPlaylist> get all => <SmartPlaylist>[
        for (final SmartPlaylistKind kind in SmartPlaylistKind.values)
          SmartPlaylist.forKind(kind),
      ];
}
