import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/external_link_launcher.dart';

/// The browser seam the app launches external pages through — the "Report a
/// bug" flow's prefilled GitHub issue and the Plex "Connect with Plex"
/// sign-in page. One shared provider (declared here at the app level, like
/// `notificationPermissionProvider`) so every feature opens the browser
/// through the same seam and a test override covers them all.
///
/// Production wires the `url_launcher`-backed launcher; tests override it
/// with a fake so no real browser is opened. Every launch is an explicit
/// user action; nothing opens on its own.
final externalLinkLauncherProvider = Provider<ExternalLinkLauncher>(
  (ref) => const UrlLauncherExternalLinkLauncher(),
);
