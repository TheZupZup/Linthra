import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/services/cache_eviction_policy.dart';

/// Replays the shared cases in `test/fixtures/cache_eviction_cases.json`.
///
/// The same file is meant to drive any other implementation of the policy, so
/// the format stays flat: tracks are listed in input order, times are epoch
/// milliseconds (or null), keys are `{source, id}` pairs, and the expected
/// eviction is a list of indices into `cached`, in eviction order.
const String _casesPath = 'test/fixtures/cache_eviction_cases.json';

CachedTrack _track(Map<String, dynamic> json, int index) {
  final String? source = json['source'] as String?;
  return CachedTrack(
    trackId: json['id'] as String,
    sourceType: source,
    fileName: json['managed'] as bool ? 'case_$index.mp3' : null,
    sizeBytes: json['size'] as int,
    lastAccessedAt: _time(json['accessed']),
    cachedAt: _time(json['cachedAt']),
    pinned: json['pinned'] as bool,
    preloaded: json['preloaded'] as bool,
  );
}

DateTime? _time(Object? millis) {
  if (millis == null) return null;
  return DateTime.fromMillisecondsSinceEpoch(millis as int, isUtc: true);
}

String? _key(Object? json) {
  if (json == null) return null;
  final Map<String, dynamic> key = json as Map<String, dynamic>;
  final String? source = key['source'] as String?;
  return CachedTrack.cacheKeyFor(source, key['id'] as String);
}

/// Index of [track] in [cached] by identity, so two equal records still map
/// back to the slot they came from.
int _indexOf(List<CachedTrack> cached, CachedTrack track) {
  for (int i = 0; i < cached.length; i++) {
    if (identical(cached[i], track)) return i;
  }
  return -1;
}

void main() {
  final Map<String, dynamic> doc =
      jsonDecode(File(_casesPath).readAsStringSync()) as Map<String, dynamic>;
  final List<Map<String, dynamic>> cases =
      (doc['cases'] as List<dynamic>).cast<Map<String, dynamic>>();

  test('file is version 1 with unique case names', () {
    expect(doc['version'], 1);
    final List<String> names = <String>[
      for (final Map<String, dynamic> c in cases) c['name'] as String,
    ];
    expect(names, isNotEmpty);
    expect(names.toSet().length, names.length);
  });

  _replay('cache eviction cases', cases, const CacheEvictionPolicy());
}

void _replay(
  String name,
  List<Map<String, dynamic>> cases,
  CacheEvictionPolicy policy,
) {
  group(name, () {
    for (final Map<String, dynamic> c in cases) {
      test(c['name'] as String, () {
        final List<dynamic> rawTracks = c['cached'] as List<dynamic>;
        final List<CachedTrack> cached = <CachedTrack>[
          for (int i = 0; i < rawTracks.length; i++)
            _track(rawTracks[i] as Map<String, dynamic>, i),
        ];
        final Map<String, dynamic> expected =
            c['expect'] as Map<String, dynamic>;
        final List<dynamic> rawProtected = c['protectKeys'] as List<dynamic>;

        final EvictionPlan plan = policy.plan(
          cached: cached,
          incomingBytes: c['incomingBytes'] as int,
          maxBytes: c['maxBytes'] as int,
          protectKey: _key(c['protectKey']),
          protectKeys: <String>{for (final dynamic k in rawProtected) _key(k)!},
          onlyPreloaded: c['onlyPreloaded'] as bool,
          incomingKey: _key(c['incomingKey']),
        );

        expect(plan.fits, expected['fits'] as bool);
        expect(
          plan.evict.map((CachedTrack t) => _indexOf(cached, t)).toList(),
          (expected['evict'] as List<dynamic>).cast<int>(),
        );
      });
    }
  });
}
