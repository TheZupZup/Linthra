import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
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
  return provider is CoverResizeImage ? provider.extent : null;
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

/// 700 distinct widths must not become 700 distinct decodes.
const int travelBudget = 24;

/// A provider that loads nothing; only its cache key matters here.
@immutable
class _StubImageProvider extends ImageProvider<String> {
  const _StubImageProvider(this.id);

  final String id;

  @override
  Future<String> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<String>(id);

  @override
  ImageStreamCompleter loadImage(String key, ImageDecoderCallback decode) {
    throw UnimplementedError('these tests never decode');
  }
}

void main() {
  group('artworkDecodeExtentFor', () {
    test('follows the device pixels the cover will occupy', () {
      // The same 48 px avatar on three desktops.
      expect(artworkDecodeExtentFor(48, 1.0), 64);
      expect(artworkDecodeExtentFor(48, 1.25), 64);
      expect(artworkDecodeExtentFor(48, 1.75), 96);
      expect(artworkDecodeExtentFor(48, 2.0), 96);
    });

    test('rounds up, so a fractional scale never decodes soft', () {
      // 48 * 1.3 is 62.4. Rounding down anywhere in this path would resample a
      // 62.4 pixel box from 62 device pixels, on exactly the displays this is
      // for. Both the pixel conversion and the bucketing round up.
      expect(artworkDecodeExtentFor(48, 1.3), 64);
      for (double ratio = 1.0; ratio <= 3.0; ratio += 0.05) {
        expect(
          artworkDecodeExtentFor(48, ratio),
          greaterThanOrEqualTo((48 * ratio).ceil()),
          reason: 'a bucket must never be smaller than the exact extent, but '
              'it is at ${ratio}x',
        );
      }
    });

    // The requested extent is part of the image cache key, so an exact
    // extent would mint a fresh decode for every width a window is dragged
    // through. That is the churn this whole bound exists to remove, so it has
    // to be bounded rather than assumed.
    test('a window resize sweep collapses to few decodes', () {
      final Set<int> buckets = <int>{};
      for (int logical = 200; logical <= 900; logical++) {
        buckets.add(artworkDecodeExtentFor(logical.toDouble(), 1.0));
      }
      expect(
        buckets.length,
        lessThanOrEqualTo(travelBudget),
        reason: '700 widths produced ${buckets.length} distinct decodes',
      );
    });

    test('every result is a usable bucket', () {
      for (final double logical in <double>[33, 47, 48, 100, 257, 999]) {
        final int extent = artworkDecodeExtentFor(logical, 1.0);
        expect(extent % artworkDecodeQuantum, 0,
            reason: '$extent is not a multiple of the quantum');
        expect(extent, greaterThanOrEqualTo(minArtworkDecodeExtent));
        expect(extent, lessThanOrEqualTo(maxArtworkDecodeExtent));
      }
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
      expect(provider, isA<CoverResizeImage>());
      final CoverResizeImage resized = provider as CoverResizeImage;
      expect(resized.extent, 96);
      expect(resized.imageProvider, isA<FileImage>());
    });

    // Upscaling would blow a small cover up in memory to look exactly as soft
    // as letting the GPU scale it.
    test('never upscales a cover smaller than its box', () {
      final CoverResizeImage resized =
          artworkImageProvider(_cover, decodeExtent: 1024) as CoverResizeImage;
      // A 512x512 source asked to cover 1024 is left at its own size.
      expect(resized.targetSizeFor(512, 512).width, isNull);
      expect(resized.targetSizeFor(512, 512).height, isNull);
    });

    test('an unbounded caller still gets the raw provider', () {
      expect(artworkImageProvider(_cover), isA<FileImage>());
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

        // The widget must ask for the bucket its own box maps to, which is
        // what artworkDecodeExtentFor already pins in the unit tests above.
        // Asserting the raw device pixels here would re-pin the bucketing in a
        // second place and break on every quantum change.
        expect(
          _decodeWidthOf(tester, find.byType(Image)),
          artworkDecodeExtentFor(64, ratio),
          reason: 'a 64 px cover at ${ratio}x should decode at '
              '${artworkDecodeExtentFor(64, ratio)} device pixels',
        );
        expect(
          _decodeWidthOf(tester, find.byType(Image))!,
          greaterThanOrEqualTo((64 * ratio).ceil()),
          reason: 'never below the exact extent the box needs',
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

  // #626: every artwork surface draws with BoxFit.cover, and cover is
  // satisfied by the *shorter* side. Constraining one axis leaves the other
  // short for a non-square source, which is then scaled back up: a soft cover.
  group('CoverResizeImage decodes for cover, not for one axis', () {
    const CoverResizeImage provider =
        CoverResizeImage(_StubImageProvider('a'), extent: 48);

    ui.TargetImageSize sizeFor(int w, int h) => provider.targetSizeFor(w, h);

    test('a landscape source meets the target on its shorter side', () {
      // 2:1. The regression decoded this 48x24 and let cover enlarge it 2x.
      final ui.TargetImageSize size = sizeFor(1000, 500);
      expect(size.height, 48,
          reason: 'the covering axis must reach the target');
      expect(size.width, 96, reason: 'the aspect ratio must be preserved');
    });

    test('a portrait source meets the target on its shorter side', () {
      final ui.TargetImageSize size = sizeFor(500, 1000);
      expect(size.width, 48);
      expect(size.height, 96);
    });

    test('a square source is unchanged from the single-axis behaviour', () {
      // The common case must not cost more memory than it did before #626.
      final ui.TargetImageSize size = sizeFor(1000, 1000);
      expect(size.width, 48);
      expect(size.height, 48);
    });

    test('the shorter side always reaches the target, at any aspect ratio', () {
      for (final List<int> source in <List<int>>[
        <int>[1000, 500],
        <int>[500, 1000],
        <int>[1000, 1000],
        <int>[3000, 400],
        <int>[400, 3000],
        <int>[1920, 1080],
        <int>[101, 97],
      ]) {
        final ui.TargetImageSize size = sizeFor(source[0], source[1]);
        final int shorter = math.min(size.width!, size.height!);
        expect(
          shorter,
          greaterThanOrEqualTo(48),
          reason: '${source[0]}x${source[1]} decoded with a shorter side of '
              '$shorter, below the 48 the cover needs',
        );
      }
    });

    test('never upscales a source already smaller than the target', () {
      // Decoding a 20 px cover up to 48 would inflate the image cache for a
      // picture that has no more detail to give.
      final ui.TargetImageSize size = sizeFor(20, 20);
      expect(size.width, isNull);
      expect(size.height, isNull);
    });

    test('a degenerate source is left alone rather than dividing by zero', () {
      expect(sizeFor(0, 100).width, isNull);
      expect(sizeFor(100, 0).width, isNull);
      expect(sizeFor(-1, -1).width, isNull);
    });

    test('an extreme aspect ratio never rounds a side to zero', () {
      // 10000x96 covering 48: the long side scales to 5000, and the point is
      // that neither side collapses to 0 on the way.
      final ui.TargetImageSize size = sizeFor(10000, 96);
      expect(size.height, 48);
      expect(size.width, 5000);
    });
  });

  // Cache identity does not fail loudly when it is wrong; it just silently
  // stops the image cache working, or worse, serves one cover for another.
  group('CoverResizeImage cache identity', () {
    test('the same cover at the same extent is one cache entry', () async {
      final Object a = await const CoverResizeImage(
        _StubImageProvider('cover'),
        extent: 64,
      ).obtainKey(ImageConfiguration.empty);
      final Object b = await const CoverResizeImage(
        _StubImageProvider('cover'),
        extent: 64,
      ).obtainKey(ImageConfiguration.empty);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('the same cover at two extents is two cache entries', () async {
      final Object small = await const CoverResizeImage(
        _StubImageProvider('cover'),
        extent: 64,
      ).obtainKey(ImageConfiguration.empty);
      final Object large = await const CoverResizeImage(
        _StubImageProvider('cover'),
        extent: 256,
      ).obtainKey(ImageConfiguration.empty);
      expect(small, isNot(large));
    });

    test('two different covers at one extent never collide', () async {
      final Object one = await const CoverResizeImage(
        _StubImageProvider('one'),
        extent: 64,
      ).obtainKey(ImageConfiguration.empty);
      final Object two = await const CoverResizeImage(
        _StubImageProvider('two'),
        extent: 64,
      ).obtainKey(ImageConfiguration.empty);
      expect(one, isNot(two));
    });
  });
}
