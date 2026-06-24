import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cache_size.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/repositories/download_preferences.dart';
import 'package:linthra/features/backup_restore/backup_import_plan.dart';
import 'package:linthra/features/backup_restore/backup_models.dart';
import 'package:linthra/features/backup_restore/backup_restore_service.dart';
import 'package:linthra/features/backup_restore/backup_validation.dart';

/// Secret/excluded keys that must NEVER appear in anything the service writes
/// or plans to apply (mirrors `backup_security_test.dart`).
const Set<String> _forbiddenKeys = <String>{
  'accessToken',
  'token',
  'salt',
  'password',
  'deviceId',
  'userId',
  'serverId',
  'machineIdentifier',
  'clientIdentifier',
  'serverVersion',
  'apiVersion',
  'productName',
};

/// Recursively collects every object key in a decoded JSON tree.
Set<String> _allKeys(Object? node) {
  final Set<String> keys = <String>{};
  if (node is Map) {
    node.forEach((Object? key, Object? value) {
      keys.add(key.toString());
      keys.addAll(_allKeys(value));
    });
  } else if (node is List) {
    for (final Object? element in node) {
      keys.addAll(_allKeys(element));
    }
  }
  return keys;
}

/// Frames an inner backup object as the full document JSON text.
String _wrap(Map<String, dynamic> inner) =>
    jsonEncode(<String, dynamic>{kBackupEnvelopeKey: inner});

/// Convenience: the plan for [text], asserting the file was readable.
BackupImportPlan _planOf(
  String text, {
  Iterable<BackupServerIdentity> existing = const <BackupServerIdentity>[],
}) {
  const BackupRestoreService service = BackupRestoreService();
  final BackupRestorePreview preview =
      service.previewRestore(text, existingServers: existing);
  expect(preview, isA<BackupRestorePreviewReady>());
  return (preview as BackupRestorePreviewReady).plan;
}

// Secret-bearing sessions: every must-not-export field carries `SENTINEL-`.
const JellyfinSession _secretJellyfin = JellyfinSession(
  baseUrl: 'https://music.example.com',
  userId: 'SENTINEL-jf-user-id',
  accessToken: 'SENTINEL-jf-access-token',
  deviceId: 'SENTINEL-jf-device-id',
  userName: 'alice',
  serverId: 'SENTINEL-jf-server-id',
  serverName: 'Home Jellyfin',
  serverVersion: 'SENTINEL-jf-server-version',
  productName: 'SENTINEL-jf-product-name',
);

const SubsonicSession _secretSubsonic = SubsonicSession(
  baseUrl: 'https://nd.example.com',
  username: 'alice',
  salt: 'SENTINEL-sub-salt',
  token: 'SENTINEL-sub-token',
  serverType: 'navidrome',
  serverVersion: 'SENTINEL-sub-server-version',
  apiVersion: 'SENTINEL-sub-api-version',
);

const PlexSession _secretPlex = PlexSession(
  baseUrl: 'https://plex.example.com:32400',
  token: 'SENTINEL-plex-token',
  machineIdentifier: 'SENTINEL-plex-machine-id',
  serverName: 'Living-room Plex',
  serverVersion: 'SENTINEL-plex-server-version',
  clientIdentifier: 'SENTINEL-plex-client-id',
  selectedSectionKeys: <String>['3', '7'],
);

