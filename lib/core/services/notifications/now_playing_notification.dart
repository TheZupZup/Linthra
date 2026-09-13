import '../../models/track.dart';
import '../media_artwork_source.dart';
import 'desktop_notifier.dart';

/// The heading used when a track carries no title at all.
///
/// A file with no tags still has a path, and the path is exactly what must
/// never be shown: a notification is drawn by another process and, on most
/// desktops, kept in a tray the whole session. "Unknown track" says as much as
/// can be said safely.
const String kUnknownTrackNotificationTitle = 'Unknown track';

/// Builds the "now playing" notification for [track].
///
/// This is the whole of what Linthra is willing to tell a notification daemon,
/// and it is deliberately a pure function: everything that decides what may
/// leave the app happens here, in one place a reviewer can read, rather than
/// inside the D-Bus call.
///
/// **What goes out.** The title and the catalog's own "Artist • Album"
/// subtitle: the same two lines the in-app mini player draws.
///
/// **What never does.** No [Track.uri] (a remote track's is a stream URL that
/// can carry a provider credential; a local one's is the listener's own file
/// path), no [Track.id], no album id, no server address, and no cover
/// reference. None of them would help a shell draw a card, and a notification
/// leaves the sandbox and usually outlives the track.
///
/// **Artwork, when it is safely supported.** The same rule the MPRIS session
/// publishes `mpris:artUrl` under, narrowed for a consumer that loads files
/// rather than URLs:
///
///  * a `file:` cover passes through. Every `file:` cover in the catalog is a
///    copy Linthra itself wrote into its own artwork cache (embedded local art
///    via `LocalArtworkCache`, or Android's SAF walk): a credential-free file
///    under the application cache directory, which resolves to the same path
///    inside a Flatpak and outside it, so the daemon can actually open it;
///  * an app-internal reference (`subsonic-cover:<id>`, `plex-thumb:<path>`)
///    is only ever published as the local copy the media-artwork cache has
///    *already* fetched. Nothing is fetched here: this runs on a track change
///    and must not wait on a server;
///  * an `http(s)` cover is dropped. A notification daemon does not fetch
///    URLs for an image, so it would buy nothing, and "a cover URL" is the
///    shape a credentialed one would arrive in;
///  * a `content:` cover is dropped. That is Android's FileProvider form, and
///    nothing on a Linux desktop can open it.
DesktopNotification nowPlayingNotification(
  Track track, {
  MediaArtworkSource? artwork,
}) {
  final String title = track.title.trim();
  return DesktopNotification(
    title: title.isEmpty ? kUnknownTrackNotificationTitle : title,
    body: track.artistAlbumLabel,
    image: safeNotificationImage(track.artworkUri, artwork: artwork),
  );
}

/// The cover a notification daemon may be handed for [artworkUri], or null.
///
/// Exposed separately from [nowPlayingNotification] because it is the part
/// worth testing on its own: it is the filter that decides whether a reference
/// leaves the app, and every scheme it lets through has to be a local file
/// Linthra wrote. See [nowPlayingNotification] for why each answer is what it
/// is.
Uri? safeNotificationImage(
  Uri? artworkUri, {
  MediaArtworkSource? artwork,
}) {
  if (artworkUri == null) return null;
  if (artworkUri.isScheme('file')) return artworkUri;
  if (artworkUri.isScheme('content') ||
      artworkUri.isScheme('http') ||
      artworkUri.isScheme('https')) {
    return null;
  }
  // An app-internal reference: publish it only once its credential-free copy
  // is on disk. `cachedFileUri` is synchronous and starts no fetch, so a cover
  // that has not been warmed yet simply means a notification without one.
  return artwork?.cachedFileUri(artworkUri);
}
