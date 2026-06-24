import '../../core/models/jellyfin_session.dart';
import '../../core/models/plex_session.dart';
import '../../core/models/subsonic_session.dart';
import 'backup_models.dart';

/// Projects a live, secret-bearing session into the **non-secret** backup
/// server model — the single place the "settings, not secrets" rule is enforced
/// in code.
///
/// Why this exists as a separate, deliberate projection (and not a reuse of each
/// session's `toJson()`): a session's own `toJson()` *includes* its credential
/// on purpose — its only caller is the encrypted on-device store. Routing that
/// through a plaintext backup would leak the token. These mappers instead copy
/// out only the fields the format documents and **structurally cannot** carry a
/// secret, because [BackupServer] has no field for one. `backup_security_test.dart`
/// feeds these mappers sessions full of sentinel secrets and asserts none of
/// them — nor the device-/session-specific ids — ever reach the exported JSON,
/// so a future field added to a session can't silently start leaking.
///
/// This file is the only part of the backup feature that depends on the app's
/// session models; the format models and the reader stay pure so Desktop can
/// reuse them.

/// A human label for a source: the server's reported friendly name when it has
/// one, otherwise the URL host (and the raw URL only if it can't be parsed).
/// Mirrors how Linthra already labels a source today.
String _displayNameFor(String? serverName, String baseUrl) {
  if (serverName != null && serverName.isNotEmpty) return serverName;
  final String? host = Uri.tryParse(baseUrl)?.host;
  if (host != null && host.isNotEmpty) return host;
  return baseUrl;
}

/// Projects a [JellyfinSession] to its backup entry. Carries `baseUrl` and the
/// sign-in `username`; deliberately omits `accessToken`, `deviceId`, `userId`,
/// `serverId`, and version strings.
JellyfinBackupServer jellyfinBackupServerFromSession(JellyfinSession session) {
  return JellyfinBackupServer(
    displayName: _displayNameFor(session.serverName, session.baseUrl),
    baseUrl: session.baseUrl,
    username: session.userName,
  );
}

/// Projects a [SubsonicSession] to its backup entry. Carries `baseUrl`,
/// `username`, and the informational `serverType`; deliberately omits the
/// `salt`/`token` credential pair and version strings.
SubsonicBackupServer subsonicBackupServerFromSession(SubsonicSession session) {
  return SubsonicBackupServer(
    // Subsonic sessions carry no friendly server name, so the host is the label.
    displayName: _displayNameFor(null, session.baseUrl),
    baseUrl: session.baseUrl,
    username: session.username,
    serverType: session.serverType,
  );
}

/// Projects a [PlexSession] to its backup entry. Carries `baseUrl` and the
/// user's chosen `selectedSectionKeys`; deliberately omits the `X-Plex-Token`,
/// `machineIdentifier`, `clientIdentifier`, and version strings.
PlexBackupServer plexBackupServerFromSession(PlexSession session) {
  return PlexBackupServer(
    displayName: _displayNameFor(session.serverName, session.baseUrl),
    baseUrl: session.baseUrl,
    selectedSectionKeys: session.selectedSectionKeys,
  );
}

/// Builds the on-device folder entry from the saved folder URI. There is no
/// session (and no secret) for the local source; [folderHint] is the SAF tree
/// URI carried for the user's reference only.
LocalBackupServer localBackupServer({String? displayName, String? folderHint}) {
  return LocalBackupServer(displayName: displayName, folderHint: folderHint);
}
