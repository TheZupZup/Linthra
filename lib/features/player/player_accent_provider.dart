import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/widgets/artwork_image.dart';
import 'player_theme.dart';

/// The "live" accent for the player/lyrics surfaces, derived from the current
/// track's album art so the screen feels like it belongs to the song. Used for
/// highlights only — the seek fill, the active lyric line, the play button.
///
/// Keyed by the track's artwork [Uri] (autoDispose, so each track's work is
/// dropped when nothing watches it). It always resolves to a tasteful colour:
/// the derived album accent when one can be read, otherwise Linthra's brand
/// accent ([PlayerPalette.fallbackAccent]). It only ever *reads* an image —
/// playback never depends on it, and a missing/undecodable cover simply yields
/// the fallback. With no artwork (the common case in tests) it returns the
/// fallback synchronously without touching the network.
final playerAccentProvider =
    FutureProvider.autoDispose.family<Color, Uri?>((ref, uri) async {
  if (uri == null) return PlayerPalette.fallbackAccent;
  try {
    final Color? derived = await _accentFromArtwork(uri);
    return derived ?? PlayerPalette.fallbackAccent;
  } catch (_) {
    // The accent is decorative; any decode/transport failure falls back.
    return PlayerPalette.fallbackAccent;
  }
});

/// Decodes the cover at a small fixed size and picks a representative accent.
Future<Color?> _accentFromArtwork(Uri uri) async {
  // A 48x48 decode bounds the work and memory regardless of cover size.
  final ImageProvider provider = ResizeImage(
    artworkImageProvider(uri),
    width: 48,
    height: 48,
  );
  final ui.Image image = await _resolveImage(provider);
  final ByteData? data =
      await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  if (data == null) return null;
  return _dominantAccent(data.buffer.asUint8List());
}

/// Resolves an [ImageProvider] to a single decoded [ui.Image].
Future<ui.Image> _resolveImage(ImageProvider provider) {
  final Completer<ui.Image> completer = Completer<ui.Image>();
  final ImageStream stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (ImageInfo info, bool _) {
      if (!completer.isCompleted) completer.complete(info.image);
      stream.removeListener(listener);
    },
    onError: (Object error, StackTrace? stackTrace) {
      if (!completer.isCompleted) completer.completeError(error);
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  return completer.future;
}

/// Picks the most "colourful" hue family from the sampled pixels (weighting by
/// saturation × value, skipping greys and near-black/near-white), then tunes it
/// for use as a highlight on the cream surfaces. Returns null when the art is
/// effectively monochrome, so the caller can fall back to the brand accent.
Color? _dominantAccent(Uint8List rgba) {
  const int buckets = 12;
  final List<double> weight = List<double>.filled(buckets, 0);
  final List<double> sumR = List<double>.filled(buckets, 0);
  final List<double> sumG = List<double>.filled(buckets, 0);
  final List<double> sumB = List<double>.filled(buckets, 0);

  for (int i = 0; i + 3 < rgba.length; i += 4) {
    if (rgba[i + 3] < 128) continue; // skip transparent pixels
    final int r = rgba[i];
    final int g = rgba[i + 1];
    final int b = rgba[i + 2];
    final HSVColor hsv = HSVColor.fromColor(Color.fromARGB(255, r, g, b));
    if (hsv.saturation < 0.22 || hsv.value < 0.18 || hsv.value > 0.96) {
      continue; // skip greys, near-black, near-white
    }
    final double w = hsv.saturation * hsv.value;
    final int bucket = ((hsv.hue / 360.0) * buckets).floor() % buckets;
    weight[bucket] += w;
    sumR[bucket] += r * w;
    sumG[bucket] += g * w;
    sumB[bucket] += b * w;
  }

  int best = -1;
  double bestWeight = 0;
  for (int i = 0; i < buckets; i++) {
    if (weight[i] > bestWeight) {
      bestWeight = weight[i];
      best = i;
    }
  }
  if (best < 0 || bestWeight <= 0) return null;

  final double w = weight[best];
  final Color average = Color.fromARGB(
    255,
    (sumR[best] / w).round().clamp(0, 255).toInt(),
    (sumG[best] / w).round().clamp(0, 255).toInt(),
    (sumB[best] / w).round().clamp(0, 255).toInt(),
  );
  return _tuneForLightSurface(average);
}

/// Clamps saturation and lightness into a band that reads as a confident,
/// legible highlight on the warm light surfaces — never washed-out or muddy.
Color _tuneForLightSurface(Color color) {
  final HSLColor hsl = HSLColor.fromColor(color);
  return hsl
      .withSaturation(hsl.saturation.clamp(0.45, 0.9).toDouble())
      .withLightness(hsl.lightness.clamp(0.40, 0.58).toDouble())
      .toColor();
}
