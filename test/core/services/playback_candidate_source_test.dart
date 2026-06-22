import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playback_candidate_source.dart';

Track _t(String id, String uri) => Track(id: id, title: 'Hello', uri: uri);

void main() {
  group('NoFallbackCandidateSource', () {
    test('every track is its own only candidate', () {
      const source = NoFallbackCandidateSource();
      final Track t = _t('j', 'jellyfin:j');
      expect(source.candidatesFor(t), <Track>[t]);
    });
  });

  group('MapPlaybackCandidateSource', () {
    final Track jelly = _t('j', 'jellyfin:j');
    final Track sub = _t('s', 'subsonic:s');

    test('returns the mapped, ordered candidates for a known track', () {
      final source = MapPlaybackCandidateSource(() => <String, List<Track>>{
            'jellyfin:j': <Track>[jelly, sub],
          });
      expect(source.candidatesFor(jelly), <Track>[jelly, sub]);
    });

    test('an unknown (single-source) track yields just itself', () {
      final source = MapPlaybackCandidateSource(() => <String, List<Track>>{
            'jellyfin:j': <Track>[jelly, sub],
          });
      final Track lonely = _t('x', 'jellyfin:x');
      expect(source.candidatesFor(lonely), <Track>[lonely]);
    });

    test('an empty mapped list falls back to the track itself', () {
      final source = MapPlaybackCandidateSource(() => <String, List<Track>>{
            'jellyfin:j': <Track>[],
          });
      expect(source.candidatesFor(jelly), <Track>[jelly]);
    });

    test('keys on the uri, so a shared bare id resolves to the right song', () {
      // Two unrelated songs that share the bare id "101" across providers.
      final Track jelly101 = _t('101', 'jellyfin:101');
      final Track sub101 = _t('101', 'subsonic:101');
      final source = MapPlaybackCandidateSource(() => <String, List<Track>>{
            'jellyfin:101': <Track>[jelly101],
            'subsonic:101': <Track>[sub101],
          });
      // Each resolves to its own entry — not the other provider's same-id song.
      expect(source.candidatesFor(jelly101), <Track>[jelly101]);
      expect(source.candidatesFor(sub101), <Track>[sub101]);
    });

    test('the map is read lazily on every call (live library)', () {
      Map<String, List<Track>> map = <String, List<Track>>{};
      final source = MapPlaybackCandidateSource(() => map);

      // Before the library knows about this song: no fallback.
      expect(source.candidatesFor(jelly), <Track>[jelly]);

      // The library updates; the same source now sees the new candidates.
      map = <String, List<Track>>{
        'jellyfin:j': <Track>[jelly, sub],
      };
      expect(source.candidatesFor(jelly), <Track>[jelly, sub]);
    });
  });
}
