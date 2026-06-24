import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/features/backup_restore/backup_export_mapper.dart';
import 'package:linthra/features/backup_restore/backup_models.dart';
import 'package:linthra/features/backup_restore/backup_validation.dart';

/// JSON keys that must NEVER appear anywhere in an exported backup: the secrets
/// (Jellyfin access token, Subsonic salt+token, Plex token, any password) and
/// the device-/session-specific ids and version strings the spec excludes on
/// purpose (they are re-derived at re-auth and carrying them would let one
/// device impersonate another). See docs/backup-restore-format.md → Security.
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

/// Recursively collects every object key in a decoded JSON tree, so a secret
/// hidden in a nested object can't slip past a shallow check.
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

/// Sessions seeded with `SENTINEL-` secrets/ids. Every field that must never be
/// exported carries the `SENTINEL-` prefix, so a single check ("no `SENTINEL-`
/// in the file") proves none of them leaked, while the non-secret fields
/// (`baseUrl`, `username`, `serverType`, section keys) use ordinary values that
/// are *expected* to appear.
const JellyfinSession _jellyfin = JellyfinSession(
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

const SubsonicSession _subsonic = SubsonicSession(
  baseUrl: 'https://nd.example.com',
  username: 'alice',
  salt: 'SENTINEL-sub-salt',
  token: 'SENTINEL-sub-token',
  serverType: 'navidrome',
  serverVersion: 'SENTINEL-sub-server-version',
  apiVersion: 'SENTINEL-sub-api-version',
);

const PlexSession _plex = PlexSession(
  baseUrl: 'https://plex.example.com:32400',
  token: 'SENTINEL-plex-token',
  machineIdentifier: 'SENTINEL-plex-machine-id',
  serverName: 'Living-room Plex',
  serverVersion: 'SENTINEL-plex-server-version',
  clientIdentifier: 'SENTINEL-plex-client-id',
  selectedSectionKeys: <String>['3', '7'],
);

LinthraBackup _backupFromSecretSessions() => LinthraBackup(
      generatedBy: const BackupGeneratedBy(app: 'Linthra Android'),
      servers: <BackupServer>[
        jellyfinBackupServerFromSession(_jellyfin),
        subsonicBackupServerFromSession(_subsonic),
        plexBackupServerFromSession(_plex),
        localBackupServer(
          displayName: 'Phone music folder',
          folderHint:
              'content://com.android.externalstorage.documents/tree/primary%3AMusic',
        ),
      ],
      preferences: const BackupPreferences(
        defaultProvider: 'jellyfin',
        preferredSourceOrder: <String>['local', 'jellyfin', 'subsonic'],
        cache: BackupCachePreferences(maxBytes: 5368709120),
      ),
    );

void main() {
  group('a backup exports settings, never secrets', () {
    test('no secret/excluded value reaches the exported JSON', () {
      final String json = encodeBackup(_backupFromSecretSessions());

      // The single strongest regression: every secret and every excluded id /
      // version string was seeded with `SENTINEL-`. If ANY of them appears, the
      // projection leaked it — and this fails.
      expect(json, isNot(contains('SENTINEL-')));
    });

    test('no forbidden key appears anywhere in the document', () {
      final Object? decoded =
          jsonDecode(encodeBackup(_backupFromSecretSessions()));

      final Set<String> present = _allKeys(decoded);
      final Set<String> leaked = present.intersection(_forbiddenKeys);

      expect(
        leaked,
        isEmpty,
        reason: 'These secret/excluded keys must never be exported: $leaked',
      );
    });

    test('the non-secret settings ARE exported (the projection keeps them)',
        () {
      final String json = encodeBackup(_backupFromSecretSessions());

      // URLs, usernames, server type, and section keys are the whole point of a
      // settings backup.
      expect(json, contains('https://music.example.com'));
      expect(json, contains('https://nd.example.com'));
      expect(json, contains('https://plex.example.com:32400'));
      expect(json, contains('alice'));
      expect(json, contains('navidrome'));
      expect(json, contains('"3"'));
      expect(json, contains('"7"'));
    });
  });

  group('the projection — not the session — is what drops the secret', () {
    test('the sessions really do carry the secrets that must be dropped', () {
      // Sanity: prove the inputs are secret-bearing, so the absence above is
      // the mapper doing its job, not an empty fixture.
      expect(
          jsonEncode(_jellyfin.toJson()), contains('SENTINEL-jf-access-token'));
      expect(jsonEncode(_subsonic.toJson()), contains('SENTINEL-sub-token'));
      expect(jsonEncode(_subsonic.toJson()), contains('SENTINEL-sub-salt'));
      expect(jsonEncode(_plex.toJson()), contains('SENTINEL-plex-token'));
    });
  });

  group('each mapper emits only its allow-listed, non-secret fields', () {
    test('Jellyfin → {type, displayName, baseUrl, username} only', () {
      final Map<String, dynamic> json =
          jellyfinBackupServerFromSession(_jellyfin).toJson();
      expect(
        json.keys.toSet(),
        <String>{'type', 'displayName', 'baseUrl', 'username'},
      );
      expect(json.keys.toSet().intersection(_forbiddenKeys), isEmpty);
    });

    test('Subsonic → {type, displayName, baseUrl, username, serverType} only',
        () {
      final Map<String, dynamic> json =
          subsonicBackupServerFromSession(_subsonic).toJson();
      expect(
        json.keys.toSet(),
        <String>{'type', 'displayName', 'baseUrl', 'username', 'serverType'},
      );
      expect(json.keys.toSet().intersection(_forbiddenKeys), isEmpty);
    });

    test('Plex → {type, displayName, baseUrl, selectedSectionKeys} only', () {
      final Map<String, dynamic> json =
          plexBackupServerFromSession(_plex).toJson();
      expect(
        json.keys.toSet(),
        <String>{'type', 'displayName', 'baseUrl', 'selectedSectionKeys'},
      );
      expect(json.keys.toSet().intersection(_forbiddenKeys), isEmpty);
    });
  });

  group('passwords are never part of the format', () {
    test('no password field exists anywhere in a full backup', () {
      // Linthra never stores a password (it derives a token once, then discards
      // it), and the format has no field for one — assert both: the key is
      // absent from the model output entirely.
      final Object? decoded =
          jsonDecode(encodeBackup(_backupFromSecretSessions()));
      expect(_allKeys(decoded).contains('password'), isFalse);
    });
  });
}
