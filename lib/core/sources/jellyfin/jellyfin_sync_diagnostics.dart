import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../../diagnostics/safe_event_log.dart';
import 'jellyfin_api.dart';

/// Debug-only, secret-free breadcrumbs for Jellyfin library sync.
///
/// Surfaces *why* a sync skipped, retried, or paged the way it did — counts and
/// fixed labels only — so a partial or slow sync is diagnosable from a debug log
/// and the "Report a bug" event trail, without anyone re-running it. It mirrors
/// the plugin-free, static style of [LocalScanDiagnostics] /
/// `PlaybackDiagnostics`.
///
/// Secret-free by construction: there is no parameter for a token, password,
/// authenticated URL, server address, or item title — only the item *kind*
/// (an enum name) and structural counts. So nothing sensitive can be recorded,
/// in a debug log or the release-visible [SafeEventLog].
abstract final class JellyfinSyncDiagnostics {
  /// The developer-log channel these breadcrumbs go to (debug builds only).
  static const String name = 'linthra.jellyfin.sync';

  /// Records that a listing dropped [skipped] unparseable entries (keeping
  /// [kept]) for one [kind]. Silent when nothing was skipped, so a clean sync
  /// leaves no noise.
  static void skipped({
    required JellyfinItemKind kind,
    required int skipped,
    required int kept,
  }) {
    if (skipped <= 0) return;
    final String detail = 'skip:${kind.name} dropped=$skipped kept=$kept';
    SafeEventLog.instance.record('jellyfin-sync', detail);
    if (kDebugMode) {
      developer.log(detail, name: name);
    }
  }

  /// Records that a paged read retried after a transient failure on [kind]
  /// (attempt [attempt] of [maxAttempts]). A debug-only signal — it is not
  /// mirrored into the release event log, to keep that trail to outcomes rather
  /// than every transient blip.
  static void retry({
    required JellyfinItemKind kind,
    required int attempt,
    required int maxAttempts,
  }) {
    if (!kDebugMode) return;
    developer.log(
      'retry:${kind.name} attempt=$attempt/$maxAttempts',
      name: name,
    );
  }

  /// Records a classified sync failure for diagnostics: the failure [category]
  /// (the error-kind name), the HTTP [statusCode] when one is known, the
  /// [action] being synced (e.g. `library`), and whether the follow-up
  /// reachability/auth probe found the server [reachable] and the session
  /// [authOk] (`null` when not probed). This is exactly the breakdown needed to
  /// tell "server unreachable" from "connected but sync failed" from "sign in
  /// again" in a bug report — and is secret-free: category/action are fixed
  /// labels, the status is a number, the probe results are booleans. No URL,
  /// token, title, or raw error rides along.
  static void failure({
    required String category,
    required String action,
    int? statusCode,
    bool? reachable,
    bool? authOk,
  }) {
    String tri(bool? v) => v == null ? 'unknown' : (v ? 'yes' : 'no');
    final String detail = 'fail:$action category=$category '
        'status=${statusCode ?? '-'} '
        'reachable=${tri(reachable)} auth=${tri(authOk)}';
    SafeEventLog.instance.record('jellyfin-sync', detail);
    if (kDebugMode) {
      developer.log(detail, name: name);
    }
  }

  /// Records that paging [kind] hit the safety page cap and stopped early after
  /// [pages] pages — a backstop that only fires for a server that ignores
  /// `StartIndex` (a real one always advances or reports a total). Mirrored to
  /// the event log because it means the listing was *truncated*, which the
  /// "No silent caps" rule says must be visible rather than read as complete.
  static void capped({required JellyfinItemKind kind, required int pages}) {
    final String detail = 'cap:${kind.name} pages=$pages';
    SafeEventLog.instance.record('jellyfin-sync', detail);
    if (kDebugMode) {
      developer.log(detail, name: name);
    }
  }
}
