/// The **restore preview** for a Linthra Backup V1 document: a pure-Dart,
/// read-only description of *what a restore would do*, produced by
/// `BackupRestoreService.previewRestore` / `planRestore` from a parsed backup
/// and the user's current setup.
///
/// This model never mutates app state and never carries a credential — it only
/// classifies the backup's entries so a (future) restore screen can show the
/// user exactly what will happen before they confirm:
///
/// - [BackupImportPlan.serversToAdd] — valid, known sources not already
///   configured. Each lands needing a [BackupRestoreFollowUp] (sign-in for a
///   network provider, folder re-pick for a local source) because V1 never
///   restores secrets.
/// - [BackupImportPlan.serversAlreadyConfigured] — entries whose
///   (`type`, normalized `baseUrl`) identity already exists; left as-is, never
///   duplicated.
/// - [BackupImportPlan.unknownServers] — a `type` this build doesn't recognise;
///   skipped with a notice, per the format's forward-compatibility rule.
/// - [BackupImportPlan.skippedServers] — malformed/unusable raw entries.
/// - [BackupImportPlan.preferences] — the clamped, ready-to-apply preferences,
///   plus what was clamped and which unknown keys were ignored.
///
/// It is deliberately free of Flutter, plugin, session, or store coupling so
/// the *same* preview can be reused by Linthra Desktop (Phase 4).
library;

import 'backup_models.dart';

/// The server `type` strings this build understands. Anything else is treated
/// as an [UnknownBackupServer] and skipped on restore (with a notice). Kept as
/// a set so the planner can branch before delegating to [BackupServer.fromJson]
/// (which itself encodes the same knowledge for the typed hierarchy).
const Set<String> kKnownBackupServerTypes = <String>{
  'jellyfin',
  'subsonic',
  'plex',
  'local',
};

/// Whether [type] is a server type this build can restore.
bool isKnownBackupServerType(String type) =>
    kKnownBackupServerTypes.contains(type);

/// Normalizes a server base URL into a stable key for duplicate detection.
///
/// Two addresses that point at the same server must collapse to the same key,
/// so the comparison is generous about the cosmetic differences a hand-typed or
/// hand-edited URL carries — without ever merging two genuinely different
/// servers:
///
/// - a missing scheme defaults to `https` (matching how the app normalizes a
///   typed address — a bare host is reached over TLS);
/// - the scheme and host are lower-cased (both are case-insensitive per the URL
///   spec);
/// - the default port for the scheme (`:80` for http, `:443` for https) is
///   dropped, while any other explicit port is kept (a LAN server is reached by
///   host:port);
/// - a trailing slash, query, and fragment are stripped.
///
/// The path case is preserved (a reverse-proxy subpath can be case-sensitive).
/// An unparseable string falls back to its trimmed, lower-cased, slash-free
/// form so two identical junk values still match.
String normalizeBackupBaseUrl(String? raw) {
  final String trimmed = (raw ?? '').trim();
  if (trimmed.isEmpty) return '';

  final String withScheme =
      trimmed.contains('://') ? trimmed : 'https://$trimmed';
  final Uri? uri = Uri.tryParse(withScheme);
  if (uri == null || uri.host.isEmpty) {
    return _stripTrailingSlashes(trimmed.toLowerCase());
  }

  final String scheme = uri.scheme.toLowerCase();
  final String host = uri.host.toLowerCase();
  final int? port = uri.hasPort ? uri.port : null;
  final bool isDefaultPort =
      (scheme == 'http' && port == 80) || (scheme == 'https' && port == 443);

  final StringBuffer key = StringBuffer()
    ..write(scheme)
    ..write('://')
    ..write(host);
  if (port != null && !isDefaultPort) {
    key
      ..write(':')
      ..write(port);
  }
  key.write(_stripTrailingSlashes(uri.path));
  return key.toString();
}

String _stripTrailingSlashes(String path) {
  int end = path.length;
  while (end > 0 && path[end - 1] == '/') {
    end--;
  }
  return path.substring(0, end);
}

/// The base URL of a parsed [server], or `null` for a source that has none
/// (a [LocalBackupServer], or an [UnknownBackupServer] without one).
String? backupServerBaseUrl(BackupServer server) {
  if (server is JellyfinBackupServer) return server.baseUrl;
  if (server is SubsonicBackupServer) return server.baseUrl;
  if (server is PlexBackupServer) return server.baseUrl;
  if (server is UnknownBackupServer) {
    final Object? raw = server.raw['baseUrl'];
    return (raw is String && raw.isNotEmpty) ? raw : null;
  }
  return null; // LocalBackupServer
}