void main() {
  const BackupRestoreService service = BackupRestoreService();

  group('export — buildBackup', () {
    test('build → encode → read round-trips the same document', () {
      final LinthraBackup backup = service.buildBackup(
        jellyfin: _secretJellyfin,
        subsonic: _secretSubsonic,
        plex: _secretPlex,
        local: const LocalFolderBackup(
          displayName: 'Phone music folder',
          folderHint: 'content://com.android.externalstorage.documents/'
              'tree/primary%3AMusic',
        ),
        preferences: const BackupPreferences(
          defaultProvider: 'jellyfin',
          preferredSourceOrder: <String>['local', 'jellyfin', 'subsonic'],
          cache: BackupCachePreferences(maxBytes: 5368709120),
        ),
        generatedBy: const BackupGeneratedBy(
          app: 'Linthra Android',
          appVersion: '0.1.7',
        ),
        createdAt: '2026-06-24T12:00:00Z',
      );

      expect(backup.servers, hasLength(4));

      final BackupReadResult result = readBackup(service.encode(backup));
      expect(result, isA<BackupReadSuccess>());
      expect((result as BackupReadSuccess).backup.toJson(), backup.toJson());
    });

    test('omits a provider that is not configured', () {
      final LinthraBackup backup =
          service.buildBackup(jellyfin: _secretJellyfin);
      expect(backup.servers, hasLength(1));
      expect(backup.servers.single, isA<JellyfinBackupServer>());
    });

    test('an empty setup builds an empty (but valid) backup', () {
      final LinthraBackup backup = service.buildBackup();
      expect(backup.servers, isEmpty);
      final BackupReadResult result = readBackup(service.encode(backup));
      expect(result, isA<BackupReadSuccess>());
    });
  });

  group('export — settings, never secrets', () {
    test('a backup the service builds carries no secret/excluded value', () {
      final String json = service.encode(
        service.buildBackup(
          jellyfin: _secretJellyfin,
          subsonic: _secretSubsonic,
          plex: _secretPlex,
          local: const LocalFolderBackup(displayName: 'Phone'),
        ),
      );

      // Not one seeded secret/id/version string leaks.
      expect(json, isNot(contains('SENTINEL-')));

      // No forbidden key appears anywhere in the document.
      final Set<String> leaked =
          _allKeys(jsonDecode(json)).intersection(_forbiddenKeys);
      expect(leaked, isEmpty, reason: 'leaked secret keys: $leaked');

      // The non-secret settings ARE present (it isn't just an empty file).
      expect(json, contains('https://music.example.com'));
      expect(json, contains('https://nd.example.com'));
      expect(json, contains('alice'));
      expect(json, contains('navidrome'));
    });
  });

  group('restore preview — reading & gating malformed files', () {
    test('a valid backup yields a ready plan', () {
      final String text = _wrap(<String, dynamic>{
        'formatVersion': 1,
        'kind': 'settings',
        'servers': <Object>[],
        'preferences': <String, dynamic>{},
      });
      expect(service.previewRestore(text), isA<BackupRestorePreviewReady>());
    });

    test('not JSON → unreadable (notJson)', () {
      final BackupRestorePreview preview =
          service.previewRestore('{not valid json');
      expect(preview, isA<BackupRestorePreviewUnreadable>());
      expect(
        (preview as BackupRestorePreviewUnreadable).failure.reason,
        BackupReadFailureReason.notJson,
      );
    });

    test('valid JSON without the marker → unreadable (notLinthraBackup)', () {
      final BackupRestorePreview preview =
          service.previewRestore('{"somethingElse": true}');
      expect(
        (preview as BackupRestorePreviewUnreadable).failure.reason,
        BackupReadFailureReason.notLinthraBackup,
      );
    });

    test('a newer formatVersion → unreadable (unsupportedVersion)', () {
      final String text = _wrap(<String, dynamic>{
        'formatVersion': kBackupFormatVersion + 1,
        'servers': <Object>[],
        'preferences': <String, dynamic>{},
      });
      final BackupRestorePreview preview = service.previewRestore(text);
      final BackupRestorePreviewUnreadable unreadable =
          preview as BackupRestorePreviewUnreadable;
      expect(
        unreadable.failure.reason,
        BackupReadFailureReason.unsupportedVersion,
      );
      expect(unreadable.failure.message, contains('newer version'));
    });

    test('a missing/invalid formatVersion → unreadable (malformed)', () {
      final String text = _wrap(<String, dynamic>{
        'servers': <Object>[],
        'preferences': <String, dynamic>{},
      });
      expect(
        (service.previewRestore(text) as BackupRestorePreviewUnreadable)
            .failure
            .reason,
        BackupReadFailureReason.malformed,
      );
    });
  });

  group('import preview — server classification', () {
    test('adds known servers, flags unknown, and skips malformed entries', () {
      final String text = _wrap(<String, dynamic>{
        'formatVersion': 1,
        'servers': <Object>[
          <String, dynamic>{
            'type': 'jellyfin',
            'baseUrl': 'https://music.example.com',
            'username': 'alice',
          },
          <String, dynamic>{
            'type': 'subsonic',
            'baseUrl': 'https://nd.example.com',
            'serverType': 'navidrome',
          },
          <String, dynamic>{
            'type': 'plex',
            'baseUrl': 'https://plex.example.com:32400',
            'selectedSectionKeys': <String>['3'],
          },
          <String, dynamic>{'type': 'local', 'folderHint': 'content://x'},
          // Unknown provider type — skipped with a notice, not dropped.
          <String, dynamic>{
            'type': 'futuresonic',
            'displayName': 'Future Server',
            'baseUrl': 'https://future.example.com',
          },
          // Malformed: a known type missing its required baseUrl.
          <String, dynamic>{'type': 'jellyfin', 'username': 'bob'},
          // Malformed: no usable type.
          <String, dynamic>{'displayName': 'No type'},
          // Malformed: not even an object.
          'junk',
        ],
        'preferences': <String, dynamic>{},
      });

      final BackupImportPlan plan = _planOf(text);

      expect(plan.addCount, 4);
      expect(
        plan.serversToAdd.map((PlannedServerAddition s) => s.type).toList(),
        <String>['jellyfin', 'subsonic', 'plex', 'local'],
      );

      // Every network server lands needing a sign-in; the local one needs a
      // folder re-pick instead.
      expect(plan.serversNeedingSignIn, hasLength(3));
      final PlannedServerAddition local = plan.serversToAdd
          .firstWhere((PlannedServerAddition s) => s.type == 'local');
      expect(local.needsSignIn, isFalse);
      expect(local.followUp, BackupRestoreFollowUp.reselectFolder);

      // Unknown type preserved as skippable, with its label for the notice.
      expect(plan.unknownServers, hasLength(1));
      expect(plan.unknownServers.single.typeName, 'futuresonic');
      expect(plan.unknownServers.single.displayName, 'Future Server');

      // The three malformed entries are skipped, each with the right reason.
      expect(
        plan.skippedServers.map((PlannedSkippedServer s) => s.reason).toSet(),
        <BackupServerSkipReason>{
          BackupServerSkipReason.missingRequiredField,
          BackupServerSkipReason.missingType,
          BackupServerSkipReason.notAnObject,
        },
      );
      final PlannedSkippedServer missingUrl = plan.skippedServers.firstWhere(
        (PlannedSkippedServer s) =>
            s.reason == BackupServerSkipReason.missingRequiredField,
      );
      expect(missingUrl.typeName, 'jellyfin');
    });
  });

  group('import preview — duplicate detection (type + normalized URL)', () {
    test('an already-configured server is flagged, not re-added', () {
      final String text = _wrap(<String, dynamic>{
        'formatVersion': 1,
        'servers': <Object>[
          // Same server as the existing one, but with a cosmetic trailing
          // slash — must still be recognised as already configured.
          <String, dynamic>{
            'type': 'jellyfin',
            'baseUrl': 'https://music.example.com/',
          },
          <String, dynamic>{
            'type': 'plex',
            'baseUrl': 'https://plex.example.com:32400',
          },
        ],
        'preferences': <String, dynamic>{},
      });

      final BackupImportPlan plan = _planOf(
        text,
        existing: <BackupServerIdentity>[
          BackupServerIdentity.of('jellyfin', 'https://music.example.com'),
        ],
      );

      expect(plan.addCount, 1);
      expect(plan.serversToAdd.single.type, 'plex');
      expect(plan.duplicateCount, 1);
      expect(plan.serversAlreadyConfigured.single.type, 'jellyfin');
    });

    test('the same server listed twice in one file is added only once', () {
      final String text = _wrap(<String, dynamic>{
        'formatVersion': 1,
        'servers': <Object>[
          <String, dynamic>{
            'type': 'subsonic',
            'baseUrl': 'https://nd.example.com',
          },
          <String, dynamic>{
            'type': 'subsonic',
            'baseUrl': 'https://nd.example.com',
          },
        ],
        'preferences': <String, dynamic>{},
      });

      final BackupImportPlan plan = _planOf(text);
      expect(plan.addCount, 1);
      expect(plan.duplicateCount, 1);
    });

    test('a different provider sharing a URL is not a duplicate', () {
      final String text = _wrap(<String, dynamic>{
        'formatVersion': 1,
        'servers': <Object>[
          <String, dynamic>{
            'type': 'subsonic',
            'baseUrl': 'https://media.example.com',
          },
        ],
        'preferences': <String, dynamic>{},
      });

      // Existing Jellyfin at the same URL must NOT shadow a Subsonic add.
      final BackupImportPlan plan = _planOf(
        text,
        existing: <BackupServerIdentity>[
          BackupServerIdentity.of('jellyfin', 'https://media.example.com'),
        ],
      );
      expect(plan.addCount, 1);
      expect(plan.duplicateCount, 0);
    });
  });

  group('import preview — preferences (applied / clamped / ignored)', () {
    test('known preferences apply; numeric values are clamped to range', () {
      final String text = _wrap(<String, dynamic>{
        'formatVersion': 1,
        'servers': <Object>[],
        'preferences': <String, dynamic>{
          'defaultProvider': 'plex',
          'cache': <String, dynamic>{
            'maxBytes': 1, // below the floor → clamps up
            'precacheCount': 9999, // above the cap → clamps down
            'allowMobileData': true,
          },
        },
      });

      final BackupImportPlan plan = _planOf(text);
      final BackupPreferencesPlan prefs = plan.preferences;

      expect(prefs.applied.defaultProvider, 'plex');
      expect(prefs.applied.cache?.maxBytes, CacheSize.minLimit);
      expect(prefs.applied.cache?.precacheCount, kMaxPrecacheCount);
      expect(prefs.applied.cache?.allowMobileData, isTrue);

      expect(
        prefs.clamps.map((BackupPreferenceClamp c) => c.field).toSet(),
        <String>{'cache.maxBytes', 'cache.precacheCount'},
      );
      final BackupPreferenceClamp count = prefs.clamps.firstWhere(
        (BackupPreferenceClamp c) => c.field == 'cache.precacheCount',
      );
      expect(count.originalValue, 9999);
      expect(count.clampedValue, kMaxPrecacheCount);
    });

    test('in-range values apply unchanged and report no clamp', () {
      final String text = _wrap(<String, dynamic>{
        'formatVersion': 1,
        'servers': <Object>[],
        'preferences': <String, dynamic>{
          'cache': <String, dynamic>{
            'maxBytes': 5368709120,
            'precacheCount': 7,
          },
        },
      });
      final BackupPreferencesPlan prefs = _planOf(text).preferences;
      expect(prefs.applied.cache?.maxBytes, 5368709120);
      expect(prefs.applied.cache?.precacheCount, 7);
      expect(prefs.clamps, isEmpty);
    });

    test('unknown preference keys are ignored (and reported), not applied', () {
      final String text = _wrap(<String, dynamic>{
        'formatVersion': 1,
        'servers': <Object>[],
        'preferences': <String, dynamic>{
          'defaultProvider': 'jellyfin',
          'futurePreference': 42,
          'cache': <String, dynamic>{
            'maxBytes': 5368709120,
            'futureCacheKnob': 'ignored',
          },
        },
      });
      final BackupPreferencesPlan prefs = _planOf(text).preferences;

      expect(prefs.applied.defaultProvider, 'jellyfin');
      expect(prefs.applied.cache?.maxBytes, 5368709120);
      expect(prefs.ignoredKeys, contains('futurePreference'));
      expect(prefs.ignoredKeys, contains('cache.futureCacheKnob'));
      // The applied preferences carry only known keys.
      expect(prefs.applied.toJson().containsKey('futurePreference'), isFalse);
    });

    test('a wrong-typed preference is dropped, not crashed on', () {
      final String text = _wrap(<String, dynamic>{
        'formatVersion': 1,
        'servers': <Object>[],
        'preferences': <String, dynamic>{
          'defaultProvider': 123,
          'cache': <String, dynamic>{'maxBytes': 'huge'},
        },
      });
      final BackupPreferencesPlan prefs = _planOf(text).preferences;
      expect(prefs.applied.defaultProvider, isNull);
      expect(prefs.applied.cache, isNull);
    });
  });

  group('restore planning never writes credentials or imports secrets', () {
    // A hostile/hand-edited backup: every server and the preferences carry
    // secret-looking keys seeded with `SENTINEL-` values.
    String hostileBackup() => _wrap(<String, dynamic>{
          'formatVersion': 1,
          'kind': 'settings',
          'servers': <Object>[
            <String, dynamic>{
              'type': 'jellyfin',
              'baseUrl': 'https://music.example.com',
              'username': 'alice',
              'accessToken': 'SENTINEL-jf-token',
              'deviceId': 'SENTINEL-jf-device',
              'password': 'SENTINEL-jf-password',
            },
            <String, dynamic>{
              'type': 'subsonic',
              'baseUrl': 'https://nd.example.com',
              'username': 'alice',
              'salt': 'SENTINEL-sub-salt',
              'token': 'SENTINEL-sub-token',
            },
            <String, dynamic>{
              'type': 'plex',
              'baseUrl': 'https://plex.example.com:32400',
              'token': 'SENTINEL-plex-token',
              'machineIdentifier': 'SENTINEL-plex-machine',
              'selectedSectionKeys': <String>['3'],
            },
          ],
          'preferences': <String, dynamic>{
            'defaultProvider': 'jellyfin',
            'password': 'SENTINEL-pref-password',
            'token': 'SENTINEL-pref-token',
            'cache': <String, dynamic>{
              'maxBytes': 5368709120,
              'secretKnob': 'SENTINEL-cache-secret',
            },
          },
        });

    test('no planned server addition carries a secret/excluded field', () {
      final BackupImportPlan plan = _planOf(hostileBackup());
      expect(plan.addCount, 3);

      for (final PlannedServerAddition addition in plan.serversToAdd) {
        final Map<String, dynamic> json = addition.server.toJson();
        expect(
          json.keys.toSet().intersection(_forbiddenKeys),
          isEmpty,
          reason: 'a ${addition.type} addition leaked: ${json.keys}',
        );
        expect(jsonEncode(json), isNot(contains('SENTINEL-')));
      }

      // The non-secret settings DID survive (it isn't dropping everything).
      final Set<String> urls = plan.serversToAdd
          .map((PlannedServerAddition s) => s.normalizedBaseUrl)
          .toSet();
      expect(urls, contains('https://music.example.com'));
    });

    test('every restored network server is treated as needs-sign-in', () {
      final BackupImportPlan plan = _planOf(hostileBackup());
      // No credential was imported, so all three must require signing in again.
      expect(plan.serversNeedingSignIn, hasLength(3));
      for (final PlannedServerAddition addition in plan.serversToAdd) {
        expect(addition.needsSignIn, isTrue);
      }
    });

    test('applied preferences contain no secret, and secret keys are ignored',
        () {
      final BackupPreferencesPlan prefs = _planOf(hostileBackup()).preferences;

      // The legitimate preference still applied.
      expect(prefs.applied.defaultProvider, 'jellyfin');
      expect(prefs.applied.cache?.maxBytes, 5368709120);

      // Nothing secret reached the applied set.
      final Map<String, dynamic> appliedJson = prefs.applied.toJson();
      expect(
        _allKeys(appliedJson).intersection(_forbiddenKeys),
        isEmpty,
      );
      expect(jsonEncode(appliedJson), isNot(contains('SENTINEL-')));

      // The secret-looking keys were seen and explicitly ignored.
      expect(prefs.ignoredKeys, contains('password'));
      expect(prefs.ignoredKeys, contains('token'));
      expect(prefs.ignoredKeys, contains('cache.secretKnob'));
    });

    test('the whole plan, re-serialized, contains no seeded secret value', () {
      final BackupImportPlan plan = _planOf(hostileBackup());
      final StringBuffer everything = StringBuffer()
        ..write(jsonEncode(plan.preferences.applied.toJson()));
      for (final PlannedServerAddition addition in plan.serversToAdd) {
        everything.write(jsonEncode(addition.server.toJson()));
      }
      expect(everything.toString(), isNot(contains('SENTINEL-')));
    });
  });
}
