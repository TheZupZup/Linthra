import 'dart:convert';

import '../../core/models/cache_size.dart';
import '../../core/repositories/download_preferences.dart';
import 'backup_models.dart';

/// Reading, version-gating, framing, and clamping for the Backup/Restore V1
/// format — the safety layer that sits on top of the pure models in
/// `backup_models.dart`.
///
/// Two jobs:
///
/// 1. **Read safely.** [readBackup] turns raw file text into a typed result that
///    distinguishes "not JSON", "not a Linthra backup", "made by a newer
///    Linthra" (a too-new `formatVersion`, rejected with a clear message — never
///    a silent half-import), and "malformed". Only a clean, supported document
///    yields a [LinthraBackup].
///
/// 2. **Clamp like the live settings.** A backup is just a file — it can be
///    hand-edited or written by a newer build — so every numeric preference is
///    clamped to *exactly* the same range the live setting enforces. These
///    helpers delegate to [CacheSize.clamp] and [sanitizePrecacheCount] so the
///    backup path can never drift from the app path: there is one definition of
///    "in range", reused.
///
/// All of this is pure Dart (no plugins, no I/O), so it runs the same on
/// Android, on Desktop, and in tests.

/// Whether this build can read a document declaring [formatVersion]. V1 accepts
/// `1`; a version below `1` is malformed and one above [kBackupFormatVersion] is
/// from a newer Linthra. Written as a range so a future build that bumps
/// [kBackupFormatVersion] keeps accepting older files unchanged.
bool isSupportedBackupFormatVersion(int formatVersion) =>
    formatVersion >= 1 && formatVersion <= kBackupFormatVersion;

/// Clamps a backed-up cache ceiling to the supported byte range, identically to
/// the live "Max cache size" setting.
int clampBackupCacheMaxBytes(int bytes) => CacheSize.clamp(bytes);

/// Clamps a backed-up pre-cache count to the supported range, identically to the
/// live "how many upcoming tracks" setting (junk → default, over-range →
/// capped).
int clampBackupPrecacheCount(int count) => sanitizePrecacheCount(count);

/// Returns a copy of [cache] with its numeric fields clamped to the live ranges
/// ([maxBytes] via [clampBackupCacheMaxBytes], [precacheCount] via
/// [clampBackupPrecacheCount]). Booleans and absent fields are left untouched.
BackupCachePreferences clampBackupCachePreferences(
  BackupCachePreferences cache,
) {
  final int? maxBytes = cache.maxBytes;
  final int? precacheCount = cache.precacheCount;
  return BackupCachePreferences(
    maxBytes: maxBytes == null ? null : clampBackupCacheMaxBytes(maxBytes),
    allowMobileData: cache.allowMobileData,
    smartPrecacheEnabled: cache.smartPrecacheEnabled,
    precacheCount:
        precacheCount == null ? null : clampBackupPrecacheCount(precacheCount),
  );
}

/// Returns a copy of [preferences] safe to apply: numeric cache fields clamped
/// to the live ranges, everything else preserved. The eventual restore importer
/// calls this before applying, so a hand-edited or newer file can never push a
/// setting out of bounds. Non-numeric choices that the app already resolves with
/// a fallback at read time (`playbackSourceStrategy` →
/// `PlaybackSourceStrategy.fromStorage`, `appIconVariant` →
/// `AppIconVariants.byId`) are left verbatim so that single source of truth
/// stays in charge.
BackupPreferences clampBackupPreferences(BackupPreferences preferences) {
  final BackupCachePreferences? cache = preferences.cache;
  return BackupPreferences(
    defaultProvider: preferences.defaultProvider,
    preferredSourceOrder: preferences.preferredSourceOrder,
    playbackSourceStrategy: preferences.playbackSourceStrategy,
    cache: cache == null ? null : clampBackupCachePreferences(cache),
    playback: preferences.playback,
    appearance: preferences.appearance,
  );
}

/// Frames [backup] as the full document map `{ "linthraBackup": { ... } }` ready
/// for `jsonEncode`. Pairs with [readBackupRoot], which unwraps the same key.
Map<String, dynamic> wrapBackupDocument(LinthraBackup backup) =>
    <String, dynamic>{kBackupEnvelopeKey: backup.toJson()};

