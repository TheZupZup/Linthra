import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import '../../../shared/widgets/now_playing_indicator.dart';
import '../now_playing.dart';
import 'album_artwork.dart';

/// Album artwork for a track row, with the [NowPlayingIndicator] overlaid when
/// [nowPlaying] says this row is the current track.
///
/// Centralizes the artwork-plus-overlay so every track-row surface (library,
/// search, album/artist/mix detail, playlists, downloads) marks the playing song
/// the same way — the indicator animates while playing and rests while paused,
/// over a subtle scrim so the cover stays legible.
class TrackArtwork extends StatelessWidget {
  const TrackArtwork({
    required this.artworkUri,
    required this.nowPlaying,
    this.dimension = 48,
    this.borderRadius = const BorderRadius.all(Radius.circular(AppRadii.sm)),
    super.key,
  });

  final Uri? artworkUri;

  /// This row's now-playing state, or null when it is not the current track.
  final NowPlayingRowState? nowPlaying;

  final double dimension;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: dimension,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          AlbumArtwork(artworkUri: artworkUri, borderRadius: borderRadius),
          if (nowPlaying != null)
            NowPlayingIndicator(
              overlay: true,
              animating: nowPlaying == NowPlayingRowState.playing,
              borderRadius: borderRadius,
            ),
        ],
      ),
    );
  }
}
