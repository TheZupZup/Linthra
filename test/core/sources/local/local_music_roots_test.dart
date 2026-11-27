import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/folder_location.dart';
import 'package:linthra/core/sources/local/local_music_roots.dart';

const String _safTree =
    'content://com.android.externalstorage.documents/tree/primary%3AMusic';

void main() {
  group('LocalMusicRoots.normalize', () {
    test('keeps the user order and drops blanks', () {
      expect(
        LocalMusicRoots.normalize(<String>['/music', '  ', '/media/usb', '']),
        <String>['/music', '/media/usb'],
      );
    });

    test('drops a folder selected twice, however it is spelled', () {
      expect(
        LocalMusicRoots.normalize(<String>['/music', '/music/', '/music/.']),
        <String>['/music'],
      );
    });

    test('drops a folder that sits inside another selected folder', () {
      expect(
        LocalMusicRoots.normalize(<String>['/music', '/music/live sets']),
        <String>['/music'],
      );
    });

    test('a folder containing selected ones replaces them', () {
      expect(
        LocalMusicRoots.normalize(<String>[
          '/music/live sets',
          '/music/albums',
          '/media/usb',
          '/music',
        ]),
        <String>['/media/usb', '/music'],
      );
    });

    test('a trailing space is part of a folder name, not padding', () {
      // Two different folders on Linux; trimming made them one.
      expect(
        LocalMusicRoots.normalize(<String>['/music/Live ', '/music/Live']),
        <String>['/music/Live ', '/music/Live'],
      );
      expect(LocalMusicRoots.canonicalize('/music/Live /'), '/music/Live ');
    });

    test('sibling folders with a shared prefix both survive', () {
      // '/music2' is not inside '/music', however similar the strings look.
      expect(
        LocalMusicRoots.normalize(<String>['/music', '/music2']),
        <String>['/music', '/music2'],
      );
    });

    test('opaque Android selections are only ever compared literally', () {
      expect(
        LocalMusicRoots.normalize(<String>[
          _safTree,
          _safTree,
          FolderLocation.androidMediaStoreAudio,
        ]),
        <String>[_safTree, FolderLocation.androidMediaStoreAudio],
      );
    });
  });

  group('LocalMusicRoots.ownerOf', () {
    const List<String> roots = <String>['/music', '/media/usb'];

    test('a file under a folder belongs to it', () {
      expect(
        LocalMusicRoots.ownerOf('/media/usb/Album/01.mp3', roots),
        '/media/usb',
      );
    });

    test('a file under no selected folder has no owner', () {
      expect(LocalMusicRoots.ownerOf('/downloads/01.mp3', roots), isNull);
    });

    test('a shared prefix does not make a file part of a folder', () {
      expect(LocalMusicRoots.ownerOf('/music2/01.mp3', roots), isNull);
    });

    test('the deepest folder wins when a list was not normalized', () {
      expect(
        LocalMusicRoots.ownerOf(
          '/music/live sets/01.mp3',
          <String>['/music', '/music/live sets'],
        ),
        '/music/live sets',
      );
    });

    test('a remote track never belongs to a local folder', () {
      expect(LocalMusicRoots.ownerOf('jellyfin:101', roots), isNull);
    });
  });

  group('LocalMusicRoots.isCoveredBy', () {
    test('a folder already selected adds nothing', () {
      expect(
        LocalMusicRoots.isCoveredBy('/music/', <String>['/music']),
        isTrue,
      );
    });

    test('a folder inside a selected one adds nothing', () {
      expect(
        LocalMusicRoots.isCoveredBy('/music/live sets', <String>['/music']),
        isTrue,
      );
    });

    test('a new folder is not covered', () {
      expect(
        LocalMusicRoots.isCoveredBy('/media/usb', <String>['/music']),
        isFalse,
      );
    });

    test('a folder containing a selected one is not covered by it', () {
      expect(
        LocalMusicRoots.isCoveredBy('/music', <String>['/music/live sets']),
        isFalse,
      );
    });
  });

  group('Android shared storage trees (#998)', () {
    String tree(String id) =>
        'content://com.android.externalstorage.documents/tree/'
        '${Uri.encodeComponent(id)}';

    test('a tree holds the trees inside it, and only those', () {
      expect(
        LocalMusicRoots.isCoveredBy(
          tree('primary:Music/Rock'),
          <String>[tree('primary:Music')],
        ),
        isTrue,
      );
      expect(
        LocalMusicRoots.isCoveredBy(
          tree('primary:Music'),
          <String>[tree('primary:')],
        ),
        isTrue,
      );
      for (final String other in <String>[
        tree('primary:Musical'),
        tree('primary:Podcasts'),
        tree('1234-ABCD:Music/Rock'),
      ]) {
        expect(
          LocalMusicRoots.isCoveredBy(other, <String>[tree('primary:Music')]),
          isFalse,
          reason: other,
        );
      }
    });

    test('adding the outer tree drops the inner one', () {
      expect(
        LocalMusicRoots.normalize(<String>[
          tree('primary:Music/Rock'),
          tree('primary:Podcasts'),
          tree('primary:Music'),
        ]),
        <String>[tree('primary:Podcasts'), tree('primary:Music')],
      );
    });

    test("another provider's trees are compared as they are", () {
      // Their ids mean nothing as paths.
      const String drive =
          'content://com.google.android.apps.docs.storage/tree/abc';
      expect(
        LocalMusicRoots.isCoveredBy(
          '$drive%2Fdef',
          <String>[drive],
        ),
        isFalse,
      );
      expect(
        LocalMusicRoots.isCoveredBy(
          tree('primary:Music/%ZZ').replaceAll('%25ZZ', '%ZZ'),
          <String>[tree('primary:Music')],
        ),
        isFalse,
        reason: 'not valid percent-encoding',
      );
    });

    test('each tree owns the documents under it', () {
      final String music = tree('primary:Music');
      final String podcasts = tree('primary:Podcasts');
      final String song =
          '$podcasts/document/${Uri.encodeComponent('primary:Podcasts/a.mp3')}';
      expect(
          LocalMusicRoots.ownerOf(song, <String>[music, podcasts]), podcasts);
    });
  });
}
