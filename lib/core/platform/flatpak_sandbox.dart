import 'dart:io' show Platform;

/// Whether this process is running inside a Flatpak sandbox.
///
/// The environment variable Flatpak documents for exactly this, and sets for
/// every application it starts. It is read rather than probed because the
/// question is "how was this build packaged", not "what can this process
/// reach": a sandbox that answers by failing every call would make Linthra
/// report a fixable error for something the user cannot fix.
///
/// Optical media is the feature that asks. UDisks2 lives on the system bus and
/// `docs/flatpak-permissions.md` refuses system-bus access outright, and
/// reading a disc's table of contents needs the drive's device node, which the
/// sandbox does not expose either. Both halves of #631 therefore report
/// "unsupported" up front inside the Flatpak instead of opening something that
/// is certain to be refused. See `docs/optical-media.md`.
bool get isFlatpakSandbox =>
    (Platform.environment['FLATPAK_ID'] ?? '').trim().isNotEmpty;
