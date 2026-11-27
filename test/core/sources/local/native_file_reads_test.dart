import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/local_file_stamp.dart';
import 'package:linthra/core/sources/local/directory_readability.dart';
import 'package:linthra/core/sources/local/native_file_reads.dart';

/// What the scan reads about the files it listed, on real folders: each
/// one's stamp, the bytes of each CUE sheet, and whether a file it could not
/// read is gone. A stamp that drifts re-reads a whole library, or never
/// re-reads a changed file; a wrong "gone" drops a song that is only out of
/// reach.
///
/// Through the real Rust library hook/build.dart builds for the test host.
/// Storage that stops answering can't be staged here, so the Rust tests
/// (native/linthra_core/src/scan/files.rs) cover it with a fake filesystem.
void main() {
  const NativeLocalFileStatReader reader = NativeLocalFileStatReader();

  late Directory temp;
  late String root;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('linthra_reads_');
    root = '${temp.path}/Music';
  });
  tearDown(() => temp.deleteSync(recursive: true));

  test('stamps files, following links, and nothing else', () async {
    final LocalFileStamp a = _file('$root/a.flac', 'abc', 1577836800000);
    final LocalFileStamp b = _file('$root/sub/b.cue', 'FILE "b.flac" WAVE', 5);
    final LocalFileStamp empty = _file('$root/empty.cue', '', 7);
    // The earliest and the latest times a scan meets in practice.
    final LocalFileStamp old = _file('$root/old.flac', 'x', 1);
    final LocalFileStamp late = _file('$root/new.flac', 'y', 2147483648999);
    Link('$root/link.flac').createSync('$root/a.flac');
    Link('$root/linkdir').createSync('$root/sub');
    Link('$root/dangling.flac').createSync('$root/nowhere');
    final ServerSocket socket = await ServerSocket.bind(
      InternetAddress('$root/sock', type: InternetAddressType.unix),
      0,
    );
    addTearDown(socket.close);
    // A Latin-1 name: the text Dart has for it holds U+FFFD and names
    // nothing.
    File.fromRawPath(
      _raw(root, <int>[...'caf'.codeUnits, 0xE9, ...'.cue'.codeUnits]),
    ).writeAsBytesSync(<int>[1, 2, 3]);

    final Map<String, LocalFileStamp?> expected = <String, LocalFileStamp?>{
      '$root/a.flac': a,
      '$root/empty.cue': empty,
      '$root/sub/b.cue': b,
      '$root/old.flac': old,
      '$root/new.flac': late,
      '$root/link.flac': a,
      '$root/linkdir': null,
      '$root/linkdir/b.cue': b,
      '$root/dangling.flac': null,
      '$root/sock': null,
      '$root/sub': null,
      '$root/missing.flac': null,
      '$root/a.flac/': null,
      '$root/./sub//b.cue': b,
      '$root/sub/../a.flac': a,
      '$root/caf�.cue': null,
      'relative/nothing.flac': null,
      '': null,
    };
    for (final MapEntry<String, LocalFileStamp?> e in expected.entries) {
      expect(await reader.stamp(e.key), e.value, reason: e.key);
    }
    // All at once, in order.
    expect(
      await reader.stampAll(expected.keys.toList()),
      expected.values.toList(),
    );
    expect(await reader.stampAll(const <String>[]), isEmpty);
  });

  test('reads a CUE sheet whole, or not at all', () async {
    _file('$root/a.cue', 'FILE "a.flac" WAVE', 1);
    _file('$root/empty.cue', '', 1);
    Link('$root/link.cue').createSync('$root/a.cue');
    Directory('$root/folder.cue').createSync();

    Future<List<int>?> read(String path) =>
        readScanFile(path, storageStallLimit);
    expect(await read('$root/a.cue'), utf8.encode('FILE "a.flac" WAVE'));
    expect(await read('$root/link.cue'), utf8.encode('FILE "a.flac" WAVE'));
    expect(await read('$root/empty.cue'), isEmpty);
    expect(await read('$root/folder.cue'), isNull);
    expect(await read('$root/missing.cue'), isNull);
  });

  group('a file the scan could not read', () {
    setUp(() {
      _file('$root/Artist/Album/01.flac', 'x', 1);
      _file('$root/Artist/Album/02.flac', 'x', 1);
      Directory('$root/Artist/Empty').createSync();
      Link('$root/Artist/Linked').createSync('$root/Artist/Album');
    });

    Future<bool> gone(String path, {String? from}) =>
        reader.isGone(path, root: from ?? root);

    test('is not gone while its folder still lists it', () async {
      expect(await gone('$root/Artist/Album/01.flac'), isFalse);
      expect(await gone('$root/Artist/./Album//02.flac'), isFalse);
      expect(await gone('$root/Artist/Linked/01.flac'), isFalse);
      // However the selected folder is written.
      for (final String from in <String>[
        '$root/',
        '$root/.',
        '${temp.path}/./Music',
        '${temp.path}/x/../Music',
      ]) {
        expect(await gone('$root/Artist/Album/01.flac', from: from), isFalse,
            reason: from);
      }
    });

    test('is gone once its folder lists it no more', () async {
      File('$root/Artist/Album/01.flac').renameSync('$root/Holocene.flac');
      expect(await gone('$root/Artist/Album/01.flac'), isTrue);
      expect(await gone('$root/Artist/Album/../Album/03.flac'), isTrue);
      expect(await gone('$root/Artist/Linked/09.flac'), isTrue);
      expect(await gone('$root/Artist/Empty/x.flac'), isTrue);
      expect(await gone('$root/Artist/Album/01.flac', from: '$root/'), isTrue);
    });

    test('is gone when its whole folder moved away', () async {
      // Said by the folder above, which lists the folder no more.
      Directory('$root/Artist').renameSync('$root/Elsewhere');
      expect(await gone('$root/Artist/Album/01.flac'), isTrue);
      expect(await gone('$root/Gone/Deeper/01.flac'), isTrue);
    });

    test('is not known to be gone when its folder cannot be listed', () async {
      // 01.flac is not a folder, so nothing can be listed inside it; the
      // folder above still lists it.
      expect(await gone('$root/Artist/Album/01.flac/inside'), isFalse);
    });

    test('is not known to be gone when the selected folder is gone', () async {
      // A drive that went away: nothing up to the selected folder answers,
      // and nothing above it is asked.
      temp.deleteSync(recursive: true);
      temp.createSync();
      expect(await gone('$root/Artist/Album/01.flac'), isFalse);
      expect(
        await gone('$root/Artist/Album/01.flac', from: temp.path),
        isTrue,
        reason: 'from the folder above, Music is gone',
      );
    });

    test('is never gone outside the selected folder', () async {
      expect(await gone('${temp.path}/elsewhere.flac'), isFalse);
      expect(await gone('${temp.path}/MusicToo/01.flac'), isFalse);
      expect(await gone('$root/../Music/Artist/Album/03.flac'), isTrue);
      expect(await gone('$root/..'), isFalse);
      expect(await gone(root), isFalse);
      expect(await gone('$root/'), isFalse);
      expect(await gone('/'), isFalse);
      expect(
        await gone('$root/Artist/Album/03.flac', from: '${temp.path}/Missing'),
        isFalse,
      );
    });

    test('keeps a name that is not UTF-8 when its folder lists it', () async {
      File.fromRawPath(_raw(
        '$root/Artist/Album',
        <int>[...'od'.codeUnits, 0x80, ...'.flac'.codeUnits],
      )).createSync();
      expect(await gone('$root/Artist/Album/od�.flac'), isFalse);
    }, skip: Platform.isLinux ? false : 'raw byte names are a Linux case');
  });

  test('random trees: every file stamped as made, folders and links not',
      () async {
    final Random random = Random(29);
    for (int i = 0; i < 30; i++) {
      final String tree = '${temp.path}/t$i';
      Directory(tree).createSync(recursive: true);
      final Map<String, LocalFileStamp?> made = <String, LocalFileStamp?>{
        tree: null,
      };
      _randomTree(random, tree, made, depth: 0);
      for (final MapEntry<String, LocalFileStamp?> e in made.entries) {
        expect(await reader.stamp(e.key), e.value, reason: e.key);
      }
      expect(
        await reader.stampAll(made.keys.toList()),
        made.values.toList(),
        reason: tree,
      );
    }
  });
}

