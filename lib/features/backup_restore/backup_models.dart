/// Typed, pure-Dart models for the **Linthra Backup / Restore V1** file format
/// documented in `docs/backup-restore-format.md`.
///
/// This file is the in-memory shape of the JSON envelope. It is deliberately
/// free of any Android/UI, plugin, or app-state coupling so the *same* models
/// can be reused by Linthra Desktop (Phase 4) and by Linthra Connect (Phase 3,
/// an optional transport). Nothing here reads a session, a store, or a file;
/// projecting live app state into these models lives in
/// `backup_export_mapper.dart`, and version-gating/clamping/reading a document
/// lives in `backup_validation.dart`.
///
/// ## Safety by construction
///
/// V1 is **settings, not secrets** (see the spec → Security). These models have
/// **no field** for a Jellyfin `accessToken`, a Subsonic `salt`/`token`, a Plex
/// `X-Plex-Token`, any password, or the device-/session-specific ids
/// (`deviceId` / `userId` / `serverId` / `machineIdentifier` /
/// `clientIdentifier` / version strings). Because the field simply does not
/// exist, [toJson] can never emit one — and `backup_security_test.dart` asserts
/// exactly that against the real projection.
///
/// ## Forward-compatibility
///
/// Every [fromJson] here is *lenient*: it reads only the keys it knows, ignores
/// unknown object fields, tolerates a missing optional, and never throws on a
/// surprising value (it falls back instead). An unrecognised server `type` is
/// preserved as an [UnknownBackupServer] rather than crashing the parse, so a
/// newer file (or a Desktop-only server type) still restores everything else.
/// Rejecting a too-new `formatVersion` is the reader's job, not the model's.
library;

/// The JSON key that wraps the whole document and identifies the file as a
/// Linthra backup. A file is recognised by this marker (and [formatVersion]),
/// not by its name, so a renamed `*.json` still restores.
const String kBackupEnvelopeKey = 'linthraBackup';

/// The format version this build reads and writes. V1 = `1`. A backup whose
/// `formatVersion` is greater than this is rejected by the reader with a clear
/// message; within this major version, changes are additive only.
const int kBackupFormatVersion = 1;

/// The only `kind` V1 understands. Reserved so a future
/// `"settings+credentials"` or `"library"` document can be told apart without a
/// format-version bump.
const String kBackupKindSettings = 'settings';

/// Coerces [value] to a `Map<String, dynamic>` when it is a JSON object,
/// otherwise returns `null`. Shared by every model parser here and by the
/// `backup_validation.dart` reader so a non-object is treated identically
/// everywhere (skipped, never a crash). Handles both the `Map<String, dynamic>`
/// that `jsonDecode` produces and a differently-typed `Map` a hand-built test
/// or other source might pass.
Map<String, dynamic>? backupJsonObject(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map(
      (Object? key, Object? v) => MapEntry<String, dynamic>(key.toString(), v),
    );
  }
  return null;
}

/// Reads [value] as a list of strings, dropping any non-string element, or an
/// empty list when [value] is not a list. Keeps a hand-edited array from
/// crashing the parse.
List<String> _backupStringList(Object? value) {
  if (value is List) {
    return value.whereType<String>().toList(growable: false);
  }
  return const <String>[];
}

/// Reads [value] as an `int`, or `null` for anything else (so a missing key, a
/// string, or a float falls back to the setting's default at clamp time rather
/// than throwing). JSON integers decode to `int`, which is what a real backup
/// carries.
int? _backupInt(Object? value) => value is int ? value : null;

/// Reads [value] as a non-empty `String`, or `null` otherwise (empty and
/// missing are treated the same — "not present").
String? _backupString(Object? value) =>
    (value is String && value.isNotEmpty) ? value : null;

/// The full contents of a backup — everything under the [kBackupEnvelopeKey]
/// wrapper. [toJson] returns this inner object; framing it as
/// `{ "linthraBackup": { ... } }` and pretty-printing is
/// `backup_validation.dart`'s job, mirroring how a session's `toJson` returns
/// its own object and the store wraps it.
class LinthraBackup {
  const LinthraBackup({
    this.formatVersion = kBackupFormatVersion,
    this.kind = kBackupKindSettings,
    this.generatedBy,
    this.createdAt,
    this.servers = const <BackupServer>[],
    this.preferences = const BackupPreferences(),
  });

  /// Format version of this document. Written as [kBackupFormatVersion] on
  /// export; on import it is whatever the file declared (the reader has already
  /// rejected a value newer than [kBackupFormatVersion] before this is built).
  final int formatVersion;

