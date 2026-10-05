import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/platform/host_platform.dart';
import '../core/services/method_channel_linux_file_saver.dart';
import '../core/services/text_file_saver.dart';
import '../data/repositories/host_platform_provider.dart';

/// Where "Save report file" and "Save diagnostics" put their file. One shared
/// provider, like `externalLinkLauncherProvider`, so both go through the same
/// seam and a test override covers them all.
///
/// On Linux the listener picks the place in the desktop's save dialog (the
/// portal's, inside the Flatpak) (#748). Elsewhere it is written into the
/// app's documents directory, as before.
final textFileSaverProvider = Provider<TextFileSaver>((ref) {
  return ref.watch(hostPlatformProvider) == HostPlatform.linux
      ? const MethodChannelLinuxFileSaver()
      : const DocumentsDirectoryTextFileSaver();
});
