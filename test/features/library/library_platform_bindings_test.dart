import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/platform_folder_picker_service.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/filesystem_local_metadata_reader.dart';
import 'package:linthra/core/sources/local/io_local_lyrics_reader.dart';
import 'package:linthra/core/sources/local/local_metadata_reader.dart';
import 'package:linthra/core/sources/local/method_channel_saf_document_lister.dart';
import 'package:linthra/core/sources/local/method_channel_saf_lyrics_reader.dart';
import 'package:linthra/core/sources/local/method_channel_saf_permission_probe.dart';
import 'package:linthra/core/sources/local/saf_document_lister.dart';
import 'package:linthra/core/sources/local/saf_permission_probe.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/player/lyrics_providers.dart';

import '../../core/sources/local/audio_tag_fixtures.dart';

ProviderContainer _containerFor(HostPlatform host) {
  final container = ProviderContainer(
    overrides: <Override>[hostPlatformProvider.overrideWithValue(host)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('Android keeps its native bindings', () {
    late ProviderContainer container;

    setUp(() {
      container = _containerFor(HostPlatform.android);
    });

    test('SAF traversal goes through the content resolver', () {
      expect(container.read(safDocumentListerProvider),
          isA<MethodChannelSafDocumentLister>());
    });

    test('the persisted-grant probe is the native one', () {
      expect(container.read(safPermissionProbeProvider),
          isA<MethodChannelSafPermissionProbe>());
    });

    test('sidecar lyrics are read as a SAF sibling document', () {
      expect(container.read(localLyricsReaderProvider),
          isA<MethodChannelSafLyricsReader>());
    });

    test('tags still come from the SAF walk, not a second Dart read', () {
      // #407 added a filesystem tag reader for desktop. Android's tags (and its
      // cached embedded artwork) already come from the native walk, so reading
      // them again here would be duplicate work with a different answer.
      expect(container.read(localMetadataReaderProvider),
          isA<UnsupportedLocalMetadataReader>());
    });
  });

  group('Linux gets the desktop/unsupported bindings', () {
    late ProviderContainer container;

    setUp(() {
      container = _containerFor(HostPlatform.linux);
    });

    test('no SAF traversal — the scan falls back to the filesystem walk', () {
      // SAF is an Android content-resolver API. On Linux the binding must be
      // the explicitly unsupported one so LocalMusicSource resolves the folder
      // as a real path instead of calling a channel that does not exist.
      expect(container.read(safDocumentListerProvider),
          isA<UnsupportedSafDocumentLister>());
    });

    test('no persisted-grant probe — there are no SAF grants to hold', () {
      expect(container.read(safPermissionProbeProvider),
          isA<UnsupportedSafPermissionProbe>());
    });

    test('sidecar lyrics are read straight off the filesystem', () {
      expect(container.read(localLyricsReaderProvider),
          isA<IoLocalLyricsReader>());
    });

    test('none of the Android MethodChannel bindings are constructed', () {
      // The bindings above are the ones that would otherwise reach a native
      // channel on a platform with no Linthra plugin registered. Stated as one
      // assertion because it is the actual startup requirement: nothing built
      // for a Linux launch may be an Android channel client.
      expect(container.read(safDocumentListerProvider),
          isNot(isA<MethodChannelSafDocumentLister>()));
      expect(container.read(safPermissionProbeProvider),
          isNot(isA<MethodChannelSafPermissionProbe>()));
      expect(container.read(localLyricsReaderProvider),
          isNot(isA<MethodChannelSafLyricsReader>()));
    });
  });

  group('bindings that are the same on both platforms', () {
    test('the scanner stays the platform-routing one everywhere', () {
      // PlatformAudioFileScanner already routes a content:// URI to SAF and a
      // path to the dart:io walk. Linux only ever hands it paths, so the
      // desktop build needs no separate scanner.
      for (final HostPlatform host in <HostPlatform>[
        HostPlatform.android,
        HostPlatform.linux,
      ]) {
        expect(_containerFor(host).read(audioFileScannerProvider),
            isA<PlatformAudioFileScanner>());
      }
    });

    test('the folder picker stays the platform-routing one everywhere', () {
      for (final HostPlatform host in <HostPlatform>[
        HostPlatform.android,
        HostPlatform.linux,
      ]) {
        expect(_containerFor(host).read(folderPickerServiceProvider),
            isA<PlatformFolderPickerService>());
      }
    });

    test('tags are read off the filesystem', () {
      // #407: Linux reads real tags rather than falling back to the filename.
      expect(
          _containerFor(HostPlatform.linux).read(localMetadataReaderProvider),
          isA<FilesystemLocalMetadataReader>());
    });

    test('the tag reader lets its parser isolate go with the container',
        () async {
      final Directory temp =
          await Directory.systemTemp.createTemp('linthra_bindings_');
      addTearDown(() => temp.delete(recursive: true));
      final TestDefaultBinaryMessenger messenger =
          TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
      const MethodChannel pathProvider =
          MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(
        pathProvider,
        (MethodCall call) async => temp.path,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(pathProvider, null));
      final File file = File('${temp.path}/One.flac')
        ..writeAsBytesSync(AudioTagFixtures.flac(title: 'One'));
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          hostPlatformProvider.overrideWithValue(HostPlatform.linux),
        ],
      );
      final FilesystemLocalMetadataReader reader = container
          .read(localMetadataReaderProvider) as FilesystemLocalMetadataReader;
      addTearDown(reader.close);

      expect((await reader.readFromPath(file.path))?.title, 'One');
      container.dispose();
      expect((await reader.readFromPath(file.path))?.title, 'One');

      expect(reader.parsersStarted, 2, reason: 'closed with the container');
    });
  });
}
