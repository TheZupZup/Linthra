import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/features/library/widgets/artist_tile.dart';
import 'package:linthra/features/player/widgets/album_artwork.dart';
import 'package:linthra/shared/widgets/artwork_image.dart';

/// Artwork decode bounds at HiDPI and fractional scales (#457).
///
/// A cover arrives at whatever size its source felt like: a server's original
/// scan, or the 1024 px bound Linthra's own local cache applies. Drawn into a
/// 48 px avatar with no decode bound, that costs the same memory and CPU as
/// showing it full-screen, once per visible row, and every point of scale
/// factor makes it worse rather than better.
///
/// So the decode target has to follow the *device* pixels the cover will
/// actually occupy. These tests are about that number, and about the fact that
/// the surfaces which draw covers really pass one.
final Uri _cover = Uri.parse('file:///cache/linthra_local_artwork/cover.img');

/// The `cacheWidth` a rendered [Image] actually asked for, or null when it
/// asked for the whole thing.
int? _decodeWidthOf(WidgetTester tester, Finder image) {
  final ImageProvider provider = tester.widget<Image>(image).image;
  return provider is ResizeImage ? provider.width : null;
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required double devicePixelRatio,
}) async {
  tester.view.devicePixelRatio = devicePixelRatio;
  tester.view.physicalSize = const Size(1920, 1080);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MediaQuery(
        data: MediaQueryData(devicePixelRatio: devicePixelRatio),
        child: MaterialApp(
          home: Scaffold(body: Center(child: child)),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('artworkDecodeExtentFor', () {
    test('follows the device pixels the cover will occupy', () {
      // The same 48 px avatar on three desktops.
      expect(artworkDecodeExtentFor(48, 1.0), 48);
      expect(artworkDecodeExtentFor(48, 1.25), 60);
      expect(artworkDecodeExtentFor(48, 1.75), 84);
      expect(artworkDecodeExtentFor(48, 2.0), 96);
    });

    test('rounds up, so a fractional scale never decodes soft', () {
      // 48 * 1.3 is 62.4: decoding 62 device pixels into a 62.4 pixel box
      // would be a visibly resampled avatar on exactly the displays this is
      // for.
      expect(artworkDecodeExtentFor(48, 1.3), 63);
    });

    test('caps at the largest surface Linthra draws a cover on', () {
      // A 4K full-screen cover at 200% would ask for 2160.
      expect(artworkDecodeExtentFor(1080, 2.0), maxArtworkDecodeExtent);
      expect(artworkDecodeExtentFor(4000, 3.0), maxArtworkDecodeExtent);
    });

    test('never asks for a cover too small to be worth decoding', () {
      expect(artworkDecodeExtentFor(4, 1.0), minArtworkDecodeExtent);
      expect(artworkDecodeExtentFor(0.5, 2.0), minArtworkDecodeExtent);
    });

    // An unbounded constraint means the box has not been measured. Guessing
    // small there renders a blurry cover, which is worse than a slow one.
    test('falls back to full size for an unmeasured box', () {
      expect(
          artworkDecodeExtentFor(double.infinity, 2.0), maxArtworkDecodeExtent);
      expect(artworkDecodeExtentFor(double.nan, 2.0), maxArtworkDecodeExtent);
      expect(artworkDecodeExtentFor(0, 2.0), maxArtworkDecodeExtent);
      expect(artworkDecodeExtentFor(-10, 2.0), maxArtworkDecodeExtent);
    });

    test('survives a nonsense device pixel ratio', () {
      expect(artworkDecodeExtentFor(48, 0), maxArtworkDecodeExtent);
      expect(
          artworkDecodeExtentFor(48, double.infinity), maxArtworkDecodeExtent);
    });
  });

  group('artworkImageProvider', () {
    // The resolver tests call it without a bound and assert on the concrete
    // provider type; that has to keep working.
    test('decodes at full size when no bound is given', () {
      expect(artworkImageProvider(_cover), isA<FileImage>());
    });

    test('wraps the resolved provider rather than replacing it', () {
      final ImageProvider provider =
          artworkImageProvider(_cover, decodeExtent: 96);
      expect(provider, isA<ResizeImage>());
      final ResizeImage resized = provider as ResizeImage;
      expect(resized.width, 96);
      expect(resized.height, isNull, reason: 'covers keep their aspect ratio');
      expect(resized.imageProvider, isA<FileImage>());
    });

    // ResizeImage upscaling would blow a small cover up in memory to look
    // exactly as soft as letting the GPU scale it.
    test('never upscales a cover smaller than its box', () {
      final ResizeImage resized =
          artworkImageProvider(_cover, decodeExtent: 1024) as ResizeImage;
      expect(resized.allowUpscaling, isFalse);
    });
  });

  group('the surfaces that draw covers pass a bound', () {
    for (final double ratio in <double>[1.0, 1.25, 1.5, 1.75, 2.0]) {
      testWidgets('AlbumArtwork bounds its decode to its box at ${ratio}x',
          (WidgetTester tester) async {
        await _pump(
          tester,
          const SizedBox.square(
            dimension: 64,
            child: AlbumArtwork(artworkUri: null),
          ),
          devicePixelRatio: ratio,
        );

        // Rebuild with a cover now that the box is known.
        await _pump(
          tester,
          SizedBox.square(
            dimension: 64,
            child: AlbumArtwork(artworkUri: _cover),
          ),
          devicePixelRatio: ratio,
        );

        expect(
          _decodeWidthOf(tester, find.byType(Image)),
          (64 * ratio).ceil(),
          reason: 'a 64 px cover at ${ratio}x should decode at '
              '${(64 * ratio).ceil()} device pixels',
        );
      });
    }

    testWidgets('a full-screen cover still stops at the cap',
        (WidgetTester tester) async {
      await _pump(
        tester,
        SizedBox.square(
            dimension: 900, child: AlbumArtwork(artworkUri: _cover)),
        devicePixelRatio: 2.0,
      );

      expect(
        _decodeWidthOf(tester, find.byType(Image)),
        maxArtworkDecodeExtent,
      );
    });

    testWidgets('an artist row avatar decodes at avatar size, not cover size',
        (WidgetTester tester) async {
      await _pump(
        tester,
        SizedBox(
          width: 400,
          child: ArtistTile(
            artist: Artist(
              id: '1',
              name: 'An Artist',
              albumCount: 2,
              trackCount: 9,
              artworkUri: _cover,
            ),
          ),
        ),
        devicePixelRatio: 2.0,
      );

      expect(_decodeWidthOf(tester, find.byType(Image)), 96);
    });
  });
}