  /// `"settings"` in V1. Carried verbatim so a future reader can branch on it.
  final String kind;

  /// Optional diagnostics about the writer. Readers must not depend on it.
  final BackupGeneratedBy? generatedBy;

  /// Optional ISO-8601 UTC timestamp the backup was written, kept as a string
  /// because it is display-only and the model should never choke on an odd
  /// date.
  final String? createdAt;

  /// The configured sources. May be empty. Unknown/unsupported types survive as
  /// [UnknownBackupServer] so the rest still imports.
  final List<BackupServer> servers;

  /// App / playback / cache / source preferences. Never null; an absent
  /// `preferences` object parses to an empty [BackupPreferences].
  final BackupPreferences preferences;

  /// Serializes the inner backup object in the documented key order. `servers`
  /// and `preferences` are always present (required, possibly empty);
  /// `generatedBy` and `createdAt` are omitted when absent.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'formatVersion': formatVersion,
        'kind': kind,
        if (generatedBy != null) 'generatedBy': generatedBy!.toJson(),
        if (createdAt != null) 'createdAt': createdAt,
        'servers': <Map<String, dynamic>>[
          for (final BackupServer server in servers) server.toJson(),
        ],
        'preferences': preferences.toJson(),
      };

  /// Rebuilds a backup from the inner object (the value under
  /// [kBackupEnvelopeKey]). Lenient by design: unknown fields are ignored, a
  /// missing/invalid `formatVersion` defaults to [kBackupFormatVersion] (the
  /// reader gates the real version first), malformed server entries are
  /// dropped, and an absent `preferences` becomes empty.
  static LinthraBackup fromJson(Map<String, dynamic> json) {
    final List<BackupServer> servers = <BackupServer>[];
    final Object? rawServers = json['servers'];
    if (rawServers is List) {
      for (final Object? entry in rawServers) {
        final Map<String, dynamic>? map = backupJsonObject(entry);
        if (map == null) continue;
        final BackupServer? server = BackupServer.fromJson(map);
        if (server != null) servers.add(server);
      }
    }
    return LinthraBackup(
      formatVersion: _backupInt(json['formatVersion']) ?? kBackupFormatVersion,
      kind: _backupString(json['kind']) ?? kBackupKindSettings,
      generatedBy: BackupGeneratedBy.fromJson(json['generatedBy']),
      createdAt: _backupString(json['createdAt']),
      servers: servers,
      preferences: BackupPreferences.fromJson(json['preferences']),
    );
  }
}

/// Diagnostics-only provenance of a backup. Both fields are optional and a
/// reader must not depend on them.
class BackupGeneratedBy {
  const BackupGeneratedBy({this.app, this.appVersion});

  /// e.g. `"Linthra Android"` / `"Linthra Desktop"`.
  final String? app;

  /// The writing app's version string, e.g. `"0.1.7"`.
  final String? appVersion;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (app != null) 'app': app,
        if (appVersion != null) 'appVersion': appVersion,
      };

  /// Parses [value] tolerantly, returning `null` when it is not an object or
  /// carries neither field — so an absent or junk `generatedBy` simply
  /// disappears rather than failing the import.
  static BackupGeneratedBy? fromJson(Object? value) {
    final Map<String, dynamic>? map = backupJsonObject(value);
    if (map == null) return null;
    final String? app = _backupString(map['app']);
    final String? appVersion = _backupString(map['appVersion']);
    if (app == null && appVersion == null) return null;
    return BackupGeneratedBy(app: app, appVersion: appVersion);
  }
}

/// One configured source, tagged by [type]. This is a sealed hierarchy so the
/// known types are exhaustive at compile time, while [UnknownBackupServer]
/// absorbs any `type` this build doesn't recognise — that's what keeps an older
/// reader (or Desktop) from crashing on a newer file's server type.
///
/// Per-type fields are **all non-secret** by construction; see the file header.
sealed class BackupServer {
  const BackupServer({this.displayName});

  /// The human label Linthra shows for this source. Non-secret; derived from the
  /// server's reported name (falling back to the URL host) at export time.
  final String? displayName;

  /// The stable type tag: `"jellyfin"`, `"subsonic"`, `"plex"`, `"local"`, or —
  /// for [UnknownBackupServer] — whatever unrecognised string the file carried.
  String get type;

  /// Serializes this entry, always leading with `type` so the document is
  /// self-describing and an older reader can skip what it doesn't know.
  Map<String, dynamic> toJson();

