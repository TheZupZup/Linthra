/// The Backup/Restore V1 **service layer**: a small, pure-Dart facade that
/// composes the format building blocks from PR #246 into the two operations the
/// (future) UI needs, while keeping every safety rule in one testable place.
///
/// 1. **Export** — [BackupRestoreService.buildBackup] projects the live,
///    secret-bearing app setup into a non-secret [LinthraBackup]. It is the
///    *only* place a backup document is assembled, and it routes every server
///    through the `backup_export_mapper` projection, so a credential structurally
///    cannot reach the file (the models have no field for one).
/// 2. **Restore preview** — [BackupRestoreService.previewRestore] reads a file's
///    text and, for a valid backup, returns a [BackupImportPlan] describing what
///    a restore *would* do (servers to add, already-configured duplicates,
///    unknown types, skipped/malformed entries, and the clamped preferences).
///    It **plans only**: it mutates no app state and writes no credential.
///
/// Everything here is pure Dart (no Flutter, no plugins, no I/O), so it runs the
/// same on Android, on Desktop (Phase 4), and in tests, and so Linthra Connect
/// (Phase 3) can reuse it as a thin transport over this same plan.
library;

import 'dart:convert';

import '../../core/models/jellyfin_session.dart';
import '../../core/models/plex_session.dart';
import '../../core/models/subsonic_session.dart';
import 'backup_export_mapper.dart';
import 'backup_import_plan.dart';
import 'backup_models.dart';
import 'backup_validation.dart';

/// The non-secret on-device folder source, supplied to [BackupRestoreService.
/// buildBackup]. There is no session (and no secret) for a local folder; the
/// [folderHint] is the SAF tree URI carried for the user's reference only.
class LocalFolderBackup {
  const LocalFolderBackup({this.displayName, this.folderHint});

  final String? displayName;
  final String? folderHint;
}

/// The outcome of [BackupRestoreService.previewRestore]: either a ready
/// [BackupImportPlan] or a typed, user-facing reason the file can't be read.
sealed class BackupRestorePreview {
  const BackupRestorePreview();
}

/// A readable backup: [plan] describes what a restore would do.
class BackupRestorePreviewReady extends BackupRestorePreview {
  const BackupRestorePreviewReady(this.plan);

  final BackupImportPlan plan;
}

/// The file could not be read as a usable backup; [failure] carries the typed
/// reason and a clear, user-facing message (reused from `backup_validation`).
class BackupRestorePreviewUnreadable extends BackupRestorePreview {
  const BackupRestorePreviewUnreadable(this.failure);

  final BackupReadFailure failure;
}

/// Builds backups and previews restores for the Backup/Restore V1 format.
/// Stateless and `const`-constructible, so it can be shared or injected freely.
class BackupRestoreService {
  const BackupRestoreService();

  /// **Export.** Builds a non-secret [LinthraBackup] from the live setup: each
  /// supplied session is projected through its `backup_export_mapper`
  /// projection (which copies out only the documented, non-secret fields), and
  /// the non-secret [preferences] are carried as-is. A `null` provider is simply
  /// omitted.
  ///
  /// The result structurally cannot contain a Jellyfin/Plex token, a Subsonic
  /// salt/token, a password, or any device-/session-specific id — see
  /// `backup_models.dart` and the security tests.
  LinthraBackup buildBackup({
    JellyfinSession? jellyfin,
    SubsonicSession? subsonic,
    PlexSession? plex,
    LocalFolderBackup? local,
    BackupPreferences preferences = const BackupPreferences(),
    BackupGeneratedBy? generatedBy,
    String? createdAt,
  }) {
    final List<BackupServer> servers = <BackupServer>[
      if (jellyfin != null) jellyfinBackupServerFromSession(jellyfin),
      if (subsonic != null) subsonicBackupServerFromSession(subsonic),
      if (plex != null) plexBackupServerFromSession(plex),
      if (local != null)
        localBackupServer(
          displayName: local.displayName,
          folderHint: local.folderHint,
        ),
    ];
    return LinthraBackup(
      generatedBy: generatedBy,
      createdAt: createdAt,
      servers: servers,
      preferences: preferences,
    );
  }

  /// Serializes [backup] to the pretty-printed JSON text of a backup file.
  /// A thin convenience over [encodeBackup] so callers need only this service.
  String encode(LinthraBackup backup) => encodeBackup(backup);

