import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/colors.dart';
import '../../core/models/playback_state.dart';
import '../../features/player/player_providers.dart';
import '../../features/player/player_screen.dart';
import '../now_playing_preview_data.dart';
import 'preview_playback_controller.dart';

/// Dev-only host for the real [PlayerScreen], fed by fake data.
///
/// It renders the **actual** Now Playing screen (the same widgets the app ships)
/// inside a nested [ProviderScope] whose playback controller is a
/// [PreviewPlaybackController]. A thin bar at the top lets you flip between the
/// sample states in `now_playing_preview_data.dart`. Nothing here runs in the
/// shipping app — launch it with:
///
/// ```
/// flutter run -t lib/ui_linthra/preview/now_playing_preview_main.dart
/// ```
class NowPlayingPreviewScreen extends StatefulWidget {
  const NowPlayingPreviewScreen({super.key});

  @override
  State<NowPlayingPreviewScreen> createState() =>
      _NowPlayingPreviewScreenState();
}

class _NowPlayingPreviewScreenState extends State<NowPlayingPreviewScreen> {
  late final PreviewPlaybackController _controller;
  int _selected = 0;

  /// A generated cover written to a temp file so the blurred-artwork hero shows
  /// up offline (the app's artwork loader reads `file:` covers from disk). Null
  /// until prepared — or if preparation fails — in which case the preview simply
  /// shows the no-artwork look.
  Uri? _artwork;

  NowPlayingPreviewSample get _current => nowPlayingPreviewSamples[_selected];

  @override
  void initState() {
    super.initState();
    _controller = PreviewPlaybackController(_resolved(_current));
    _prepareArtwork();
  }

  /// Applies the prepared cover to a sample's state (for samples that want it),
  /// so the real artwork/background widgets have something to render offline.
  PlaybackState _resolved(NowPlayingPreviewSample sample) {
    final Uri? art = _artwork;
    final track = sample.state.currentTrack;
    if (!sample.showArtwork || art == null || track == null) {
      return sample.state;
    }
    return sample.state.copyWith(
      currentTrack: track.copyWith(artworkUri: art),
    );
  }

  /// Paints a calm brand-gradient square and writes it to a temp PNG, so the
  /// preview can show a real cover and blurred backdrop without bundling any
  /// asset or hitting the network.
  Future<void> _prepareArtwork() async {
    try {
      final ui.Image image = await _paintPreviewCover();
      final ByteData? png =
          await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (png == null) return;
      final Directory dir =
          await Directory.systemTemp.createTemp('linthra_np_preview');
      final File file = File('${dir.path}/cover.png');
      await file.writeAsBytes(
        png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
      if (!mounted) return;
      setState(() => _artwork = file.uri);
      _controller.load(_resolved(_current));
    } catch (_) {
      // Best-effort: the preview still works without a cover image.
    }
  }

  Future<ui.Image> _paintPreviewCover() async {
    const double size = 512;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, size, size),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          const Offset(size, size),
          const <Color>[
            AppColors.brandBright,
            AppColors.brandDeep,
            AppColors.accentDeep,
          ],
          const <double>[0.0, 0.55, 1.0],
        ),
    );
    // A soft glow so the heavily-blurred backdrop has some structure to it.
    canvas.drawCircle(
      const Offset(size * 0.66, size * 0.34),
      size * 0.24,
      Paint()..color = AppColors.accentBright.withValues(alpha: 0.35),
    );
    return recorder.endRecording().toImage(size.toInt(), size.toInt());
  }

  void _select(int index) {
    setState(() => _selected = index);
    _controller.load(_resolved(_current));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: _PreviewBar(
              samples: nowPlayingPreviewSamples,
              selected: _selected,
              onSelected: _select,
            ),
          ),
          Expanded(
            // The real Now Playing screen, with only its playback controller
            // swapped for the fake one. Everything else (cast, favorites, sleep
            // timer, lyrics) uses its normal in-memory default, so no provider
            // needs a server.
            child: ProviderScope(
              overrides: [
                playbackControllerProvider.overrideWithValue(_controller),
              ],
              child: const PlayerScreen(),
            ),
          ),
        ],
      ),
    );
  }
}

/// The thin dev toolbar above the previewed screen: a clear "fake data" note and
/// a dropdown to pick which sample state to render. Intentionally plain — it is
/// not part of the design under review.
class _PreviewBar extends StatelessWidget {
  const _PreviewBar({
    required this.samples,
    required this.selected,
    required this.onSelected,
  });

  final List<NowPlayingPreviewSample> samples;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(
              Icons.science_outlined,
              size: 18,
              color: theme.colorScheme.secondary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Now Playing — UI preview (fake data)',
                style: theme.textTheme.labelMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            DropdownButton<int>(
              value: selected,
              underline: const SizedBox.shrink(),
              borderRadius: BorderRadius.circular(12),
              items: [
                for (int i = 0; i < samples.length; i++)
                  DropdownMenuItem<int>(
                    value: i,
                    child: Text(samples[i].name),
                  ),
              ],
              onChanged: (i) {
                if (i != null) onSelected(i);
              },
            ),
          ],
        ),
      ),
    );
  }
}
