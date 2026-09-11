import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/sources/music_provider.dart';
import 'package:linthra/core/sources/source_availability.dart';
import 'package:linthra/features/downloads/download_providers.dart';
import 'package:linthra/features/library/source_availability_providers.dart';
import 'package:linthra/features/library/widgets/track_status_glyph.dart';

/// A row's status glyph is the only place a listener is told whether the music
/// in front of them will still play when the server is away. These tests hold it
/// to the two things that are easy to get wrong: saying something when there is
/// nothing to say (which teaches people to ignore it), and saying the wrong
/// thing about *why* a row will not play (a rejected session is not a dead
/// server, and the fix is different).
const Track _remote = Track(
  id: 'a',
  title: 'Careful',
  uri: 'jellyfin:a',
  artistName: 'NF',
  albumName: 'Perception',
);

const Track _local = Track(
  id: 'b',
  title: 'Something Local',
  uri: 'file:///b.mp3',
);

/// The server's state, as the availability probe would publish it. Held as a
/// provider so a test can move it while the glyph is on screen — the reconnect
/// case, which must not need an app restart.
final StateProvider<SourceAvailability> _serverState =
    StateProvider<SourceAvailability>((ref) => SourceAvailability.available);

/// Pumps one row's glyph. Returns the container so a test can move the server
/// state afterwards without rebuilding the widget tree.
Future<ProviderContainer> _pump(
  WidgetTester tester, {
  Track track = _remote,
  bool isRemote = true,
  SourceAvailability availability = SourceAvailability.available,
  DownloadStatus status = DownloadStatus.notDownloaded,
  bool hasOfflineCopy = false,
}) async {
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      _serverState.overrideWith((ref) => availability),
      sourceAvailabilityProvider.overrideWith(
        (ref) => <String, SourceAvailability>{
          MusicProviders.jellyfin.sourceId: ref.watch(_serverState),
        },
      ),
      offlineAvailableTrackKeysProvider.overrideWithValue(
        hasOfflineCopy
            ? <String>{CachedTrack.cacheKeyForTrack(track)}
            : const <String>{},
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: TrackStatusGlyph(
              track: track,
              isRemote: isRemote,
              downloadStatus: status,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

/// Nothing rendered at all — the answer for the overwhelming majority of rows.
void _expectSilent(WidgetTester tester) {
  expect(find.byType(Icon), findsNothing);
  expect(find.byType(CircularProgressIndicator), findsNothing);
}

void main() {
  group('TrackStatusGlyph stays quiet when there is nothing to say', () {
    testWidgets('an on-device track shows no glyph', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(
        tester,
        track: _local,
        isRemote: false,
        availability: SourceAvailability.unreachable,
      );

      _expectSilent(tester);
      handle.dispose();
    });

    testWidgets('an ordinary server-backed row shows no glyph', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester);

      _expectSilent(tester);
      handle.dispose();
    });
  });

  group('TrackStatusGlyph reports saved copies', () {
    testWidgets('an explicit download says downloaded', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester, status: DownloadStatus.downloaded);

      expect(find.bySemanticsLabel('Downloaded'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a prefetched copy says cached, not downloaded',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester, hasOfflineCopy: true);

      expect(find.bySemanticsLabel('Cached for offline play'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Downloaded'),
        findsNothing,
        reason: 'the user never asked for this copy and it can be evicted, so '
            'it must not read as one they own',
      );
      handle.dispose();
    });

    testWidgets('a saved copy says so when its server is away', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(
        tester,
        hasOfflineCopy: true,
        availability: SourceAvailability.unreachable,
      );

      expect(
          find.bySemanticsLabel('Playing from offline copy'), findsOneWidget);
      handle.dispose();
    });
  });

  group('TrackStatusGlyph reports a server that cannot serve this row', () {
    testWidgets('an unreachable server reads as unavailable', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester, availability: SourceAvailability.unreachable);

      expect(find.bySemanticsLabel('Jellyfin unavailable'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a rejected session asks for a sign-in, not for the network',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester, availability: SourceAvailability.authenticationError);

      expect(find.bySemanticsLabel('Jellyfin sign-in needed'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Jellyfin unavailable'),
        findsNothing,
        reason: 'the server answered — telling the user to check their '
            'connection would send them looking in the wrong place',
      );
      handle.dispose();
    });

    testWidgets('a probe still in flight reads as checking, not as failed',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester, availability: SourceAvailability.checking);

      expect(find.bySemanticsLabel('Checking Jellyfin'), findsOneWidget);
      handle.dispose();
    });
  });

  group('TrackStatusGlyph shows one glyph, never two', () {
    testWidgets('an in-flight download outranks the server state',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(
        tester,
        status: DownloadStatus.queued,
        availability: SourceAvailability.unreachable,
      );

      expect(find.bySemanticsLabel('Queued'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Jellyfin unavailable'),
        findsNothing,
        reason: 'two glyphs for one row is how a calm list turns noisy',
      );
      handle.dispose();
    });
  });

  group('TrackStatusGlyph follows the server without a restart', () {
    testWidgets('the glyph clears when the server answers again',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final ProviderContainer container = await _pump(
        tester,
        availability: SourceAvailability.unreachable,
      );
      expect(find.bySemanticsLabel('Jellyfin unavailable'), findsOneWidget);

      // The probe comes back. Same widget tree, same screen, no re-pump of the
      // app — exactly what walking back onto the home network does.
      container.read(_serverState.notifier).state =
          SourceAvailability.available;
      await tester.pump();

      _expectSilent(tester);
      handle.dispose();
    });

    testWidgets('the glyph appears when the server goes away', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final ProviderContainer container = await _pump(tester);
      _expectSilent(tester);

      container.read(_serverState.notifier).state =
          SourceAvailability.unreachable;
      await tester.pump();

      expect(find.bySemanticsLabel('Jellyfin unavailable'), findsOneWidget);
      handle.dispose();
    });
  });
}