/// Encodes [backup] as the pretty-printed UTF-8 JSON text of a backup file
/// (two-space indent), exactly the human-inspectable shape the format
/// documents.
String encodeBackup(LinthraBackup backup) =>
    const JsonEncoder.withIndent('  ').convert(wrapBackupDocument(backup));

/// Why a document could not be read as a usable backup.
enum BackupReadFailureReason {
  /// The text isn't valid JSON at all.
  notJson,

  /// Valid JSON, but it has no [kBackupEnvelopeKey] object — not a Linthra
  /// backup.
  notLinthraBackup,

  /// A Linthra backup, but its `formatVersion` is newer than this build
  /// supports. The user should update Linthra.
  unsupportedVersion,

  /// A Linthra backup whose envelope is structurally invalid (e.g. a missing or
  /// non-integer `formatVersion`).
  malformed,
}

/// The outcome of reading a backup document: either a parsed [LinthraBackup] or
/// a typed failure carrying a user-facing [message].
sealed class BackupReadResult {
  const BackupReadResult();
}

/// A successfully read backup. The contained [backup] is parsed but **not**
/// clamped — call [clampBackupPreferences] before applying its preferences.
class BackupReadSuccess extends BackupReadResult {
  const BackupReadSuccess(this.backup);

  final LinthraBackup backup;
}

/// A document that could not be read, with the [reason] and a clear, user-facing
/// [message] suitable to show on the (future) restore screen.
class BackupReadFailure extends BackupReadResult {
  const BackupReadFailure(this.reason, this.message);

  final BackupReadFailureReason reason;
  final String message;
}

/// Reads backup [text]: decodes the JSON, then validates the envelope via
/// [readBackupRoot]. Never throws — invalid JSON becomes a
/// [BackupReadFailureReason.notJson] failure.
BackupReadResult readBackup(String text) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return const BackupReadFailure(
      BackupReadFailureReason.notJson,
      'This file is not valid JSON, so it is not a Linthra backup.',
    );
  }
  final Map<String, dynamic>? root = backupJsonObject(decoded);
  if (root == null) {
    return const BackupReadFailure(
      BackupReadFailureReason.notLinthraBackup,
      'This file does not look like a Linthra backup.',
    );
  }
  return readBackupRoot(root);
}

/// Validates an already-decoded document [root] and, on success, builds the
/// [LinthraBackup]. Splitting this out lets a caller that already has a decoded
/// map (or a test) reuse the exact envelope/version checks.
///
/// Order matters: the [kBackupEnvelopeKey] marker is checked first (is this even
/// a backup?), then `formatVersion` (can we read it?), and only then is the body
/// parsed. A too-new version is reported as [BackupReadFailureReason.unsupportedVersion]
/// with a clear message rather than parsed partially.
BackupReadResult readBackupRoot(Map<String, dynamic> root) {
  final Map<String, dynamic>? inner =
      backupJsonObject(root[kBackupEnvelopeKey]);
  if (inner == null) {
    return const BackupReadFailure(
      BackupReadFailureReason.notLinthraBackup,
      'This file is missing the Linthra backup marker, so it cannot be '
      'restored.',
    );
  }

  final Object? rawVersion = inner['formatVersion'];
  if (rawVersion is! int) {
    return const BackupReadFailure(
      BackupReadFailureReason.malformed,
      'This backup is missing a valid format version and cannot be restored.',
    );
  }
  if (rawVersion < 1) {
    return BackupReadFailure(
      BackupReadFailureReason.malformed,
      'This backup reports an invalid format version ($rawVersion).',
    );
  }
  if (rawVersion > kBackupFormatVersion) {
    return BackupReadFailure(
      BackupReadFailureReason.unsupportedVersion,
      'This backup was made by a newer version of Linthra (backup format '
      'v$rawVersion). Update Linthra to restore it.',
    );
  }

  return BackupReadSuccess(LinthraBackup.fromJson(inner));
}
