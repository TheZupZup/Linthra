import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/audio_stream_quality.dart';
import '../../../shared/format/audio_quality_label.dart';
import '../audio_quality_providers.dart';

/// The quiet "FLAC · Lossless · 44.1 kHz" line under the playback source, when
/// "Show audio quality" is on.
///
/// With the setting on it always takes the same height, known or not, so a
/// track change (which clears the report until the new one is read) never
/// moves the progress bar and the transport below it. With the setting off it
/// takes nothing and Now Playing is exactly what it was before.
class AudioQualityLine extends ConsumerWidget {
  const AudioQualityLine({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(audioQualityLineEnabledProvider)) {
      return const SizedBox.shrink();
    }
    final AudioStreamQuality? quality =
        ref.watch(nowPlayingAudioQualityProvider);
    final ThemeData theme = Theme.of(context);
    final TextStyle? style = theme.textTheme.labelMedium?.copyWith(
      letterSpacing: 0.2,
      color: theme.colorScheme.onSurfaceVariant,
    );
    final String? text =
        quality == null ? null : AudioQualityLabel.text(quality);

    final double fontSize = style?.fontSize ?? 12.0;
    final double lineHeight = style?.height ?? 1.2;
    final double textHeight =
        MediaQuery.textScalerOf(context).scale(fontSize) * lineHeight;
    final double slotHeight = textHeight + AppSpacing.xs;

    return SizedBox(
      key: const ValueKey<String>('audio-quality-line'),
      height: slotHeight < 20 ? 20 : slotHeight,
      child: text == null
          ? null
          : Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(Icons.graphic_eq, size: 15, color: style?.color),
                  const SizedBox(width: AppSpacing.xs + 2),
                  Flexible(
                    child: Text(
                      text,
                      semanticsLabel: AudioQualityLabel.semantics(quality!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