  /// Dispatches on `type`. Returns:
  /// - a typed server for a known type, or `null` if that entry is missing a
  ///   required field (a corrupt known entry, dropped on import);
  /// - an [UnknownBackupServer] for a non-empty unrecognised type (preserved so
  ///   restore can skip it *with a notice*, per the spec);
  /// - `null` for an entry with no usable `type` at all.
  static BackupServer? fromJson(Map<String, dynamic> json) {
    final String? type = _backupString(json['type']);
    switch (type) {
      case 'jellyfin':
        return JellyfinBackupServer.fromJson(json);
      case 'subsonic':
        return SubsonicBackupServer.fromJson(json);
      case 'plex':
        return PlexBackupServer.fromJson(json);
      case 'local':
        return LocalBackupServer.fromJson(json);
      case null:
        return null;
      default:
        return UnknownBackupServer(
          typeName: type,
          displayName: _backupString(json['displayName']),
          raw: Map<String, dynamic>.of(json),
        );
    }
  }
}

/// A Jellyfin source. Exports only the non-secret `baseUrl` and sign-in
/// `username`; the `accessToken`, `deviceId`, `userId`, `serverId`, and version
/// strings are never modelled here.
class JellyfinBackupServer extends BackupServer {
  const JellyfinBackupServer({
    super.displayName,
    required this.baseUrl,
    this.username,
  });

  /// Server base URL, no trailing slash (e.g. `https://music.example.com`).
  final String baseUrl;

  /// Sign-in name, to pre-fill the login form on restore.
  final String? username;

  @override
  String get type => 'jellyfin';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type,
        if (displayName != null) 'displayName': displayName,
        'baseUrl': baseUrl,
        if (username != null) 'username': username,
      };

  /// Returns `null` when `baseUrl` is missing/blank — a Jellyfin entry with no
  /// address can't be restored, so it is dropped rather than half-imported.
  static JellyfinBackupServer? fromJson(Map<String, dynamic> json) {
    final String? baseUrl = _backupString(json['baseUrl']);
    if (baseUrl == null) return null;
    return JellyfinBackupServer(
      displayName: _backupString(json['displayName']),
      baseUrl: baseUrl,
      username: _backupString(json['username']),
    );
  }
}

/// A Subsonic / Navidrome (and other OpenSubsonic) source. Exports `baseUrl`,
/// `username`, and the informational `serverType`; the `salt`/`token`
/// credential pair and version strings are never modelled here.
class SubsonicBackupServer extends BackupServer {
  const SubsonicBackupServer({
    super.displayName,
    required this.baseUrl,
    this.username,
    this.serverType,
  });

  /// Server base URL, no trailing slash.
  final String baseUrl;

  /// Sign-in name, to pre-fill the login form on restore.
  final String? username;

  /// OpenSubsonic server product (e.g. `navidrome`), if known. Informational.
  final String? serverType;

  @override
  String get type => 'subsonic';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type,
        if (displayName != null) 'displayName': displayName,
        'baseUrl': baseUrl,
        if (username != null) 'username': username,
        if (serverType != null) 'serverType': serverType,
      };

  /// Returns `null` when `baseUrl` is missing/blank (see
  /// [JellyfinBackupServer.fromJson]).
  static SubsonicBackupServer? fromJson(Map<String, dynamic> json) {
    final String? baseUrl = _backupString(json['baseUrl']);
    if (baseUrl == null) return null;
    return SubsonicBackupServer(
      displayName: _backupString(json['displayName']),
      baseUrl: baseUrl,
      username: _backupString(json['username']),
      serverType: _backupString(json['serverType']),
    );
  }
}

/// A Plex source. Exports `baseUrl` and the user's chosen music-library
/// `selectedSectionKeys` (a genuine choice worth restoring); the
/// `X-Plex-Token`, `machineIdentifier`, `clientIdentifier`, and version strings
/// are never modelled here. Plex has no username in a session, so none is
/// exported.
class PlexBackupServer extends BackupServer {
  const PlexBackupServer({
    super.displayName,
    required this.baseUrl,
    this.selectedSectionKeys = const <String>[],
  });

  /// Server base URL incl. port (e.g. `https://plex.example.com:32400`).
  final String baseUrl;

  /// The music-library section keys the user chose to include.
  final List<String> selectedSectionKeys;

