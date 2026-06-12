import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/plex/plex_music_source.dart';

/// Internal Plex wiring — deliberately invisible to users.
///
/// This is the "register the provider" step of the Plex plan (issue #178 /
/// docs/plex.md): the playback router and the render-time artwork seam read
/// this provider, so `plex:<ratingKey>` track URIs and `plex-thumb:` artwork
/// references are recognized end to end. There is **no** Plex entry in
/// Settings, no sign-in screen, and no library picker yet, so in production
/// nothing can ever supply a session: this stays `null`, every `plex:` track
/// fails resolution with a friendly "not signed in", and every `plex-thumb:`
/// reference falls back to the artwork placeholder. Plex stays completely
/// invisible until the connection UI ships.
///
/// The settings controller PR will replace this default with the real session
/// lifecycle (manual-token sign-in, persisted via the encrypted
/// `PlexSessionStore`, library-section selection), exactly like
/// `jellyfinMusicSourceProvider` / `subsonicMusicSourceProvider` derive from
/// their controllers. Everything downstream is already wired through this
/// seam, so that PR only has to make it return a real source. Tests override
/// it (with a `PlexMusicSource` built on a `FakePlexClient`) to exercise the
/// signed-in paths today.
final plexMusicSourceProvider = Provider<PlexMusicSource?>((ref) => null);