/// Writes [contents] to [path] with its modified time set to [modifiedAtMs],
/// and returns the stamp it should have.
LocalFileStamp _file(String path, String contents, int modifiedAtMs) {
  File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(contents)
    ..setLastModifiedSync(
      DateTime.fromMillisecondsSinceEpoch(modifiedAtMs, isUtc: true),
    );
  return LocalFileStamp(
    sizeBytes: utf8.encode(contents).length,
    modifiedAtMs: modifiedAtMs,
  );
}

/// A random tree under [dir]: files of random sizes and times, folders,
/// links to a folder or to nothing. Each path goes into [made] with the
/// stamp it should have: none for a folder or a link that leads to no file.
void _randomTree(
  Random random,
  String dir,
  Map<String, LocalFileStamp?> made, {
  required int depth,
}) {
  for (int i = 0; i < random.nextInt(6); i++) {
    final String name = <String>['a', 'b', 'Ä', 'z z', '.hidden', '中'][i % 6];
    switch (random.nextInt(depth < 3 ? 4 : 2)) {
      case 0:
      case 1:
        final String path =
            '$dir/$name$i.${random.nextBool() ? 'cue' : 'flac'}';
        final int size = random.nextInt(3000);
        final int modified = random.nextInt(1 << 32) * 997;
        File(path)
          ..writeAsBytesSync(
            List<int>.generate(size, (int b) => random.nextInt(256)),
          )
          ..setLastModifiedSync(
            DateTime.fromMillisecondsSinceEpoch(modified, isUtc: true),
          );
        made[path] = LocalFileStamp(sizeBytes: size, modifiedAtMs: modified);
      case 2:
        Directory('$dir/$name$i').createSync();
        made['$dir/$name$i'] = null;
        _randomTree(random, '$dir/$name$i', made, depth: depth + 1);
      default:
        Link('$dir/l$i').createSync(random.nextBool() ? dir : '$dir/x');
        made['$dir/l$i'] = null;
    }
  }
}

/// [name]'s raw bytes under [dir].
Uint8List _raw(String dir, List<int> name) =>
    Uint8List.fromList(<int>[...utf8.encode('$dir/'), ...name]);