/// The identity used to decide whether two sources are "the same server":
/// provider [type] plus the [normalizedBaseUrl]. A URL-less source (e.g.
/// `local`) keys on its type alone (empty URL), so a second on-device folder
/// entry is recognised as already configured rather than duplicated.
class BackupServerIdentity {
  const BackupServerIdentity({
    required this.type,
    required this.normalizedBaseUrl,
  });

  /// Builds an identity from a raw [type] and (optional) [baseUrl], normalizing
  /// the URL. This is the constructor the app uses to describe an *already
  /// configured* source for duplicate detection.
  factory BackupServerIdentity.of(String type, String? baseUrl) =>
      BackupServerIdentity(
        type: type,
        normalizedBaseUrl: normalizeBackupBaseUrl(baseUrl),
      );

  /// Builds the identity of a parsed backup [server].
  factory BackupServerIdentity.forServer(BackupServer server) =>
      BackupServerIdentity.of(server.type, backupServerBaseUrl(server));

  /// The provider type (`jellyfin` / `subsonic` / `plex` / `local`).
  final String type;

  /// The normalized base URL, or the empty string for a URL-less source.
  final String normalizedBaseUrl;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BackupServerIdentity &&
          other.type == type &&
          other.normalizedBaseUrl == normalizedBaseUrl);

  @override
  int get hashCode => Object.hash(type, normalizedBaseUrl);

  @override
  String toString() =>
      normalizedBaseUrl.isEmpty ? type : '$type@$normalizedBaseUrl';
}

/// What a restored server needs before it can play. V1 never restores a
/// credential, so every added server requires one of these one-time follow-ups.
enum BackupRestoreFollowUp {
  /// A network provider (`jellyfin` / `subsonic` / `plex`) must be signed in
  /// again — the user re-enters a password or pastes a token.
  signIn,

  /// An on-device folder (`local`) must be re-picked: an Android SAF grant is
  /// per-device and can't transfer, so restore carries only a hint.
  reselectFolder,
}

/// The follow-up a restored [server] requires: [BackupRestoreFollowUp.signIn]
/// for a network provider, [BackupRestoreFollowUp.reselectFolder] for a local
/// folder.
BackupRestoreFollowUp backupRestoreFollowUpFor(BackupServer server) =>
    server is LocalBackupServer
        ? BackupRestoreFollowUp.reselectFolder
        : BackupRestoreFollowUp.signIn;

/// A known, valid backup server the plan **will add**. It carries no
/// credential; after restore it lands in a *needs-[followUp]* state.
class PlannedServerAddition {
  const PlannedServerAddition({required this.server, required this.identity});

  /// The parsed, non-secret server model to add.
  final BackupServer server;

  /// Its duplicate-detection identity (type + normalized base URL).
  final BackupServerIdentity identity;

  String get type => server.type;
  String? get displayName => server.displayName;
  String get normalizedBaseUrl => identity.normalizedBaseUrl;

  /// The one-time action the user must take after restore.
  BackupRestoreFollowUp get followUp => backupRestoreFollowUpFor(server);

  /// Whether this server lands needing a sign-in (true for every network
  /// provider; false only for a local folder, which needs a re-pick instead).
  bool get needsSignIn => followUp == BackupRestoreFollowUp.signIn;
}

/// A known backup server **skipped because it is already configured** — its
/// (`type`, normalized `baseUrl`) identity matches a source the user already
/// has. Restore leaves the existing one untouched rather than duplicating it.
class PlannedDuplicateServer {
  const PlannedDuplicateServer({required this.server, required this.identity});

  final BackupServer server;
  final BackupServerIdentity identity;

  String get type => server.type;
  String? get displayName => server.displayName;
}

/// A backup server whose `type` this build does not recognise (a newer
/// provider, or a platform-specific type like `local` on Desktop). Restore
/// **skips it with a notice**, never an error — the format is forward-compatible
/// by design.
class PlannedUnknownServer {
  const PlannedUnknownServer({required this.typeName, this.displayName});

  /// The unrecognised `type` string from the file.
  final String typeName;

  /// The entry's display name, if it carried one (shown in the skip notice).
  final String? displayName;
}