  /// **Restore preview from file text.** Validates the envelope and version via
  /// [readBackup]; on a readable backup, returns a [BackupRestorePreviewReady]
  /// wrapping the [BackupImportPlan]. A non-JSON, non-Linthra, newer-version, or
  /// malformed file becomes a [BackupRestorePreviewUnreadable] carrying the
  /// typed reason and message — never a throw, never a partial import.
  ///
  /// [existingServers] is the user's current setup (one [BackupServerIdentity]
  /// per configured source); it drives duplicate detection. Pass none to preview
  /// onto a fresh install (everything known is "to add").
  BackupRestorePreview previewRestore(
    String text, {
    Iterable<BackupServerIdentity> existingServers =
        const <BackupServerIdentity>[],
  }) {
    final BackupReadResult result = readBackup(text);
    if (result is BackupReadFailure) {
      return BackupRestorePreviewUnreadable(result);
    }
    final LinthraBackup backup = (result as BackupReadSuccess).backup;
    // Re-read the raw inner object so the plan can also report entries the
    // lenient model parser silently drops (malformed servers) and unknown
    // preference keys. The text already parsed cleanly inside [readBackup], so
    // this can't fail; the parsed model's own JSON is a safe fallback.
    final Map<String, dynamic> inner = _innerObjectOf(text) ?? backup.toJson();
    return BackupRestorePreviewReady(
      planRestore(inner, existingServers: existingServers),
    );
  }

  /// **The planner.** Classifies the raw [inner] backup object (the value under
  /// the `linthraBackup` envelope) against the current setup into a
  /// [BackupImportPlan]. Works directly on the raw map so it can count entries
  /// the typed parser drops; reuses [BackupServer.fromJson] /
  /// [BackupPreferences.fromJson] for the actual parsing so the model stays the
  /// single source of truth.
  ///
  /// Mutates nothing and reads no credential.
  BackupImportPlan planRestore(
    Map<String, dynamic> inner, {
    Iterable<BackupServerIdentity> existingServers =
        const <BackupServerIdentity>[],
  }) {
    final List<PlannedServerAddition> toAdd = <PlannedServerAddition>[];
    final List<PlannedDuplicateServer> duplicates = <PlannedDuplicateServer>[];
    final List<PlannedUnknownServer> unknown = <PlannedUnknownServer>[];
    final List<PlannedSkippedServer> skipped = <PlannedSkippedServer>[];

    // Seed "already present" from the live config, then grow it as entries are
    // accepted so a file that lists the same server twice adds it only once
    // (merge, never duplicate).
    final Set<BackupServerIdentity> seen = <BackupServerIdentity>{
      ...existingServers,
    };

    final Object? rawServers = inner['servers'];
    if (rawServers is List) {
      for (final Object? entry in rawServers) {
        _classifyServer(
          entry,
          seen: seen,
          toAdd: toAdd,
          duplicates: duplicates,
          unknown: unknown,
          skipped: skipped,
        );
      }
    }

    return BackupImportPlan(
      serversToAdd: toAdd,
      serversAlreadyConfigured: duplicates,
      unknownServers: unknown,
      skippedServers: skipped,
      preferences: _planPreferences(inner['preferences']),
      generatedBy: BackupGeneratedBy.fromJson(inner['generatedBy']),
      createdAt: _nonEmptyString(inner['createdAt']),
    );
  }

  /// Classifies one raw server [entry], appending it to exactly one of the
  /// outcome lists.
  void _classifyServer(
    Object? entry, {
    required Set<BackupServerIdentity> seen,
    required List<PlannedServerAddition> toAdd,
    required List<PlannedDuplicateServer> duplicates,
    required List<PlannedUnknownServer> unknown,
    required List<PlannedSkippedServer> skipped,
  }) {
    final Map<String, dynamic>? map = backupJsonObject(entry);
    if (map == null) {
      skipped.add(
        const PlannedSkippedServer(reason: BackupServerSkipReason.notAnObject),
      );
      return;
    }

    final String? type = _nonEmptyString(map['type']);
    if (type == null) {
      skipped.add(
        const PlannedSkippedServer(reason: BackupServerSkipReason.missingType),
      );
      return;
    }

    if (!isKnownBackupServerType(type)) {
      unknown.add(
        PlannedUnknownServer(
          typeName: type,
          displayName: _nonEmptyString(map['displayName']),
        ),
      );
      return;
    }

    final BackupServer? server = BackupServer.fromJson(map);
    if (server == null) {
      // A known type whose required field (baseUrl) was missing/blank.
      skipped.add(
        PlannedSkippedServer(
          reason: BackupServerSkipReason.missingRequiredField,
          typeName: type,
        ),
      );
      return;
    }

    final BackupServerIdentity identity =
        BackupServerIdentity.forServer(server);
    if (seen.contains(identity)) {
      duplicates.add(
        PlannedDuplicateServer(server: server, identity: identity),
      );
      return;
    }
    seen.add(identity);
    toAdd.add(PlannedServerAddition(server: server, identity: identity));
  }

