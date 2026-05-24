import 'package:flutter/foundation.dart';

/// Byte progress for a single in-flight download.
///
/// [totalBytes] is `null` when the server didn't report a content length, in
/// which case progress is indeterminate ([fraction]/[percent] are `null`) and
/// the UI shows a spinner rather than a filling bar.
///
/// Security note: this carries only the non-secret track id and byte counts —
/// never a URL, token, or file path — so it is safe to surface in the UI.
@immutable
class DownloadProgress {
  const DownloadProgress({
    required this.trackId,
    required this.receivedBytes,
    this.totalBytes,
  });

  final String trackId;
  final int receivedBytes;
  final int? totalBytes;

  /// Completion in the range 0.0–1.0 when the total is known, else `null`.
  double? get fraction {
    final int? total = totalBytes;
    if (total == null || total <= 0) return null;
    return (receivedBytes / total).clamp(0.0, 1.0);
  }

  /// Completion as a whole percent (0–100) when the total is known, else
  /// `null`.
  int? get percent {
    final double? value = fraction;
    return value == null ? null : (value * 100).round();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DownloadProgress &&
          other.trackId == trackId &&
          other.receivedBytes == receivedBytes &&
          other.totalBytes == totalBytes);

  @override
  int get hashCode => Object.hash(trackId, receivedBytes, totalBytes);
}
