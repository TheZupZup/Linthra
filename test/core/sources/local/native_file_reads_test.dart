import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/directory_readability.dart';
import 'package:linthra/core/sources/local/local_file_stat.dart';
import 'package:linthra/core/sources/local/native_file_reads.dart';

/// The Rust reads have to answer what the Dart ones answer: the same stamp
/// for every path, the same "gone" for every file a scan could not read, and
/// the same bytes (or none) for every CUE sheet. A stamp that drifts re-reads
/// a whole library, or never re-reads a changed file; a wrong "gone" drops a
/// song that is only out of reach.
///
/// Real folders, through the real Rust library hook/build.dart builds for
/// the test host. Storage that stops answering can't be staged here, so the
/// Rust tests (native/linthra_core/src/scan/files.rs) cover it with a fake
/// filesystem.
void main() {
  const IoLocalFileStatReader dart = IoLocalFileStatReader();
  const NativeLocalFileStatReader rust = NativeLocalFileStatReader();

  late Directory temp;
  late String root;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('linthra_reads_');
    root = '${temp.path}/Music';
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Future<void> expectSame(String path) async {
    expect(
      await rust.stamp(path),
      await dart.stamp(path),
      reason: 'stamp $path',
    );
    expect(
      await readScanFile(path, storageStallLimit),
      await _readWhole(path),
      reason: 'read $path',
    );
  }

  Future<void> expectSameBatch(List<String> paths) async {
    expect(
      await rust.stampAll(paths),
      <Object?>[for (final String path in paths) await dart.stamp(path)],
      reason: 'stampAll $paths',
    );
  }

  Future<void> expectSameGone(String path, String root) async {
    expect(
      await rust.isGone(path, root: root),
      await dart.isGone(path, root: root),
      reason: 'isGone $path in $root',
    );
  }

  group('native file reads', () {
    test('stamp and read every kind of entry like Dart', () async {
      _file('$root/a.flac', 'abc');
      _file('$root/empty.cue', '');
      _file('$root/sub/b.cue', 'FILE "b.flac" WAVE');
      File('$root/old.flac')
        ..writeAsStringSync('x')
        ..setLastModifiedSync(DateTime.utc(1970, 1, 1, 0, 0, 0, 1));
      File('$root/new.flac')
        ..writeAsStringSync('y')
        ..setLastModifiedSync(DateTime.utc(2038, 1, 19, 3, 14, 8, 999));
      Link('$root/link.flac').createSync('$root/a.flac');
      Link('$root/linkdir').createSync('$root/sub');
      Link('$root/dangling.flac').createSync('$root/nowhere');
      final ServerSocket socket = await ServerSocket.bind(
        InternetAddress('$root/sock', type: InternetAddressType.unix),
        0,
      );
      addTearDown(socket.close);
      final List<int> latin1 = <int>[
        ...'caf'.codeUnits,
        0xE9,
        ...'.cue'.codeUnits
      ];
      File.fromRawPath(_raw(root, latin1)).writeAsBytesSync(<int>[1, 2, 3]);

      final List<String> paths = <String>[
        '$root/a.flac',
        '$root/empty.cue',
        '$root/sub/b.cue',
        '$root/old.flac',
        '$root/new.flac',
        '$root/link.flac',
        '$root/linkdir',
        '$root/linkdir/b.cue',
        '$root/dangling.flac',
        '$root/sock',
        '$root/sub',
        '$root/missing.flac',
        '$root/a.flac/',
        '$root/./sub//b.cue',
        '$root/sub/../a.flac',
        // The text Dart has for the Latin-1 name, which names nothing.
        '$root/caf\uFFFD.cue',
        'relative/nothing.flac',
        '',
      ];
      for (final String path in paths) {
        await expectSame(path);
      }
      await expectSameBatch(paths);
      await expectSameBatch(<String>[]);
    });

    test('decide "gone" like Dart', () async {
      _file('$root/Artist/Album/01.flac', 'x');
      _file('$root/Artist/Album/02.flac', 'x');
      Directory('$root/Artist/Empty').createSync();
      Link('$root/Artist/Linked').createSync('$root/Artist/Album');
      final List<int> odd = <int>[
        ...'od'.codeUnits,
        0x80,
        ...'.flac'.codeUnits
      ];
      File.fromRawPath(_raw('$root/Artist/Album', odd)).createSync();

      final List<String> paths = <String>[
        '$root/Artist/Album/01.flac',
        '$root/Artist/Album/03.flac',
        '$root/Artist/Moved/01.flac',
        '$root/Gone/Deeper/01.flac',
        '$root/Artist/Linked/01.flac',
        '$root/Artist/Linked/09.flac',
        '$root/Artist/Album/01.flac/inside',
        '$root/Artist/Album/od\uFFFD.flac',
        '$root/Artist/Empty/x.flac',
        '$root/Artist/./Album//02.flac',
        '$root/Artist/Album/../Album/03.flac',
        '$root/../Music/Artist/Album/03.flac',
        '$root/..',
        root,
        '$root/',
        '${temp.path}/elsewhere.flac',
        '${temp.path}/MusicToo/01.flac',
        '/',
      ];
      for (final String r in <String>[
        root,
        '$root/',
        '$root/.',
        '${temp.path}/./Music',
        '${temp.path}/x/../Music',
        '$root/Artist',
        '${temp.path}/Missing',
        '/',
      ]) {
        for (final String path in paths) {
          await expectSameGone(path, r);
        }
      }
    });

    test('decide "gone" like Dart once the folder is gone', () async {
      _file('$root/Artist/Album/01.flac', 'x');
      temp.deleteSync(recursive: true);
      temp.createSync();
      await expectSameGone('$root/Artist/Album/01.flac', root);
      await expectSameGone('$root/Artist/Album/01.flac', temp.path);
    });

    test('match Dart on random trees and paths', () async {
      final Random random = Random(29);
      const List<String> names = <String>[
        'a',
        'b.flac',
        'c.cue',
        'Ä',
        'z z',
        '.',
        '..',
        '',
        '中.cue',
      ];
      for (int i = 0; i < 30; i++) {
        final String tree = '${temp.path}/t$i';
        Directory(tree).createSync();
        final List<String> made = _randomTree(random, tree, depth: 0);
        await expectSameBatch(made);
        for (int k = 0; k < 25; k++) {
          final StringBuffer path = StringBuffer(tree);
          final int depth = 1 + random.nextInt(4);
          for (int d = 0; d < depth; d++) {
            path.write('/');
            path.write(
              random.nextBool() && made.isNotEmpty
                  ? made[random.nextInt(made.length)].split('/').last
                  : names[random.nextInt(names.length)],
            );
          }
          final String candidate = random.nextInt(3) == 0
              ? made[random.nextInt(made.length)]
              : path.toString();
          await expectSame(candidate);
          await expectSameGone(candidate, random.nextBool() ? tree : '$tree/');
        }
      }
    });
  });
}

