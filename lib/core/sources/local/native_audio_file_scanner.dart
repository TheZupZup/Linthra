import '../../native/api/scan.dart';
import '../../native/linthra_bridge.dart';
import 'audio_file_scanner.dart';
import 'directory_readability.dart';
import 'local_root_fault.dart';

/// Walks a music folder in the Rust core
/// (native/linthra_core/src/scan/walk.rs), with the same rules as
/// [IoAudioFileScanner]: an unreadable subfolder is skipped and reported, the
/// folder itself failing or going away mid-walk throws the same
/// `FolderScanException`, and storage that stops answering for
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
    if (failure != null) {
      final LocalRootFault fault = failure.stalled
          ? LocalRootFault.unavailable
          : classifyErrno(failure.errno);
      throw failure.interrupted
          ? interruptedScanException(folder, fault)
          : rootFaultException(folder, fault);
    }
    // The walk already finished; its findings are handed on in the order the
    // walk met them, as the Dart walk reports them while it runs.
    walk.unreadable.forEach(onUnreadableDirectory ?? (_) {});
    walk.unopenable.forEach(onUnopenableName ?? (_) {});
    return walk.paths;
  }
}
