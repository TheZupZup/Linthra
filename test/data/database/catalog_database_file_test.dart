import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/database/catalog_database_file.dart';
import 'package:linthra/data/database/linthra_database.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

void main() {
  late Directory root;
  late Directory documents;
  late Directory support;

  setUp(() {
    root = Directory.systemTemp.createTempSync('linthra_catalog_');
    documents = Directory(p.join(root.path, 'Documents'))..createSync();
    // Not created: path_provider creates it on Linux, but the catalog must not
    // depend on that.
    support =
        Directory(p.join(root.path, 'data', 'io.github.thezupzup.linthra'));
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<File> resolve({
    bool isAndroid = false,
    Future<Directory> Function()? documentsDirectory,
  }) =>
      resolveCatalogFile(
        isAndroid: isAndroid,
        documentsDirectory: documentsDirectory ?? () async => documents,
        supportDirectory: () async => support,
      );

  File inDocuments([String suffix = '']) =>
      File(p.join(documents.path, '$catalogFileName$suffix'));
  File inSupport([String suffix = '']) =>
      File(p.join(support.path, '$catalogFileName$suffix'));

  test('Android keeps the catalog in the app documents directory', () async {
    final File file = await resolve(isAndroid: true);

    expect(file.path, inDocuments().path);
    expect(support.existsSync(), isFalse);
  });

  test('a desktop keeps the catalog in the application support directory',
      () async {
    final File file = await resolve();

    expect(file.path, inSupport().path);
    // SQLite creates the file but not the folder it goes in.
    expect(support.existsSync(), isTrue);
  });

  test('no Documents folder at all is not an error', () async {
    // What path_provider throws on Linux without xdg-user-dir, which used to
    // stop the catalog from opening at all.
    final File file = await resolve(
      documentsDirectory: () async => throw MissingPlatformDirectoryException(
        'Unable to get application documents directory',
      ),
    );

    expect(file.path, inSupport().path);
  });

  test('a catalog left in Documents moves over with its journal', () async {
    inDocuments().writeAsStringSync('catalog');
    inDocuments('-journal').writeAsStringSync('journal');

    final File file = await resolve();

    expect(file.path, inSupport().path);
    expect(inSupport().readAsStringSync(), 'catalog');
    expect(inSupport('-journal').readAsStringSync(), 'journal');
    expect(inDocuments().existsSync(), isFalse);
    expect(inDocuments('-journal').existsSync(), isFalse);
    expect(File('${inSupport().path}.partial').existsSync(), isFalse);
  });

  test('a moved catalog opens with the library it had', () async {
    final LinthraDatabase before =
        LinthraDatabase.forTesting(NativeDatabase(inDocuments()));
    await before.into(before.tracks).insert(
          TracksCompanion.insert(
            id: '/music/one.mp3',
            sourceId: 'local',
            title: 'One',
            uri: '/music/one.mp3',
            albumId: const Value('album-1'),
          ),
        );
    await before.close();

    final LinthraDatabase after =
        LinthraDatabase.forTesting(NativeDatabase(await resolve()));
    addTearDown(after.close);

    final List<TrackRow> tracks = await after.select(after.tracks).get();
    expect(tracks.single.title, 'One');
  });

  test('a catalog already in the support directory wins', () async {
    support.createSync(recursive: true);
    inSupport().writeAsStringSync('current');
    inDocuments().writeAsStringSync('older');

    final File file = await resolve();

    expect(file.path, inSupport().path);
    expect(inSupport().readAsStringSync(), 'current');
    expect(inDocuments().readAsStringSync(), 'older');
  });

  test('a move that cannot finish opens the catalog where it was', () async {
    inDocuments().writeAsStringSync('catalog');
    inDocuments('-journal').writeAsStringSync('journal');
    // Something in the way of the copy, standing in for a full disk or a
    // data folder that cannot be written. A folder works even as root.
    Directory('${inSupport().path}.partial').createSync(recursive: true);

    final File file = await resolve();

    expect(file.path, inDocuments().path);
    expect(inDocuments().readAsStringSync(), 'catalog');
    expect(inDocuments('-journal').readAsStringSync(), 'journal');
    expect(inSupport().existsSync(), isFalse);
    // A half-moved journal would be replayed into the next catalog there.
    expect(inSupport('-journal').existsSync(), isFalse);
  });

  test('a move cut off halfway finishes on the next launch', () async {
    // The journal was copied, then the app stopped before the catalog was.
    support.createSync(recursive: true);
    inDocuments().writeAsStringSync('catalog');
    inDocuments('-journal').writeAsStringSync('journal');
    inSupport('-journal').writeAsStringSync('journal');
    File('${inSupport().path}.partial').writeAsStringSync('cata');

    final File file = await resolve();

    expect(file.path, inSupport().path);
    expect(inSupport().readAsStringSync(), 'catalog');
    expect(inSupport('-journal').readAsStringSync(), 'journal');
    expect(inDocuments().existsSync(), isFalse);
  });

  test('a stale journal is not kept for a catalog that has none', () async {
    // Left by an attempt that never finished, for a journal the catalog in
    // Documents has since replayed and dropped.
    support.createSync(recursive: true);
    inSupport('-journal').writeAsStringSync('stale');
    inDocuments().writeAsStringSync('catalog');

    await resolve();

    expect(inSupport().readAsStringSync(), 'catalog');
    expect(inSupport('-journal').existsSync(), isFalse);
  });
}
