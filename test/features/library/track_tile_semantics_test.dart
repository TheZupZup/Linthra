import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/download_progress.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/sources/music_provider.dart';
import 'package:linthra/core/sources/source_availability.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/features/downloads/download_providers.dart';
import 'package:linthra/features/library/source_availability_providers.dart';
import 'package:linthra/features/library/widgets/track_tile.dart';
import 'package:linthra/features/player/now_playing.dart';

import 'fake_remote_track_downloader.dart';

/// A track row is the thing a listener meets most often, and everything it says
/// beyond the title and artist is carried by a glyph: whether this is the song
/// playing, whether it is saved offline, whether it is selected. Each of those
/// has to survive being heard rather than seen.
const Track _remote = Track(
  id: 'a',
  title: 'Careful',
  uri: 'jellyfin:a',
  artistName: 'NF',
  albumName: 'Perception',
);

Future<void> _pump(
  WidgetTester tester, {
  NowPlaying? nowPlaying,
  DownloadStatus status = DownloadStatus.notDownloaded,
  bool selectionActive = false,
  bool selected = false,
  SourceAvailability availability = SourceAvailability.available,
  bool offlineCopy = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        remoteTrackDownloaderProvider
            .overrideWithValue(FakeRemoteTrackDownloader()),
        if (nowPlaying != null)
          nowPlayingProvider.overrideWithValue(nowPlaying),
        sourceAvailabilityProvider.overrideWith(
          (ref) => <String, SourceAvailability>{
            MusicProviders.jellyfin.sourceId: availability,
          },
        ),
        if (offlineCopy)
          offlineAvailableTrackKeysProvider.overrideWithValue(
            <String>{CachedTrack.cacheKeyForTrack(_remote)},
          ),
        trackDownloadStatusProvider.overrideWith(
          (ref, String key) => Stream<DownloadStatus>.value(status),
        ),
        // The in-flight row also watches byte progress; a known fraction keeps
        // the ring determinate instead of reaching for a real repository.
        trackDownloadProgressProvider.overrideWith(
          (ref, String key) => Stream<DownloadProgress?>.value(
            status == DownloadStatus.downloading
                ? const DownloadProgress(
                    trackId: 'a',
                    receivedBytes: 1,
                    totalBytes: 2,
                  )
                : null,
          ),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ListView(
            children: <Widget>[
              TrackTile(
                tracks: const <Track>[_remote],
                index: 0,
                selectable: true,
                selectionActive: selectionActive,
                selected: selected,
                onSelectToggle: () {},
              ),
            ],
          ),
        ),
      ),
    ),
  );
  // Not pumpAndSettle: a playing indicator and a download ring both animate
  // forever. Two frames: one to deliver the overridden status stream, one to
  // rebuild the row on it.
  await tester.pump();
  await tester.pump();
}

/// The row merges into a single node, so everything it says arrives as one
/// announcement: the playback state, then the title and artist, then the
/// offline state. This reads that node.
SemanticsNode _row(WidgetTester tester) =>
    tester.getSemantics(find.text('Careful'));

void main() {
  group('TrackTile semantics', () {
    testWidgets('the playing row says it is playing', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(
        tester,
        nowPlaying: const NowPlaying(currentTrack: _remote, isPlaying: true),
      );

      expect(_row(tester).label, contains('Now playing'));
      expect(_row(tester).label, isNot(contains('paused')));
      handle.dispose();
    });

    testWidgets('a paused row says paused rather than playing', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(
        tester,
        nowPlaying: const NowPlaying(currentTrack: _remote, isPlaying: false),
      );

      expect(_row(tester).label, contains('Now playing, paused'));
      handle.dispose();
    });

    testWidgets('a row that is not playing says nothing about playback',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester, nowPlaying: const NowPlaying());

      expect(_row(tester).label, isNot(contains('Now playing')));
      // The title and artist are still there — only the state is absent.
      expect(_row(tester).label, contains('Careful'));
      handle.dispose();
    });

    testWidgets('a saved row says it is downloaded', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester, status: DownloadStatus.downloaded);

      expect(_row(tester).label, contains('Downloaded'));
      handle.dispose();
    });

    testWidgets('a downloading row says so — the ring used to be silent',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester, status: DownloadStatus.downloading);

      expect(_row(tester).label, contains('Downloading'));
      handle.dispose();
    });

    testWidgets('a queued row says queued', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester, status: DownloadStatus.queued);

      expect(_row(tester).label, contains('Queued'));
      handle.dispose();
    });

    testWidgets('a failed row says the download failed', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester, status: DownloadStatus.failed);

      expect(_row(tester).label, contains('Download failed'));
      handle.dispose();
    });

    testWidgets('a row with nothing to report adds no offline state',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester, status: DownloadStatus.notDownloaded);

      // Exactly the visible text, nothing invented on top of it.
      expect(_row(tester).label, 'Careful\nNF • Perception');
      handle.dispose();
    });

    testWidgets('a row whose server is away says so', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester, availability: SourceAvailability.unreachable);

      expect(_row(tester).label, contains('Jellyfin unavailable'));
      handle.dispose();
    });

    testWidgets('a row saved offline says the server being away is survivable',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(
        tester,
        offlineCopy: true,
        availability: SourceAvailability.unreachable,
      );

      expect(_row(tester).label, contains('Playing from offline copy'));
      // The row still plays, so it must not also be announced as broken.
      expect(_row(tester).label, isNot(contains('unavailable')));
      handle.dispose();
    });

    testWidgets('a rejected session asks for a sign-in instead of the network',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester, availability: SourceAvailability.authenticationError);

      expect(_row(tester).label, contains('Jellyfin sign-in needed'));
      handle.dispose();
    });

    testWidgets('a selected row is exposed as selected, once', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester, selectionActive: true, selected: true);

      expect(_row(tester).flagsCollection.isSelected, Tristate.isTrue);

      // The box beside the title mirrors that state visually; it must not
      // also appear as a second, unnamed toggle in the reading order.
      expect(find.byType(Checkbox), findsOneWidget);
      expect(
        find.semantics.byFlag(SemanticsFlag.hasCheckedState),
        findsNothing,
      );
      handle.dispose();
    });

    testWidgets('an unselected row in selection mode says so', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester, selectionActive: true);

      expect(_row(tester).flagsCollection.isSelected, Tristate.isFalse);
      // The row carries the state either way, so an unselected row is
      // announced as unselected rather than as having no state at all.
      expect(
        _row(tester).flagsCollection.isSelected,
        isNot(Tristate.none),
      );
      handle.dispose();
    });

    testWidgets('the overflow menu is named', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester);

      expect(
        tester.getSemantics(find.byTooltip('More actions')),
        matchesSemantics(
          tooltip: 'More actions',
          isButton: true,
          isFocusable: true,
          isEnabled: true,
          hasEnabledState: true,
          hasTapAction: true,
          hasFocusAction: true,
          hasExpandedState: true,
        ),
      );
      handle.dispose();
    });
  });
}