  @override
  String get type => 'plex';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type,
        if (displayName != null) 'displayName': displayName,
        'baseUrl': baseUrl,
        if (selectedSectionKeys.isNotEmpty)
          'selectedSectionKeys': selectedSectionKeys,
      };

  /// Returns `null` when `baseUrl` is missing/blank (see
  /// [JellyfinBackupServer.fromJson]).
  static PlexBackupServer? fromJson(Map<String, dynamic> json) {
    final String? baseUrl = _backupString(json['baseUrl']);
    if (baseUrl == null) return null;
    return PlexBackupServer(
      displayName: _backupString(json['displayName']),
      baseUrl: baseUrl,
      selectedSectionKeys: _backupStringList(json['selectedSectionKeys']),
    );
  }
}

/// An on-device folder source. [folderHint] is the previously chosen Android SAF
/// tree URI, **informational only**: a SAF grant is per-device and cannot
/// transfer, so on restore Linthra shows it as a hint and asks the user to
/// re-pick the folder. Desktop ignores it.
class LocalBackupServer extends BackupServer {
  const LocalBackupServer({super.displayName, this.folderHint});

  /// The SAF tree URI of the previously chosen folder, for the user's
  /// reference. Not a credential and grants no access.
  final String? folderHint;

  @override
  String get type => 'local';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type,
        if (displayName != null) 'displayName': displayName,
        if (folderHint != null) 'folderHint': folderHint,
      };

  static LocalBackupServer fromJson(Map<String, dynamic> json) {
    return LocalBackupServer(
      displayName: _backupString(json['displayName']),
      folderHint: _backupString(json['folderHint']),
    );
  }
}

/// A server entry whose `type` this build does not recognise — a future
/// provider, or a platform-specific type (e.g. `local` on Desktop). It is kept
/// (not dropped) so the importer can skip it *with a notice*. The original
/// object is preserved in [raw] so nothing is silently lost and the entry can
/// round-trip unchanged.
class UnknownBackupServer extends BackupServer {
  const UnknownBackupServer({
    required this.typeName,
    super.displayName,
    this.raw = const <String, dynamic>{},
  });

  /// The unrecognised `type` string from the file.
  final String typeName;

  /// The entry exactly as it appeared, so re-serializing loses nothing.
  final Map<String, dynamic> raw;

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => raw.isNotEmpty
      ? Map<String, dynamic>.of(raw)
      : <String, dynamic>{
          'type': typeName,
          if (displayName != null) 'displayName': displayName,
        };
}

/// Non-secret user preferences read from `shared_preferences`. Every field is
/// optional: a backup carries only the keys the user actually has, and a reader
/// applies only the keys present (clamping/validating each — see
/// `backup_validation.dart`).
class BackupPreferences {
  const BackupPreferences({
    this.defaultProvider,
    this.preferredSourceOrder = const <String>[],
    this.playbackSourceStrategy,
    this.cache,
    this.playback,
    this.appearance,
  });

  /// Explicit default source id (`jellyfin` / `subsonic` / `plex` / `local`),
  /// or `null` for Automatic.
  final String? defaultProvider;

  /// Source ids, most-preferred first. May be empty.
  final List<String> preferredSourceOrder;

  /// Playback-source strategy enum name (e.g. `preferLocalCache`), or `null`
  /// for the default.
  final String? playbackSourceStrategy;

  /// Offline-cache preferences, or `null` when none are set.
  final BackupCachePreferences? cache;

  /// Playback preferences, or `null` when none are set.
  final BackupPlaybackPreferences? playback;

  /// Appearance preferences, or `null` when none are set.
  final BackupAppearancePreferences? appearance;

  /// Serializes only the keys that are set, producing `{}` when nothing is —
  /// exactly the "apply only the keys present" contract, in reverse.
  Map<String, dynamic> toJson() {
    final Map<String, dynamic>? cacheJson = cache?.toJson();
    final Map<String, dynamic>? playbackJson = playback?.toJson();
    final Map<String, dynamic>? appearanceJson = appearance?.toJson();
    return <String, dynamic>{
      if (defaultProvider != null) 'defaultProvider': defaultProvider,
      if (preferredSourceOrder.isNotEmpty)
        'preferredSourceOrder': preferredSourceOrder,
      if (playbackSourceStrategy != null)
        'playbackSourceStrategy': playbackSourceStrategy,
      if (cacheJson != null && cacheJson.isNotEmpty) 'cache': cacheJson,
      if (playbackJson != null && playbackJson.isNotEmpty)
        'playback': playbackJson,
      if (appearanceJson != null && appearanceJson.isNotEmpty)
        'appearance': appearanceJson,
    };
  }

