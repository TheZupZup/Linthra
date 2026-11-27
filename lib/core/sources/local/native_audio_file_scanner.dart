import 'package:flutter/foundation.dart';

import '../../native/api/scan.dart';
import '../../native/linthra_bridge.dart';
import 'audio_file_scanner.dart';
import 'directory_readability.dart';
import 'folder_scan_exception.dart';
import 'local_root_fault.dart';

/// Walks a music folder in the Rust core
/// (native/linthra_core/src/scan/walk.rs, where the rules are explained): an
/// unreadable subfolder is skipped and reported, a name that isn't valid
/// UTF-8 is reported instead of indexed, and the folder itself failing or
/// going away mid-walk throws a [FolderScanException] rather than answering
/// with an empty or partial list. Storage that stops answering for
/// [storageStallLimit] counts as unavailable.
class NativeAudioFileScanner implements AudioFileScanner {
  const NativeAudioFileScanner({Duration stallLimit = storageStallLimit})
      : _stallLimit = stallLimit;

  final Duration _stallLimit;

  @override
  Future<List<String>> listFiles(
    String folder, {
    void Function(String directory)? onUnreadableDirectory,
    void Function(String path)? onUnopenableName,
  }) async {
    await LinthraBridgeLoader.ensureReady();
    final FolderWalk walk = await walkFolder(
      folder: folder,
      stallLimitMs: _stallLimit.inMilliseconds,
    );
    final WalkFault? failure = walk.failure;
    if (failure != null) throw walkFailureException(folder, failure);
    // The walk already finished; its findings are handed on in the order the
    // walk met them.
    walk.unreadable.forEach(onUnreadableDirectory ?? (_) {});
    walk.unopenable.forEach(onUnopenableName ?? (_) {});
    return walk.paths;
  }
}

/// What the user is told about a walk of [folder] that failed with
/// [failure]: the folder's fault classified from its errno (or unavailable
/// when it stopped answering), worded for a folder that couldn't be opened
/// or for one that went away while it was being scanned.
@visibleForTesting
FolderScanException walkFailureException(String folder, WalkFault failure) {
  final LocalRootFault fault = failure.stalled
      ? LocalRootFault.unavailable
      : classifyErrno(failure.errno);
  return failure.interrupted
      ? interruptedScanException(folder, fault)
      : rootFaultException(folder, fault);
}