  /// Builds the preferences portion of the plan: the clamped, ready-to-apply
  /// preferences, the list of numeric values that were clamped, and the unknown
  /// keys (including any secret-looking ones) that are ignored.
  BackupPreferencesPlan _planPreferences(Object? rawPreferences) {
    final BackupPreferences parsed = BackupPreferences.fromJson(rawPreferences);
    final BackupPreferences applied = clampBackupPreferences(parsed);

    final List<BackupPreferenceClamp> clamps = <BackupPreferenceClamp>[];
    final BackupCachePreferences? before = parsed.cache;
    final BackupCachePreferences? after = applied.cache;
    if (before != null && after != null) {
      _addClamp(
        clamps,
        field: 'cache.maxBytes',
        before: before.maxBytes,
        after: after.maxBytes,
      );
      _addClamp(
        clamps,
        field: 'cache.precacheCount',
        before: before.precacheCount,
        after: after.precacheCount,
      );
    }

    final Map<String, dynamic>? raw = backupJsonObject(rawPreferences);
    final List<String> ignored =
        raw == null ? const <String>[] : _ignoredPreferenceKeys(raw);

    return BackupPreferencesPlan(
      applied: applied,
      clamps: clamps,
      ignoredKeys: ignored,
    );
  }

  void _addClamp(
    List<BackupPreferenceClamp> clamps, {
    required String field,
    required int? before,
    required int? after,
  }) {
    if (before != null && after != null && before != after) {
      clamps.add(
        BackupPreferenceClamp(
          field: field,
          originalValue: before,
          clampedValue: after,
        ),
      );
    }
  }

  /// Collects every preference key the file carried that this build does not
  /// model — at the top level and within the structured `cache` / `playback` /
  /// `appearance` sub-objects (nested keys are prefixed, e.g. `cache.foo`). A
  /// secret-looking key (`password`, `token`, …) lands here, proving it was
  /// seen and dropped rather than applied.
  List<String> _ignoredPreferenceKeys(Map<String, dynamic> raw) {
    final List<String> ignored = <String>[];
    for (final String key in raw.keys) {
      if (!_knownPreferenceKeys.contains(key)) ignored.add(key);
    }
    ignored.addAll(_ignoredNestedKeys(raw['cache'], _knownCacheKeys, 'cache'));
    ignored.addAll(
      _ignoredNestedKeys(raw['playback'], _knownPlaybackKeys, 'playback'),
    );
    ignored.addAll(
      _ignoredNestedKeys(raw['appearance'], _knownAppearanceKeys, 'appearance'),
    );
    return ignored;
  }

  List<String> _ignoredNestedKeys(
    Object? value,
    Set<String> known,
    String prefix,
  ) {
    final Map<String, dynamic>? map = backupJsonObject(value);
    if (map == null) return const <String>[];
    final List<String> out = <String>[];
    for (final String key in map.keys) {
      if (!known.contains(key)) out.add('$prefix.$key');
    }
    return out;
  }

  /// Re-decodes [text] and returns the raw object under the `linthraBackup`
  /// envelope, or `null` if it isn't present/decodable.
  Map<String, dynamic>? _innerObjectOf(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return null;
    }
    final Map<String, dynamic>? root = backupJsonObject(decoded);
    if (root == null) return null;
    return backupJsonObject(root[kBackupEnvelopeKey]);
  }
}

/// Reads [value] as a non-empty `String`, or `null` otherwise.
String? _nonEmptyString(Object? value) =>
    (value is String && value.isNotEmpty) ? value : null;

/// The preference keys this build understands at each level of the document.
const Set<String> _knownPreferenceKeys = <String>{
  'defaultProvider',
  'preferredSourceOrder',
  'playbackSourceStrategy',
  'cache',
  'playback',
  'appearance',
};
const Set<String> _knownCacheKeys = <String>{
  'maxBytes',
  'allowMobileData',
  'smartPrecacheEnabled',
  'precacheCount',
};
const Set<String> _knownPlaybackKeys = <String>{'normalizeVolume'};
const Set<String> _knownAppearanceKeys = <String>{'appIconVariant'};
