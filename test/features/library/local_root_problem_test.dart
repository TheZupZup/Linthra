// The words a broken local folder is described with (#414).
//
// Pure, so the states a real machine is awkward to hold in (a network share
// that stopped answering, a folder whose permissions changed under you) are
// all one function call away. The point of testing it on its own is that the
// Settings card and the Library screen both read from here, so if the words are
// right once they are right on both.
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/folder_location.dart';
import 'package:linthra/core/sources/local/local_root_fault.dart';
import 'package:linthra/features/library/local_root_problem.dart';

const String _safTree =
    'content://com.android.externalstorage.documents/tree/primary%3AMusic';

LocalRootProblemPresentation _forPath(LocalRootFault fault) {
  return localRootProblemPresentation(
    fault,
    location: FolderLocation.parse('/media/usb/Music'),
  );
}

void main() {
  group('localRootProblemPresentation', () {
    test('every fault resolves to something a person can read', () {
      // Total by construction: a fault that fell through would leave a user
      // staring at a library with no explanation, which is the bug.
      for (final LocalRootFault fault in LocalRootFault.values) {
        final LocalRootProblemPresentation presentation = _forPath(fault);

        expect(presentation.title, isNotEmpty);
        expect(presentation.explanation, isNotEmpty);
        expect(presentation.guidance, isNotEmpty);
      }
    });

    test('the three filesystem faults read differently', () {
      // The whole feature: one message covering "it is gone", "you may not read
      // it" and "the drive is not answering" is the message that was already
      // there, and it sent people to the wrong fix two times out of three.
      final Set<String> titles = <String>{
        for (final LocalRootFault fault in LocalRootFault.values)
          _forPath(fault).title,
      };

      expect(titles, hasLength(LocalRootFault.values.length));
    });

    test('a missing folder points at the drive and at reselecting', () {
      final LocalRootProblemPresentation presentation =
          _forPath(LocalRootFault.missing);

      expect(presentation.title, 'Folder not found');
      expect(presentation.guidance, contains('Reconnect'));
      expect(presentation.canReselect, isTrue);
    });

    test('a permission problem talks about permissions, not a missing drive',
        () {
      final LocalRootProblemPresentation presentation =
          _forPath(LocalRootFault.permissionDenied);

      expect(presentation.title, 'Permission denied');
      expect(presentation.explanation, contains('still there'));
      expect(presentation.guidance, contains('permissions'));
    });

    test('unresponsive storage is presented as temporary', () {
      // Nothing about the user's setup changed, so nothing should suggest they
      // reconfigure anything: this one usually fixes itself.
      final LocalRootProblemPresentation presentation =
          _forPath(LocalRootFault.unavailable);

      expect(presentation.explanation, contains('Nothing about your setup'));
      expect(presentation.guidance, contains('on its own'));
    });

    test('every fault promises the indexed music is still there', () {
      // The single most important sentence on this surface. A drive going away
      // must never read as the library having been thrown out.
      for (final LocalRootFault fault in LocalRootFault.values) {
        expect(
          _forPath(fault).explanation,
          contains('stays in your library'),
          reason: '$fault must not imply the music was lost',
        );
      }
    });

    test('nothing it says carries a path, an errno or an OS message', () {
      // There is no parameter one could arrive in, and this is the assertion
      // that keeps someone from adding one.
      for (final LocalRootFault fault in LocalRootFault.values) {
        final LocalRootProblemPresentation presentation =
            localRootProblemPresentation(
          fault,
          location: FolderLocation.parse('/media/usb/Secret Album'),
        );
        final String all = '${presentation.title} ${presentation.explanation} '
            '${presentation.guidance}';

        expect(all, isNot(contains('/media/usb')));
        expect(all, isNot(contains('Secret Album')));
        expect(all, isNot(contains('errno')));
      }
    });

    test('a SAF tree that refuses access is a grant to restore', () {
      // A content:// tree is a grant rather than a path, so access being
      // refused means the grant went, and the way back is the chooser.
      final LocalRootProblemPresentation presentation =
          localRootProblemPresentation(
        LocalRootFault.permissionDenied,
        location: FolderLocation.parse(_safTree),
      );

      expect(presentation.title, 'Folder access was revoked');
      expect(presentation.canReselect, isTrue);
    });

    test('a SAF tree that failed for some other reason is not called revoked',
        () {
      // A content:// tree can also fail because the provider behind it cannot
      // be walked at all (a cloud or document provider), and that arrives with
      // no diagnosis. The grant is fine, and picking the same provider again
      // would change nothing, so promising it restores access would be a lie
      // the user can follow twice.
      final LocalRootProblemPresentation presentation =
          localRootProblemPresentation(
        LocalRootFault.unknown,
        location: FolderLocation.parse(_safTree),
      );

      expect(presentation.title, "Folder can't be read");
      expect(presentation.explanation, contains('stays in your library'));
    });

    test('the device library is never sent to a folder chooser', () {
      // Android's MediaStore selection is not a folder, so "select it again"
      // would be answering a question the user did not ask.
      final LocalRootProblemPresentation presentation =
          localRootProblemPresentation(
        LocalRootFault.permissionDenied,
        location: FolderLocation.parse(FolderLocation.androidMediaStoreAudio),
      );

      expect(presentation.title, 'Device music access is off');
      expect(presentation.canReselect, isFalse);
      expect(presentation.guidance, contains('Android settings'));
    });

    test('only a withdrawn permission sends the device library to settings',
        () {
      // MediaStore fails for reasons of its own: a null cursor, a platform
      // channel that never answered. The scan calls those something other than
      // a permission problem, and so must this. Sending that user to Android's
      // permission screen would be wrong, and the scan summary right below
      // would be saying something else.
      final LocalRootProblemPresentation unknown = localRootProblemPresentation(
        LocalRootFault.unknown,
        location: FolderLocation.parse(FolderLocation.androidMediaStoreAudio),
      );

      expect(unknown.title, "Device music can't be read");
      expect(unknown.guidance, isNot(contains('Android settings')));
      expect(unknown.explanation, contains('stays in your library'));
      expect(unknown.canReselect, isFalse);
      expect(
        unknown.title,
        isNot(
          localRootProblemPresentation(
            LocalRootFault.permissionDenied,
            location:
                FolderLocation.parse(FolderLocation.androidMediaStoreAudio),
          ).title,
        ),
      );
    });

    test('the device library never describes itself as a missing folder', () {
      for (final LocalRootFault fault in LocalRootFault.values) {
        final LocalRootProblemPresentation presentation =
            localRootProblemPresentation(
          fault,
          location: FolderLocation.parse(FolderLocation.androidMediaStoreAudio),
        );

        expect(presentation.canReselect, isFalse);
        expect(presentation.explanation, isNot(contains('folder')));
      }
    });
  });
}
