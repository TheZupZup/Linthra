import 'package:flutter/material.dart';

import '../../../shared/widgets/now_playing_indicator.dart';
import '../../player/now_playing.dart';

/// The number gutter at the start of a row on an album's own page, on desktop.
///
/// Every row there would otherwise repeat the same cover, so the row leads
/// with what a desktop player shows instead: the track's number, or the
/// now-playing bars on the song that is playing. Numbers are end-aligned with
/// same-width digits, so 9 and 10 line up on their last digit.
///
/// A track with no number keeps the gutter empty, so its title still lines up
/// with the rest.
class AlbumTrackNumber extends StatelessWidget {
  const AlbumTrackNumber({
    required this.trackNumber,
    required this.nowPlaying,
    super.key,
  });

  final int? trackNumber;

  /// This row's now-playing state, or null when it is not the current track.
  final NowPlayingRowState? nowPlaying;

  /// Room for three digits at the reading size, before any text scaling.
  static const double _width = 28;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final NowPlayingRowState? playing = nowPlaying;
    final int? number = trackNumber;
    return SizedBox(
      // Grows with the text, so a larger reading size still fits the digits.
      width: MediaQuery.textScalerOf(context).scale(_width),
      child: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: playing != null
            ? NowPlayingIndicator(
                animating: playing == NowPlayingRowState.playing,
              )
            : number == null
                ? null
                : FittedBox(
                    // A four-digit number shrinks rather than spilling into
                    // the title.
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '$number',
                      maxLines: 1,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color:
                            theme.colorScheme.onSurface.withValues(alpha: 0.6),
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ),
      ),
    );
  }
}
