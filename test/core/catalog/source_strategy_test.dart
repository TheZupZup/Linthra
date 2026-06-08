import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/source_capability.dart';
import 'package:linthra/core/catalog/source_strategy.dart';

/// A tagged candidate so tests can assert the resulting *order* by tag while the
/// strategy reads the capability via [profileOf].
typedef _Cand = ({String tag, PlaybackSourceCapability cap});

SourceProviderType _pt(String provider) {
  switch (provider) {
    case 'local':
      return SourceProviderType.local;
    case 'subsonic':
      return SourceProviderType.subsonic;
    default:
      return SourceProviderType.jellyfin;
  }
}

_Cand _cand(
  String tag,
  SourceDelivery delivery, {
  String provider = 'jellyfin',
  int? bitrate,
}) =>
    (
      tag: tag,
      cap: PlaybackSourceCapability(
        sourceId: provider,
        providerType: _pt(provider),
        delivery: delivery,
        bitrateKbps: bitrate,
      ),
    );

List<String> _order(List<_Cand> candidates, PlaybackSourceStrategy strategy) =>
    orderBySourceStrategy(candidates, strategy, (_Cand c) => c.cap)
        .map((_Cand c) => c.tag)
        .toList();

void main() {
  group('preferDefault — identity (preserves PR1/PR2)', () {
    test('order is unchanged regardless of delivery or quality', () {
      final candidates = <_Cand>[
        _cand('remote', SourceDelivery.remoteStream, bitrate: 128),
        _cand('cache', SourceDelivery.cache),
        _cand('local', SourceDelivery.localFile, provider: 'local'),
      ];
      expect(
        _order(candidates, PlaybackSourceStrategy.preferDefault),
        <String>['remote', 'cache', 'local'],
      );
    });
  });

  group('preferLocalCache', () {
    test('chooses cache, then local, then server', () {
      final candidates = <_Cand>[
        _cand('remote', SourceDelivery.remoteStream),
        _cand('cache', SourceDelivery.cache),
        _cand('local', SourceDelivery.localFile, provider: 'local'),
      ];
      expect(
        _order(candidates, PlaybackSourceStrategy.preferLocalCache),
        <String>['cache', 'local', 'remote'],
      );
    });

    test('falls back to default order when no cache/local exists', () {
      final candidates = <_Cand>[
        _cand('jelly', SourceDelivery.remoteStream),
        _cand('sub', SourceDelivery.remoteStream, provider: 'subsonic'),
      ];
      expect(
        _order(candidates, PlaybackSourceStrategy.preferLocalCache),
        <String>['jelly', 'sub'],
      );
    });

    test('default order is the tie-breaker among equal (server) candidates',
        () {
      final candidates = <_Cand>[
        _cand('first', SourceDelivery.remoteStream),
        _cand('cache', SourceDelivery.cache),
        _cand('second', SourceDelivery.remoteStream, provider: 'subsonic'),
      ];
      // cache rises; the two servers keep their relative default order.
      expect(
        _order(candidates, PlaybackSourceStrategy.preferLocalCache),
        <String>['cache', 'first', 'second'],
      );
    });
  });

  group('preferHighestQuality', () {
    test('uses known quality: higher bitrate first', () {
      final candidates = <_Cand>[
        _cand('low', SourceDelivery.remoteStream, bitrate: 128),
        _cand('high', SourceDelivery.remoteStream,
            provider: 'subsonic', bitrate: 320),
      ];
      expect(
        _order(candidates, PlaybackSourceStrategy.preferHighestQuality),
        <String>['high', 'low'],
      );
    });

    test('falls back to default order when quality is unknown', () {
      final candidates = <_Cand>[
        _cand('a', SourceDelivery.remoteStream),
        _cand('b', SourceDelivery.remoteStream, provider: 'subsonic'),
      ];
      expect(
        _order(candidates, PlaybackSourceStrategy.preferHighestQuality),
        <String>['a', 'b'],
      );
    });

    test('an unknown-quality candidate keeps its default slot (no downgrade)',
        () {
      // Only the known candidate(s) reorder among their own slots; the unknown
      // one never moves, so a known-lower is never promoted past an unknown.
      final candidates = <_Cand>[
        _cand('unknown', SourceDelivery.remoteStream),
        _cand('k320', SourceDelivery.remoteStream,
            provider: 'subsonic', bitrate: 320),
      ];
      expect(
        _order(candidates, PlaybackSourceStrategy.preferHighestQuality),
        <String>['unknown', 'k320'],
      );
    });
  });

  group('preferLowerData', () {
    test('prefers cache/local first', () {
      final candidates = <_Cand>[
        _cand('remote', SourceDelivery.remoteStream, bitrate: 64),
        _cand('cache', SourceDelivery.cache),
        _cand('local', SourceDelivery.localFile, provider: 'local'),
      ];
      final ordered =
          _order(candidates, PlaybackSourceStrategy.preferLowerData);
      expect(ordered.first, anyOf('cache', 'local'));
      expect(ordered.last, 'remote');
      expect(ordered.sublist(0, 2), containsAll(<String>['cache', 'local']));
    });

    test('uses known lower-data (bitrate) among server copies', () {
      final candidates = <_Cand>[
        _cand('hi', SourceDelivery.remoteStream, bitrate: 320),
        _cand('lo', SourceDelivery.remoteStream,
            provider: 'subsonic', bitrate: 96),
      ];
      expect(
        _order(candidates, PlaybackSourceStrategy.preferLowerData),
        <String>['lo', 'hi'],
      );
    });

    test('falls back to default order when bitrate is unknown', () {
      final candidates = <_Cand>[
        _cand('a', SourceDelivery.remoteStream),
        _cand('b', SourceDelivery.remoteStream, provider: 'subsonic'),
      ];
      expect(
        _order(candidates, PlaybackSourceStrategy.preferLowerData),
        <String>['a', 'b'],
      );
    });
  });

  group('automaticBalanced', () {
    test('prefers cache/local when available', () {
      final candidates = <_Cand>[
        _cand('remote', SourceDelivery.remoteStream),
        _cand('cache', SourceDelivery.cache),
      ];
      expect(
        _order(candidates, PlaybackSourceStrategy.automaticBalanced),
        <String>['cache', 'remote'],
      );
    });

    test('falls back to default order when metadata is unknown', () {
      final candidates = <_Cand>[
        _cand('jelly', SourceDelivery.remoteStream, bitrate: 999),
        _cand('sub', SourceDelivery.remoteStream, provider: 'subsonic'),
      ];
      // No cache/local, and balanced never reorders servers on quality guesses.
      expect(
        _order(candidates, PlaybackSourceStrategy.automaticBalanced),
        <String>['jelly', 'sub'],
      );
    });
  });

  group('determinism & safety', () {
    test('a single candidate is returned unchanged for every strategy', () {
      for (final s in PlaybackSourceStrategy.values) {
        expect(_order(<_Cand>[_cand('only', SourceDelivery.remoteStream)], s),
            <String>['only']);
      }
    });

    test('the same input always yields the same order', () {
      final candidates = <_Cand>[
        _cand('remote', SourceDelivery.remoteStream, bitrate: 200),
        _cand('cache', SourceDelivery.cache),
        _cand('local', SourceDelivery.localFile, provider: 'local'),
      ];
      final a = _order(candidates, PlaybackSourceStrategy.automaticBalanced);
      final b = _order(candidates, PlaybackSourceStrategy.automaticBalanced);
      expect(a, b);
    });

    test('strategy labels/descriptions expose no URLs, hosts, or paths', () {
      for (final s in PlaybackSourceStrategy.values) {
        for (final String text in <String>[s.label, s.description]) {
          expect(text, isNot(contains('://')));
          expect(text.toLowerCase(), isNot(contains('http')));
          expect(text, isNot(contains(r'\')));
          expect(text, isNot(contains('@')));
        }
      }
    });

    test('fromStorage falls back to the default for unknown/absent values', () {
      expect(PlaybackSourceStrategy.fromStorage(null),
          PlaybackSourceStrategy.preferDefault);
      expect(PlaybackSourceStrategy.fromStorage('nonsense'),
          PlaybackSourceStrategy.preferDefault);
      expect(PlaybackSourceStrategy.fromStorage('preferLocalCache'),
          PlaybackSourceStrategy.preferLocalCache);
    });
  });
}