  /// Parses [value] tolerantly: a non-object (or absent) `preferences` becomes
  /// an empty instance, unknown keys are ignored, and each sub-object is itself
  /// parsed leniently.
  static BackupPreferences fromJson(Object? value) {
    final Map<String, dynamic>? map = backupJsonObject(value);
    if (map == null) return const BackupPreferences();
    return BackupPreferences(
      defaultProvider: _backupString(map['defaultProvider']),
      preferredSourceOrder: _backupStringList(map['preferredSourceOrder']),
      playbackSourceStrategy: _backupString(map['playbackSourceStrategy']),
      cache: BackupCachePreferences.fromJson(map['cache']),
      playback: BackupPlaybackPreferences.fromJson(map['playback']),
      appearance: BackupAppearancePreferences.fromJson(map['appearance']),
    );
  }
}

/// Offline-cache preferences. The numeric fields are stored verbatim here and
/// clamped to the live ranges by `backup_validation.dart` on restore — never
/// pushed out of bounds by a hand-edited or newer file.
class BackupCachePreferences {
  const BackupCachePreferences({
    this.maxBytes,
    this.allowMobileData,
    this.smartPrecacheEnabled,
    this.precacheCount,
  });

  /// Offline-cache size ceiling, in bytes (LRU eviction above it).
  final int? maxBytes;

  /// Whether downloads / pre-cache may use metered data.
  final bool? allowMobileData;

  /// Whether upcoming queued tracks are warmed into the cache.
  final bool? smartPrecacheEnabled;

  /// How many upcoming tracks smart pre-cache warms ahead.
  final int? precacheCount;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (maxBytes != null) 'maxBytes': maxBytes,
        if (allowMobileData != null) 'allowMobileData': allowMobileData,
        if (smartPrecacheEnabled != null)
          'smartPrecacheEnabled': smartPrecacheEnabled,
        if (precacheCount != null) 'precacheCount': precacheCount,
      };

  /// Returns `null` when [value] is not an object or carries none of the known
  /// keys, so an empty/absent `cache` simply doesn't appear.
  static BackupCachePreferences? fromJson(Object? value) {
    final Map<String, dynamic>? map = backupJsonObject(value);
    if (map == null) return null;
    final int? maxBytes = _backupInt(map['maxBytes']);
    final bool? allowMobileData =
        map['allowMobileData'] is bool ? map['allowMobileData'] as bool : null;
    final bool? smartPrecacheEnabled = map['smartPrecacheEnabled'] is bool
        ? map['smartPrecacheEnabled'] as bool
        : null;
    final int? precacheCount = _backupInt(map['precacheCount']);
    if (maxBytes == null &&
        allowMobileData == null &&
        smartPrecacheEnabled == null &&
        precacheCount == null) {
      return null;
    }
    return BackupCachePreferences(
      maxBytes: maxBytes,
      allowMobileData: allowMobileData,
      smartPrecacheEnabled: smartPrecacheEnabled,
      precacheCount: precacheCount,
    );
  }
}

/// Playback preferences.
class BackupPlaybackPreferences {
  const BackupPlaybackPreferences({this.normalizeVolume});

  /// Apply ReplayGain (attenuation-only) for even loudness.
  final bool? normalizeVolume;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (normalizeVolume != null) 'normalizeVolume': normalizeVolume,
      };

  /// Returns `null` when [value] is not an object or carries no known key.
  static BackupPlaybackPreferences? fromJson(Object? value) {
    final Map<String, dynamic>? map = backupJsonObject(value);
    if (map == null) return null;
    final bool? normalizeVolume =
        map['normalizeVolume'] is bool ? map['normalizeVolume'] as bool : null;
    if (normalizeVolume == null) return null;
    return BackupPlaybackPreferences(normalizeVolume: normalizeVolume);
  }
}

/// Appearance preferences. Cosmetic only.
class BackupAppearancePreferences {
  const BackupAppearancePreferences({this.appIconVariant});

  /// Chosen Linthra logo/branding variant id; cosmetic.
  final String? appIconVariant;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (appIconVariant != null) 'appIconVariant': appIconVariant,
      };

  /// Returns `null` when [value] is not an object or carries no known key.
  static BackupAppearancePreferences? fromJson(Object? value) {
    final Map<String, dynamic>? map = backupJsonObject(value);
    if (map == null) return null;
    final String? appIconVariant = _backupString(map['appIconVariant']);
    if (appIconVariant == null) return null;
    return BackupAppearancePreferences(appIconVariant: appIconVariant);
  }
}
