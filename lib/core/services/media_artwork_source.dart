import 'dart:async';

import '../models/persisted_playback_session.dart';

/// A synchronous source of already-fetched, safe **local** media-session
/// artwork — the seam the media handler reads while building a `MediaItem`,
/// without ever awaiting or triggering a fetch on the playback path.
///
/// Backed by `MediaArtworkCache`, whose covers are warmed ahead of time by
/// `MediaArtworkPrewarmService` so a track's cover is usually cached *before* it
/// reaches the now-playing card — beating the head unit's metadata snapshot at
/// the track change (a plain late-arriving cover is ignored by many head units).
abstract interface class MediaArtworkSource {
  /// The safe `content://` URI for [reference] if it has already been fetched
  /// and cached, else `null`. Synchronous and side-effect-free — it never starts
  /// a fetch, so reading it while building a `MediaItem` can't block playback or
  /// put a credential in `artUri`.
  Uri? cached(Uri reference);

  /// The same cached cover as a `file:` URI, or `null` when it is not cached.
  ///
  /// [cached] hands back the Android `content://` form, which only a platform
  /// with the FileProvider can open. A Linux desktop shell reading
  /// `mpris:artUrl` needs the file itself. Same entry, same privacy properties
  /// (the basename is a hash of the credential-free reference), different
  /// wrapper for a different consumer.
  Uri? cachedFileUri(Uri reference);

  /// Emits a [reference] the moment its cover first becomes cached (so [cached]
  /// would now return a URI for it). Lets a now-playing item that was published
  /// without art be refreshed at once — instead of waiting for the next playback
  /// tick — when its cover finishes warming. Broadcast; emits at most once per
  /// reference.
  Stream<Uri> get coverReady;
}

/// Whether [uri] is a cover the platform media session can load by itself — a
/// private `file:`, a remote token-free `http`/`https` image (e.g. Jellyfin), or
/// an app `content:` URI. Any other scheme is an app-internal *reference* (e.g.
/// Subsonic's `subsonic-cover:<id>`) that must first be fetched to a local file
/// (see `MediaArtworkCache`) before it can be shown on the media session.
///
/// An `http`/`https` cover that carries a credential is never one: whatever
/// it is handed to (the system media session, Android Auto, a desktop shell)
/// would get the credential with it.
bool isPlatformLoadableArtwork(Uri uri) =>
    uri.isScheme('file') ||
    ((uri.isScheme('http') || uri.isScheme('https')) &&
        isPersistableArtworkUri(uri)) ||
    uri.isScheme('content');
