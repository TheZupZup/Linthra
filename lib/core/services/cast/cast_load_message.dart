import '../../models/cast_media.dart';

/// Builds the Google Cast v2 `LOAD` message (and the `MediaInformation` /
/// metadata blocks inside it) for a [CastMedia], in one tested place.
///
/// Keeping this here — rather than inline in [ChromecastCastTransport] — means
/// the transport stays a thin socket adapter, metadata formatting never scatters
/// across the app or into a widget, and the exact wire shape the receiver sees
/// is unit-testable (the transport itself can't be, since it opens a real
/// socket).
///
/// What the receiver shows: the **default media receiver** renders this
/// metadata — track title, artist, album, artwork — and uses [CastMedia.duration]
/// for the seek-bar length. That metadata is the *only* Linthra-specific content
/// the default receiver can display; the receiver's own app name and logo are
/// fixed by the receiver application and **cannot** be set from a sender, so true
/// "Linthra" branding on the device would require shipping a custom Cast receiver
/// app (out of scope). See docs/cast.md.
///
/// Security: `contentId` is the one field that legitimately carries the
/// authenticated stream URL — the receiver fetches the bytes itself, so the
/// token must be in it. Nothing else does: the metadata block holds only display
/// text and a token-free artwork URL (Jellyfin's public image; Subsonic omits
/// artwork rather than embed its credential). This message is handed straight to
/// the cast session and is never logged or persisted.
abstract final class CastLoadMessage {
  /// The Cast `MusicTrackMediaMetadata` discriminator (per the Cast media
  /// metadata types), so the receiver renders title/artist/album as a track.
  static const int musicTrackMetadataType = 3;

  /// The default media receiver streams a fully-buffered remote URL (as opposed
  /// to a `LIVE` stream).
  static const String bufferedStreamType = 'BUFFERED';

  /// The complete `LOAD` payload for [media], tagged with [requestId]. Autoplays
  /// from the start; the receiver replies with a `MEDIA_STATUS` carrying the new
  /// media session id.
  static Map<String, dynamic> build(
    CastMedia media, {
    required int requestId,
  }) {
    return <String, dynamic>{
      'type': 'LOAD',
      'requestId': requestId,
      'autoplay': true,
      'currentTime': 0,
      'media': mediaInfo(media),
    };
  }

  /// The Cast `MediaInformation` object for [media]: what to fetch, how to
  /// decode it, its duration (when known), and the metadata the receiver
  /// displays.
  static Map<String, dynamic> mediaInfo(CastMedia media) {
    final Duration? duration = media.duration;
    return <String, dynamic>{
      'contentId': media.url.toString(),
      'contentType': media.contentType,
      'streamType': bufferedStreamType,
      if (duration != null && duration > Duration.zero)
        'duration': duration.inMilliseconds / 1000.0,
      'metadata': metadata(media),
    };
  }

  /// The Cast `MusicTrackMediaMetadata` the receiver renders. Carries only
  /// display fields and a token-free artwork URL — never the stream token.
  static Map<String, dynamic> metadata(CastMedia media) {
    final Uri? artworkUrl = media.artworkUrl;
    return <String, dynamic>{
      'metadataType': musicTrackMetadataType,
      if (media.title != null) 'title': media.title,
      if (media.artist != null) 'artist': media.artist,
      if (media.album != null) 'albumName': media.album,
      if (artworkUrl != null)
        'images': <Map<String, dynamic>>[
          <String, dynamic>{'url': artworkUrl.toString()},
        ],
    };
  }
}
