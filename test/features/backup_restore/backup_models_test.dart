import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cache_size.dart';
import 'package:linthra/core/repositories/download_preferences.dart';
import 'package:linthra/features/backup_restore/backup_models.dart';
import 'package:linthra/features/backup_restore/backup_validation.dart';

/// A fully-populated backup mirroring the spec's worked example, used as the
/// fixture for round-trip and framing tests.
LinthraBackup _exampleBackup() => const LinthraBackup(
      generatedBy: BackupGeneratedBy(
        app: 'Linthra Android',
        appVersion: '0.1.7',
      ),
      createdAt: '2026-06-24T12:00:00Z',
      servers: <BackupServer>[
        JellyfinBackupServer(
          displayName: 'Home Jellyfin',
          baseUrl: 'https://music.example.com',
          username: 'alice',
        ),
        SubsonicBackupServer(
          displayName: 'Navidrome',
          baseUrl: 'https://nd.example.com',
          username: 'alice',
          serverType: 'navidrome',
        ),
        PlexBackupServer(
          displayName: 'Living-room Plex',
          baseUrl: 'https://plex.example.com:32400',
          selectedSectionKeys: <String>['3', '7'],
        ),
        LocalBackupServer(
          displayName: 'Phone music folder',
          folderHint:
              'content://com.android.externalstorage.documents/tree/primary%3AMusic',
        ),
      ],
      preferences: BackupPreferences(
        defaultProvider: 'jellyfin',
        preferredSourceOrder: <String>['local', 'jellyfin', 'subsonic'],
        playbackSourceStrategy: 'preferLocalCache',
        cache: BackupCachePreferences(
          maxBytes: 5368709120,
          allowMobileData: false,
          smartPrecacheEnabled: true,
          precacheCount: 3,
        ),
        playback: BackupPlaybackPreferences(normalizeVolume: false),
        appearance: BackupAppearancePreferences(appIconVariant: 'classic'),
      ),
    );

