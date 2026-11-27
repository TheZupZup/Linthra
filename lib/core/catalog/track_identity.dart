import '../models/track.dart';
import '../sources/music_provider.dart';

/// The `sourceId` of the provider that owns [track], derived from its opaque
/// `scheme:` URI (`jellyfin:` / `subsonic:` / a local path). This is the same
/// mapping the capability model and the playback resolvers key off, so source
/// identity can never disagree across the app.
String trackSourceId(Track track) =>
    MusicProviders.forTrackUri(track.uri).sourceId;