/// Why a raw server entry could not be used and was skipped.
enum BackupServerSkipReason {
  /// The entry was not a JSON object.
  notAnObject,

  /// The entry had no usable `type` at all.
  missingType,

  /// A known type was missing a required field (e.g. a server with no
  /// `baseUrl`) and so could not be restored.
  missingRequiredField,
}

/// A raw server entry that was malformed/unusable and is skipped, with the
/// [reason] why.
class PlannedSkippedServer {
  const PlannedSkippedServer({required this.reason, this.typeName});

  final BackupServerSkipReason reason;

  /// The entry's declared `type` when it had a usable one (e.g. a known type
  /// missing its `baseUrl`); `null` when the entry had no type.
  final String? typeName;
}

/// A numeric preference value the file carried out of range, reported with how
/// it was clamped to the live setting's accepted range.
class BackupPreferenceClamp {
  const BackupPreferenceClamp({
    required this.field,
    required this.originalValue,
    required this.clampedValue,
  });

  /// Dotted field name, e.g. `cache.maxBytes` or `cache.precacheCount`.
  final String field;

  /// The value the backup file declared.
  final int originalValue;

  /// The value after clamping to the live range.
  final int clampedValue;
}

/// The preferences portion of a [BackupImportPlan]: the validated, clamped
/// preferences that would be applied, what was clamped, and which keys were
/// ignored.
class BackupPreferencesPlan {
  const BackupPreferencesPlan({
    this.applied = const BackupPreferences(),
    this.clamps = const <BackupPreferenceClamp>[],
    this.ignoredKeys = const <String>[],
  });

  /// The preferences ready to apply: only the keys the file actually carried,
  /// with numeric values already clamped to the live ranges. Applying these is
  /// the future restore step — this PR only *previews* them.
  final BackupPreferences applied;

  /// Numeric values that were clamped into range, for the user to see.
  final List<BackupPreferenceClamp> clamps;

  /// Preference keys present in the file that this build does not understand
  /// (including any secret-looking key a hand-edited file might carry) and so
  /// ignores. They never reach [applied].
  final List<String> ignoredKeys;

  /// Whether applying this plan would set any preference at all.
  bool get hasChanges => applied.toJson().isNotEmpty;
}

/// A read-only preview of what restoring a backup would do. Produced by
/// `BackupRestoreService`; it mutates nothing and contains no credentials.
class BackupImportPlan {
  const BackupImportPlan({
    this.serversToAdd = const <PlannedServerAddition>[],
    this.serversAlreadyConfigured = const <PlannedDuplicateServer>[],
    this.unknownServers = const <PlannedUnknownServer>[],
    this.skippedServers = const <PlannedSkippedServer>[],
    this.preferences = const BackupPreferencesPlan(),
    this.generatedBy,
    this.createdAt,
  });

  /// Valid, known sources not already configured — what restore will add.
  final List<PlannedServerAddition> serversToAdd;

  /// Entries already configured (same type + normalized base URL); left as-is.
  final List<PlannedDuplicateServer> serversAlreadyConfigured;

  /// Entries with an unrecognised `type`; skipped with a notice.
  final List<PlannedUnknownServer> unknownServers;

  /// Malformed/unusable raw entries; skipped.
  final List<PlannedSkippedServer> skippedServers;

  /// The preferences that would be applied, with clamp/ignore notes.
  final BackupPreferencesPlan preferences;

  /// Diagnostics-only provenance from the file (display only).
  final BackupGeneratedBy? generatedBy;

  /// The file's `createdAt` timestamp, if any (display only).
  final String? createdAt;

  int get addCount => serversToAdd.length;
  int get duplicateCount => serversAlreadyConfigured.length;
  int get unknownCount => unknownServers.length;
  int get skippedCount => skippedServers.length;

  bool get hasServersToAdd => serversToAdd.isNotEmpty;
  bool get hasPreferencesToApply => preferences.hasChanges;

  /// True when applying this plan would change nothing — no new server and no
  /// preference to set.
  bool get isEmpty => serversToAdd.isEmpty && !preferences.hasChanges;

  /// The servers that will land needing the user to sign in again (every
  /// network provider in [serversToAdd]).
  Iterable<PlannedServerAddition> get serversNeedingSignIn =>
      serversToAdd.where((PlannedServerAddition s) => s.needsSignIn);
}