void main() {
  group('envelope & framing', () {
    test('encodeBackup wraps the document under the linthraBackup marker', () {
      final Map<String, dynamic> doc =
          jsonDecode(encodeBackup(_exampleBackup())) as Map<String, dynamic>;

      expect(doc.keys, <String>[kBackupEnvelopeKey]);
      final Map<String, dynamic> inner =
          doc[kBackupEnvelopeKey] as Map<String, dynamic>;
      expect(inner['formatVersion'], kBackupFormatVersion);
      expect(inner['formatVersion'], 1);
      expect(inner['kind'], kBackupKindSettings);
    });

    test('servers and preferences are always present, even when empty', () {
      const LinthraBackup empty = LinthraBackup();
      final Map<String, dynamic> json = empty.toJson();

      expect(json['servers'], isEmpty);
      expect(json['preferences'], isEmpty);
      // Optional diagnostics are omitted when absent.
      expect(json.containsKey('generatedBy'), isFalse);
      expect(json.containsKey('createdAt'), isFalse);
    });

    test('empty preferences serialize to {} and omit absent sub-objects', () {
      const BackupPreferences prefs = BackupPreferences();
      expect(prefs.toJson(), isEmpty);

      const BackupPreferences partial = BackupPreferences(
        defaultProvider: 'plex',
      );
      expect(partial.toJson(), <String, dynamic>{'defaultProvider': 'plex'});
      expect(partial.toJson().containsKey('cache'), isFalse);
    });
  });

  group('round-trip fidelity', () {
    test('encode → read returns an identical document', () {
      final LinthraBackup original = _exampleBackup();

      final BackupReadResult result = readBackup(encodeBackup(original));

      expect(result, isA<BackupReadSuccess>());
      final LinthraBackup restored = (result as BackupReadSuccess).backup;
      expect(restored.toJson(), original.toJson());
    });

    test('each server type preserves its documented fields', () {
      final LinthraBackup restored =
          (readBackup(encodeBackup(_exampleBackup())) as BackupReadSuccess)
              .backup;

      final JellyfinBackupServer jellyfin =
          restored.servers[0] as JellyfinBackupServer;
      expect(jellyfin.baseUrl, 'https://music.example.com');
      expect(jellyfin.username, 'alice');

      final SubsonicBackupServer subsonic =
          restored.servers[1] as SubsonicBackupServer;
      expect(subsonic.serverType, 'navidrome');

      final PlexBackupServer plex = restored.servers[2] as PlexBackupServer;
      expect(plex.selectedSectionKeys, <String>['3', '7']);

      final LocalBackupServer local = restored.servers[3] as LocalBackupServer;
      expect(local.folderHint, contains('tree/primary'));
    });
  });

  group('forward-compatibility: unknown fields are ignored', () {
    test('unknown top-level, server, and preference keys do not break parsing',
        () {
      final Map<String, dynamic> root = <String, dynamic>{
        kBackupEnvelopeKey: <String, dynamic>{
          'formatVersion': 1,
          'kind': 'settings',
          // A field a future Linthra might add at the envelope level.
          'futureEnvelopeField': <String, dynamic>{'anything': true},
          'servers': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'jellyfin',
              'baseUrl': 'https://music.example.com',
              'username': 'alice',
              // A field a future Linthra might add to a known server type.
              'futureServerField': 'ignored',
            },
          ],
          'preferences': <String, dynamic>{
            'defaultProvider': 'jellyfin',
            // A preference key this build has never heard of.
            'futurePreference': 42,
            'cache': <String, dynamic>{
              'maxBytes': 5368709120,
              'futureCacheKnob': 'ignored',
            },
          },
        },
      };

      final BackupReadResult result = readBackupRoot(root);

      expect(result, isA<BackupReadSuccess>());
      final LinthraBackup backup = (result as BackupReadSuccess).backup;
      expect(backup.servers, hasLength(1));
      expect(backup.servers.single, isA<JellyfinBackupServer>());
      expect(backup.preferences.defaultProvider, 'jellyfin');
      expect(backup.preferences.cache?.maxBytes, 5368709120);
      // The unknown keys are gone — not re-emitted on a known type's toJson.
      expect(backup.servers.single.toJson().containsKey('futureServerField'),
          isFalse);
    });
  });

  group('forward-compatibility: unknown server types', () {
    test('an unknown type is preserved (skippable) and others still import',
        () {
      final Map<String, dynamic> root = <String, dynamic>{
        kBackupEnvelopeKey: <String, dynamic>{
          'formatVersion': 1,
          'servers': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'jellyfin',
              'baseUrl': 'https://music.example.com',
            },
            <String, dynamic>{
              // A provider this build doesn't know (a newer Android, or a
              // Desktop-only source).
              'type': 'futuresonic',
              'displayName': 'Future Server',
              'baseUrl': 'https://future.example.com',
            },
          ],
          'preferences': <String, dynamic>{},
        },
      };

      final LinthraBackup backup =
          (readBackupRoot(root) as BackupReadSuccess).backup;

      expect(backup.servers, hasLength(2));
      expect(backup.servers[0], isA<JellyfinBackupServer>());

      final BackupServer unknown = backup.servers[1];
      expect(unknown, isA<UnknownBackupServer>());
      expect(unknown.type, 'futuresonic');
      expect(unknown.displayName, 'Future Server');
      // The original entry round-trips losslessly so nothing is silently lost.
      expect(unknown.toJson()['baseUrl'], 'https://future.example.com');
    });

    test('a typeless server entry is dropped, not crashed on', () {
      final Map<String, dynamic> root = <String, dynamic>{
        kBackupEnvelopeKey: <String, dynamic>{
          'formatVersion': 1,
          'servers': <Object>[
            <String, dynamic>{'displayName': 'No type here'},
            'not even an object',
          ],
          'preferences': <String, dynamic>{},
        },
      };

      final LinthraBackup backup =
          (readBackupRoot(root) as BackupReadSuccess).backup;
      expect(backup.servers, isEmpty);
    });
  });

  group('version gating', () {
    test('a newer formatVersion is rejected with a clear message', () {
      final Map<String, dynamic> root = <String, dynamic>{
        kBackupEnvelopeKey: <String, dynamic>{
          'formatVersion': kBackupFormatVersion + 1,
          'servers': <Object>[],
          'preferences': <String, dynamic>{},
        },
      };

      final BackupReadResult result = readBackupRoot(root);

      expect(result, isA<BackupReadFailure>());
      final BackupReadFailure failure = result as BackupReadFailure;
      expect(failure.reason, BackupReadFailureReason.unsupportedVersion);
      expect(failure.message, contains('newer version'));
    });

    test('isSupportedBackupFormatVersion accepts only the supported range', () {
      expect(isSupportedBackupFormatVersion(1), isTrue);
      expect(isSupportedBackupFormatVersion(kBackupFormatVersion), isTrue);
      expect(isSupportedBackupFormatVersion(kBackupFormatVersion + 1), isFalse);
      expect(isSupportedBackupFormatVersion(0), isFalse);
      expect(isSupportedBackupFormatVersion(-1), isFalse);
    });

    test('a missing or non-integer formatVersion is malformed', () {
      final BackupReadResult missing = readBackupRoot(<String, dynamic>{
        kBackupEnvelopeKey: <String, dynamic>{
          'servers': <Object>[],
          'preferences': <String, dynamic>{},
        },
      });
      expect((missing as BackupReadFailure).reason,
          BackupReadFailureReason.malformed);

      final BackupReadResult notInt = readBackupRoot(<String, dynamic>{
        kBackupEnvelopeKey: <String, dynamic>{
          'formatVersion': 'one',
          'servers': <Object>[],
          'preferences': <String, dynamic>{},
        },
      });
      expect((notInt as BackupReadFailure).reason,
          BackupReadFailureReason.malformed);
    });

    test('a version below 1 is malformed', () {
      final BackupReadResult result = readBackupRoot(<String, dynamic>{
        kBackupEnvelopeKey: <String, dynamic>{'formatVersion': 0},
      });
      expect((result as BackupReadFailure).reason,
          BackupReadFailureReason.malformed);
    });
  });

  group('reader rejects non-backups', () {
    test('invalid JSON → notJson', () {
      final BackupReadResult result = readBackup('{not valid json');
      expect((result as BackupReadFailure).reason,
          BackupReadFailureReason.notJson);
    });

    test('valid JSON without the marker → notLinthraBackup', () {
      final BackupReadResult result = readBackup('{"somethingElse": true}');
      expect((result as BackupReadFailure).reason,
          BackupReadFailureReason.notLinthraBackup);
    });

    test('a non-object JSON value → notLinthraBackup', () {
      final BackupReadResult result = readBackup('[1, 2, 3]');
      expect((result as BackupReadFailure).reason,
          BackupReadFailureReason.notLinthraBackup);
    });
  });

  group('lenient parsing of malformed bodies', () {
    test('a known server missing its baseUrl is dropped', () {
      final LinthraBackup backup = (readBackupRoot(<String, dynamic>{
        kBackupEnvelopeKey: <String, dynamic>{
          'formatVersion': 1,
          'servers': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'jellyfin', 'username': 'alice'},
          ],
          'preferences': <String, dynamic>{},
        },
      }) as BackupReadSuccess)
          .backup;
      expect(backup.servers, isEmpty);
    });

    test('a non-list servers value parses to no servers', () {
      final LinthraBackup backup = (readBackupRoot(<String, dynamic>{
        kBackupEnvelopeKey: <String, dynamic>{
          'formatVersion': 1,
          'servers': 'not a list',
          'preferences': <String, dynamic>{},
        },
      }) as BackupReadSuccess)
          .backup;
      expect(backup.servers, isEmpty);
    });

    test('wrong-typed preference values fall back instead of throwing', () {
      final LinthraBackup backup = (readBackupRoot(<String, dynamic>{
        kBackupEnvelopeKey: <String, dynamic>{
          'formatVersion': 1,
          'servers': <Object>[],
          'preferences': <String, dynamic>{
            // Wrong types throughout — each should be ignored, none should crash.
            'defaultProvider': 123,
            'preferredSourceOrder': 'jellyfin',
            'cache': <String, dynamic>{'maxBytes': 'huge'},
            'playback': <String, dynamic>{'normalizeVolume': 'yes'},
          },
        },
      }) as BackupReadSuccess)
          .backup;

      expect(backup.preferences.defaultProvider, isNull);
      expect(backup.preferences.preferredSourceOrder, isEmpty);
      // cache had only an invalid maxBytes → it collapses to "no cache prefs".
      expect(backup.preferences.cache, isNull);
      expect(backup.preferences.playback, isNull);
    });
  });

  group('preference clamping (matches the live settings ranges)', () {
    test('maxBytes below the floor clamps up to the live minimum', () {
      const BackupPreferences prefs = BackupPreferences(
        cache: BackupCachePreferences(maxBytes: 1),
      );
      final BackupPreferences clamped = clampBackupPreferences(prefs);
      expect(clamped.cache?.maxBytes, CacheSize.minLimit);
    });

    test('maxBytes above the ceiling clamps down to the live maximum', () {
      const BackupPreferences prefs = BackupPreferences(
        cache: BackupCachePreferences(maxBytes: 999999999999999),
      );
      final BackupPreferences clamped = clampBackupPreferences(prefs);
      expect(clamped.cache?.maxBytes, CacheSize.maxLimit);
    });

    test('precacheCount junk → default, over-range → capped', () {
      const BackupPreferences low = BackupPreferences(
        cache: BackupCachePreferences(precacheCount: 0),
      );
      expect(
        clampBackupPreferences(low).cache?.precacheCount,
        kDefaultPrecacheCount,
      );

      const BackupPreferences high = BackupPreferences(
        cache: BackupCachePreferences(precacheCount: 9999),
      );
      expect(
        clampBackupPreferences(high).cache?.precacheCount,
        kMaxPrecacheCount,
      );
    });

    test('in-range values and booleans are preserved unchanged', () {
      const BackupPreferences prefs = BackupPreferences(
        cache: BackupCachePreferences(
          maxBytes: 5368709120,
          allowMobileData: true,
          smartPrecacheEnabled: false,
          precacheCount: 7,
        ),
      );
      final BackupCachePreferences? cache = clampBackupPreferences(prefs).cache;
      expect(cache?.maxBytes, 5368709120);
      expect(cache?.precacheCount, 7);
      expect(cache?.allowMobileData, isTrue);
      expect(cache?.smartPrecacheEnabled, isFalse);
    });

    test('clamping leaves non-cache preferences untouched', () {
      const BackupPreferences prefs = BackupPreferences(
        defaultProvider: 'plex',
        preferredSourceOrder: <String>['plex', 'local'],
        playbackSourceStrategy: 'preferHighestQuality',
        appearance: BackupAppearancePreferences(appIconVariant: 'gold'),
      );
      final BackupPreferences clamped = clampBackupPreferences(prefs);
      expect(clamped.defaultProvider, 'plex');
      expect(clamped.preferredSourceOrder, <String>['plex', 'local']);
      expect(clamped.playbackSourceStrategy, 'preferHighestQuality');
      expect(clamped.appearance?.appIconVariant, 'gold');
    });
  });
}
