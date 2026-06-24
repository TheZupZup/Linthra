import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/backup_restore/backup_import_plan.dart';
import 'package:linthra/features/backup_restore/backup_models.dart';

void main() {
  group('normalizeBackupBaseUrl', () {
    test('strips a trailing slash', () {
      expect(
        normalizeBackupBaseUrl('https://music.example.com/'),
        'https://music.example.com',
      );
    });

    test('lower-cases the scheme and host (both case-insensitive)', () {
      expect(
        normalizeBackupBaseUrl('HTTPS://Music.Example.COM'),
        'https://music.example.com',
      );
    });

    test('assumes https when no scheme is typed', () {
      expect(
        normalizeBackupBaseUrl('music.example.com'),
        'https://music.example.com',
      );
    });

    test('drops the default port but keeps a non-default one', () {
      expect(
        normalizeBackupBaseUrl('https://music.example.com:443'),
        'https://music.example.com',
      );
      expect(
        normalizeBackupBaseUrl('http://192.168.1.10:80/'),
        'http://192.168.1.10',
      );
      expect(
        normalizeBackupBaseUrl('https://plex.example.com:32400'),
        'https://plex.example.com:32400',
      );
    });

    test('preserves a reverse-proxy subpath (case kept) and drops the query',
        () {
      expect(
        normalizeBackupBaseUrl('https://example.com/Jellyfin/?x=1'),
        'https://example.com/Jellyfin',
      );
    });

    test('an empty or null value is the empty key', () {
      expect(normalizeBackupBaseUrl(''), '');
      expect(normalizeBackupBaseUrl(null), '');
      expect(normalizeBackupBaseUrl('   '), '');
    });

    test('cosmetic variants of the same server collapse to one key', () {
      final String a = normalizeBackupBaseUrl('https://music.example.com');
      final String b = normalizeBackupBaseUrl('HTTPS://music.example.com/');
      final String c = normalizeBackupBaseUrl('music.example.com:443/');
      expect(a, b);
      expect(b, c);
    });
  });

  group('backupServerBaseUrl', () {
    test('returns the URL for each network type and null for local', () {
      expect(
        backupServerBaseUrl(
          const JellyfinBackupServer(baseUrl: 'https://jf.example.com'),
        ),
        'https://jf.example.com',
      );
      expect(
        backupServerBaseUrl(
          const SubsonicBackupServer(baseUrl: 'https://nd.example.com'),
        ),
        'https://nd.example.com',
      );
      expect(
        backupServerBaseUrl(
          const PlexBackupServer(baseUrl: 'https://plex.example.com:32400'),
        ),
        'https://plex.example.com:32400',
      );
      expect(backupServerBaseUrl(const LocalBackupServer()), isNull);
    });

    test('reads a baseUrl out of an unknown server entry when present', () {
      const UnknownBackupServer unknown = UnknownBackupServer(
        typeName: 'futuresonic',
        raw: <String, dynamic>{
          'type': 'futuresonic',
          'baseUrl': 'https://future.example.com',
        },
      );
      expect(backupServerBaseUrl(unknown), 'https://future.example.com');
      expect(
        backupServerBaseUrl(
          const UnknownBackupServer(typeName: 'futuresonic'),
        ),
        isNull,
      );
    });
  });

  group('isKnownBackupServerType', () {
    test('recognises exactly the four V1 types', () {
      expect(isKnownBackupServerType('jellyfin'), isTrue);
      expect(isKnownBackupServerType('subsonic'), isTrue);
      expect(isKnownBackupServerType('plex'), isTrue);
      expect(isKnownBackupServerType('local'), isTrue);
      expect(isKnownBackupServerType('futuresonic'), isFalse);
      expect(isKnownBackupServerType(''), isFalse);
    });
  });

  group('BackupServerIdentity', () {
    test('normalizes the URL and compares by (type, normalized URL)', () {
      final BackupServerIdentity a = BackupServerIdentity.of(
        'jellyfin',
        'https://music.example.com',
      );
      final BackupServerIdentity b = BackupServerIdentity.of(
        'jellyfin',
        'https://music.example.com/',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(<BackupServerIdentity>{a, b}, hasLength(1));
    });

    test('a different type or host is a different identity', () {
      final BackupServerIdentity jellyfin = BackupServerIdentity.of(
        'jellyfin',
        'https://music.example.com',
      );
      expect(
        jellyfin,
        isNot(BackupServerIdentity.of('plex', 'https://music.example.com')),
      );
      expect(
        jellyfin,
        isNot(BackupServerIdentity.of('jellyfin', 'https://other.example.com')),
      );
    });

    test('forServer derives the identity from a parsed server', () {
      final BackupServerIdentity jellyfin = BackupServerIdentity.forServer(
        const JellyfinBackupServer(baseUrl: 'https://music.example.com/'),
      );
      expect(jellyfin.type, 'jellyfin');
      expect(jellyfin.normalizedBaseUrl, 'https://music.example.com');
    });

    test('a local source keys on its type alone (empty URL)', () {
      final BackupServerIdentity local =
          BackupServerIdentity.forServer(const LocalBackupServer());
      expect(local.type, 'local');
      expect(local.normalizedBaseUrl, '');
      // Two local sources are "the same" identity (only one folder source).
      expect(local, BackupServerIdentity.of('local', null));
    });
  });

  group('backupRestoreFollowUpFor', () {
    test('network providers need a sign-in; local needs a folder re-pick', () {
      expect(
        backupRestoreFollowUpFor(
          const JellyfinBackupServer(baseUrl: 'https://jf.example.com'),
        ),
        BackupRestoreFollowUp.signIn,
      );
      expect(
        backupRestoreFollowUpFor(
          const SubsonicBackupServer(baseUrl: 'https://nd.example.com'),
        ),
        BackupRestoreFollowUp.signIn,
      );
      expect(
        backupRestoreFollowUpFor(
          const PlexBackupServer(baseUrl: 'https://plex.example.com:32400'),
        ),
        BackupRestoreFollowUp.signIn,
      );
      expect(
        backupRestoreFollowUpFor(const LocalBackupServer()),
        BackupRestoreFollowUp.reselectFolder,
      );
    });
  });

  group('PlannedServerAddition', () {
    test('exposes type/displayName and the right follow-up per server', () {
      const JellyfinBackupServer server = JellyfinBackupServer(
        displayName: 'Home Jellyfin',
        baseUrl: 'https://music.example.com',
        username: 'alice',
      );
      final PlannedServerAddition addition = PlannedServerAddition(
        server: server,
        identity: BackupServerIdentity.forServer(server),
      );
      expect(addition.type, 'jellyfin');
      expect(addition.displayName, 'Home Jellyfin');
      expect(addition.normalizedBaseUrl, 'https://music.example.com');
      expect(addition.needsSignIn, isTrue);
      expect(addition.followUp, BackupRestoreFollowUp.signIn);
    });

    test('a local addition needs a folder re-pick, not a sign-in', () {
      const LocalBackupServer server = LocalBackupServer(
        displayName: 'Phone music',
      );
      final PlannedServerAddition addition = PlannedServerAddition(
        server: server,
        identity: BackupServerIdentity.forServer(server),
      );
      expect(addition.needsSignIn, isFalse);
      expect(addition.followUp, BackupRestoreFollowUp.reselectFolder);
    });
  });

  group('BackupPreferencesPlan', () {
    test('hasChanges reflects whether any preference would be applied', () {
      const BackupPreferencesPlan empty = BackupPreferencesPlan();
      expect(empty.hasChanges, isFalse);

      const BackupPreferencesPlan some = BackupPreferencesPlan(
        applied: BackupPreferences(defaultProvider: 'jellyfin'),
      );
      expect(some.hasChanges, isTrue);
    });
  });

  group('BackupImportPlan convenience', () {
    test('an all-empty plan is isEmpty with zero counts', () {
      const BackupImportPlan plan = BackupImportPlan();
      expect(plan.isEmpty, isTrue);
      expect(plan.hasServersToAdd, isFalse);
      expect(plan.hasPreferencesToApply, isFalse);
      expect(plan.addCount, 0);
      expect(plan.duplicateCount, 0);
      expect(plan.unknownCount, 0);
      expect(plan.skippedCount, 0);
      expect(plan.serversNeedingSignIn, isEmpty);
    });

    test('counts entries; only network servers need sign-in', () {
      const JellyfinBackupServer jellyfin = JellyfinBackupServer(
        baseUrl: 'https://music.example.com',
      );
      const LocalBackupServer local = LocalBackupServer();
      final BackupImportPlan plan = BackupImportPlan(
        serversToAdd: <PlannedServerAddition>[
          PlannedServerAddition(
            server: jellyfin,
            identity: BackupServerIdentity.forServer(jellyfin),
          ),
          PlannedServerAddition(
            server: local,
            identity: BackupServerIdentity.forServer(local),
          ),
        ],
        preferences: const BackupPreferencesPlan(
          applied: BackupPreferences(defaultProvider: 'jellyfin'),
        ),
      );

      expect(plan.isEmpty, isFalse);
      expect(plan.addCount, 2);
      expect(plan.hasPreferencesToApply, isTrue);
      // Only the Jellyfin server needs a sign-in; the local folder does not.
      expect(plan.serversNeedingSignIn, hasLength(1));
      expect(plan.serversNeedingSignIn.single.type, 'jellyfin');
    });
  });
}
