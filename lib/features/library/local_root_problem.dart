import 'package:flutter/material.dart';

import '../../core/sources/local/folder_location.dart';
import '../../core/sources/local/local_root_fault.dart';

/// What the app says about one configured local folder that is not readable
/// right now: a glyph, a short title, what happened, and what to do about it.
///
/// This is the one place a [LocalRootFault] becomes something a person can
/// read, so the Settings card and the Library screen cannot drift into
/// describing the same broken folder two different ways. It is the same job
/// `sourceStatusPresentation` does for servers in the sidebar.
///
/// **Nothing raw reaches here.** The only inputs are a fault kind and the kind
/// of selection; there is no field an `errno`, an OS message, a device name or
/// even the folder path could travel in. The path is rendered separately by the
/// row that already shows it, from the user's own selection, so a failure can
/// never smuggle a different one in.
@immutable
class LocalRootProblemPresentation {
  const LocalRootProblemPresentation({
    required this.icon,
    required this.title,
    required this.explanation,
    required this.guidance,
    required this.canReselect,
  });

  /// The status glyph for this kind of problem.
  final IconData icon;

  /// A few words for the state: "Folder not found", "Permission denied".
  final String title;

  /// What happened, in one sentence, plus the promise that matters most: the
  /// music this folder contributed is still in the library.
  final String explanation;

  /// What the user can do about it, matched to the actions on offer.
  final String guidance;

  /// Whether picking a folder again is a fix for this. False for Android's
  /// device-wide library, which is not a folder and has no chooser: sending
  /// that user to a folder picker would be answering a different question.
  final bool canReselect;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalRootProblemPresentation &&
          other.icon == icon &&
          other.title == title &&
          other.explanation == explanation &&
          other.guidance == guidance &&
          other.canReselect == canReselect);

  @override
  int get hashCode =>
      Object.hash(icon, title, explanation, guidance, canReselect);

  @override
  String toString() => 'LocalRootProblemPresentation($title)';
}

/// How [fault] should read for a folder selected as [location].
///
/// Pure and total: no clock, no filesystem, no provider lookup. Whatever
/// produced the fault (a real probe, a failed scan, a test), the words are the
/// same, which is what lets a widget test cover states a real machine is
/// awkward to hold in.
LocalRootProblemPresentation localRootProblemPresentation(
  LocalRootFault fault, {
  required FolderLocation location,
}) {
  // Android's device-wide library is not a folder: it cannot be missing, it
  // cannot be unplugged and it cannot be reselected. Answered first so no
  // filesystem wording can reach it.
  if (location.isAndroidMediaStore) {
    // Only a withdrawn permission sends anyone to Android settings. MediaStore
    // can fail for its own reasons (a null cursor, a platform channel that did
    // not answer), and the scan already calls those something other than a
    // permission problem. Telling that user their music access is off would be
    // both wrong and contradicted by the scan summary two lines away.
    if (fault == LocalRootFault.permissionDenied) {
      return const LocalRootProblemPresentation(
        icon: Icons.lock_outline,
        title: 'Device music access is off',
        explanation: "Linthra can no longer read this device's music library. "
            'The music it already indexed stays in your library.',
        guidance: 'Re-enable music access in Android settings, then retry. You '
            'can use a folder instead at any time.',
        canReselect: false,
      );
    }
    return const LocalRootProblemPresentation(
      icon: Icons.error_outline,
      title: "Device music can't be read",
      explanation: "Linthra couldn't read this device's music library, and "
          "Android didn't say why. The music it already indexed stays in your "
          'library.',
      guidance: 'Retry. You can select a folder instead at any time.',
      canReselect: false,
    );
  }

  // A SAF tree is a grant rather than a path, so access being refused means the
  // grant went rather than the folder, and the way back is the chooser.
  //
  // Only when access was actually refused, though. A `content://` tree can also
  // fail because the provider behind it cannot be walked at all (a cloud or
  // document provider), and that arrives undiagnosed: the grant is fine, and
  // picking the same provider again would change nothing. Those fall through to
  // the honest wording below.
  if (location.isContentUri && fault == LocalRootFault.permissionDenied) {
    return const LocalRootProblemPresentation(
      icon: Icons.lock_outline,
      title: 'Folder access was revoked',
      explanation: "Linthra no longer has permission to read this folder. Its "
          'music stays in your library.',
      guidance: 'Select the folder again with the system folder chooser to '
          'restore access.',
      canReselect: true,
    );
  }

  switch (fault) {
    case LocalRootFault.missing:
      return const LocalRootProblemPresentation(
        icon: Icons.folder_off_outlined,
        title: 'Folder not found',
        explanation: "Linthra can't find this folder any more. The drive may "
            'be disconnected, or the folder may have been moved, renamed or '
            'deleted. Its music stays in your library either way.',
        guidance: 'Reconnect the drive and retry, or select the folder again '
            'if the music moved.',
        canReselect: true,
      );
    case LocalRootFault.permissionDenied:
      return const LocalRootProblemPresentation(
        icon: Icons.lock_outline,
        title: 'Permission denied',
        explanation: "This folder is still there, but Linthra isn't allowed to "
            'read it. Its permissions may have changed, or the access Linthra '
            'was given was withdrawn. Its music stays in your library.',
        guidance: "Check the folder's permissions and retry, or select the "
            'folder again to grant access.',
        canReselect: true,
      );
    case LocalRootFault.unavailable:
      return const LocalRootProblemPresentation(
        icon: Icons.link_off,
        title: "Storage isn't responding",
        explanation: "The drive or network share this folder lives on isn't "
            'responding right now. Nothing about your setup changed, and its '
            'music stays in your library.',
        guidance: 'Reconnect it, or wait for it to come back: Linthra retries '
            'on its own and picks the folder up as soon as it answers.',
        canReselect: true,
      );
    case LocalRootFault.unknown:
      return const LocalRootProblemPresentation(
        icon: Icons.error_outline,
        title: "Folder can't be read",
        explanation: "Linthra couldn't read this folder, and the system didn't "
            'say why. Its music stays in your library.',
        guidance: 'Retry, or select the folder again to restore access.',
        canReselect: true,
      );
  }
}