void _file(String path, String contents) => File(path)
  ..createSync(recursive: true)
  ..writeAsStringSync(contents);

/// A random tree under [dir]: files of random sizes and times, folders,
/// links to either or to nothing. Every path it made, [dir] included.
List<String> _randomTree(Random random, String dir, {required int depth}) {
  final List<String> made = <String>[dir];
  for (int i = 0; i < random.nextInt(6); i++) {
    final String name = <String>['a', 'b', 'Ä', 'z z', '.hidden', '中'][i % 6];
    switch (random.nextInt(depth < 3 ? 4 : 2)) {
      case 0:
      case 1:
        final String path =
            '$dir/$name$i.${random.nextBool() ? 'cue' : 'flac'}';
        File(path)
          ..writeAsBytesSync(List<int>.generate(
            random.nextInt(3000),
            (int b) => random.nextInt(256),
          ))
          ..setLastModifiedSync(
            DateTime.fromMillisecondsSinceEpoch(random.nextInt(1 << 32) * 997),
          );
        made.add(path);
      case 2:
        Directory('$dir/$name$i').createSync();
        made.addAll(_randomTree(random, '$dir/$name$i', depth: depth + 1));
      default:
        Link('$dir/l$i').createSync(random.nextBool() ? dir : '$dir/x');
        made.add('$dir/l$i');
    }
  }
  return made;
}

/// [name]'s raw bytes under [dir].
Uint8List _raw(String dir, List<int> name) =>
    Uint8List.fromList(<int>[...utf8.encode('$dir/'), ...name]);

/// The whole file through `dart:io`, or null when it can't be read.
Future<List<int>?> _readWhole(String path) async {
  try {
    return await File(path).readAsBytes();
  } on FileSystemException {
    return null;
  }
}
