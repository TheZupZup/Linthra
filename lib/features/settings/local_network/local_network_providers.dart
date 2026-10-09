import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../core/lifecycle/app_visibility.dart';
import '../../../core/services/local_network/local_network_access.dart';
import '../../../core/services/local_network/local_network_address.dart';
import '../../../core/services/local_network/local_network_permission.dart';
import '../../../data/repositories/host_platform_provider.dart';
import '../audiobookshelf/audiobookshelf_settings_controller.dart';
import '../jellyfin/jellyfin_settings_controller.dart';
import '../plex/plex_settings_controller.dart';
import '../subsonic/subsonic_settings_controller.dart';

/// Android 17's local network permission on Android; a no-op that always
/// answers "not required" everywhere else.
final localNetworkPermissionProvider = Provider<LocalNetworkPermission>((ref) {
  return ref.watch(hostPlatformProvider).isAndroid
      ? const MethodChannelLocalNetworkPermission()
      : const UnsupportedLocalNetworkPermission();
});

/// Counts the times the user granted local network access in this session.
/// Whatever was held back while it was missing (the Jellyfin availability
/// probe, the Connections card) listens to this and tries again.
class LocalNetworkGrants extends Notifier<int> {
  @override
  int build() => 0;

  void granted() => state++;
}

final localNetworkGrantsProvider =
    NotifierProvider<LocalNetworkGrants, int>(LocalNetworkGrants.new);

/// The one gate every server connection goes through. See [LocalNetworkAccess]
/// for when it asks and when it only reports.
final localNetworkAccessProvider = Provider<LocalNetworkAccess>((ref) {
  final LocalNetworkAccess access = LocalNetworkAccess(
    permission: ref.watch(localNetworkPermissionProvider),
    isAppVisible: () => ref.read(appVisibilityProvider),
    onGranted: () => ref.read(localNetworkGrantsProvider.notifier).granted(),
  );
  ref.listen<bool>(appVisibilityProvider, (bool? previous, bool visible) {
    if (visible && previous == false) access.onAppShown();
  });
  return access;
});

/// The [http.Client] a server client (Jellyfin, Navidrome/Subsonic, Plex,
/// Audiobookshelf) talks through: a plain client behind the local network
/// gate, so a request Android 17 would block fails at once with the reason
/// instead of timing out. It never prompts; the prompts belong to the user's
/// own actions.
http.Client guardedServerHttpClient(Ref ref) => LocalNetworkGuardedClient(
    http.Client(), ref.watch(localNetworkAccessProvider));

/// For a connection the user just asked for (Test connection, Sign in,
/// Connect): asks for local network access when [rawUrl] is on the local
/// network and Android can still show the dialog, then throws
/// [LocalNetworkBlockedException] if access stays off. Returns quietly for an
/// internet server, an address that doesn't resolve, or a device where the
/// permission doesn't apply.
Future<void> requireLocalNetworkFor(Ref ref, String rawUrl) async {
  final Uri? server = serverUriForLocalNetworkCheck(rawUrl);
  if (server == null) return;
  final LocalNetworkPermissionStatus? blocker = await ref
      .read(localNetworkAccessProvider)
      .blockerFor(server, prompt: LocalNetworkPrompt.userAction);
  if (blocker != null) throw LocalNetworkBlockedException(blocker);
}

/// [rawUrl] as typed into a server field, read leniently enough to find its
/// host even when it was typed as a bare address and port, with no scheme yet.
/// `null` when there's no host.
Uri? serverUriForLocalNetworkCheck(String rawUrl) {
  final String trimmed = rawUrl.trim();
  if (trimmed.isEmpty) return null;
  final Uri? uri =
      Uri.tryParse(trimmed.contains('://') ? trimmed : 'http://$trimmed');
  if (uri == null || uri.host.isEmpty) return null;
  return uri;
}

/// Whether the Connections screen should offer local network access: the
/// permission is enforced and not granted, and at least one configured server
/// resolves to a local address. `null` when there is nothing to offer.
///
/// Auto-disposed, so leaving and reopening Connections asks Android again.
final localNetworkAccessNeededProvider =
    FutureProvider.autoDispose<LocalNetworkPermissionStatus?>((ref) async {
  ref.watch(localNetworkGrantsProvider);
  final LocalNetworkAccess access = ref.watch(localNetworkAccessProvider);
  // Every watch before the first await, so a sign-in or sign-out reruns this.
  final List<String?> servers = <String?>[
    ref.watch(jellyfinSettingsControllerProvider
        .select((s) => s.isConnected ? s.baseUrl : null)),
    ref.watch(subsonicSettingsControllerProvider
        .select((s) => s.isConnected ? s.baseUrl : null)),
    ref.watch(plexSettingsControllerProvider
        .select((s) => s.isConnected ? s.baseUrl : null)),
    ref.watch(audiobookshelfSettingsControllerProvider
        .select((s) => s.isConnected ? s.baseUrl : null)),
  ];
  final LocalNetworkPermissionStatus status = await access.status();
  if (status.allowsLocalNetwork ||
      status == LocalNetworkPermissionStatus.unknown) {
    return null;
  }
  for (final String? url in servers) {
    final String? host = url == null ? null : Uri.tryParse(url)?.host;
    if (host == null || host.isEmpty) continue;
    if (await access.localityOf(host) == HostLocality.local) return status;
  }
  return null;
});
