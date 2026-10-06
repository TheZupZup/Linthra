// One field of one saved track that can't be read must not cost the queue.
//
// `PersistedPlaybackSession.fromJson` promises that invalid individual tracks
// are dropped and the rest restored. But an artist, album or album id of
// another type than a string (a damaged or hand-edited record, or one from
// another build) threw out of the whole decode. Restore took that for a
// record it couldn't read and cleared it: the whole saved queue was gone at
// the next launch, the tracks that read fine with it.
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/persisted_playback_session.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playback_session_persistence.dart';
import 'package:linthra/data/repositories/shared_preferences_playback_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/player/fake_playback_controller.dart';

/// Two local tracks, the current one second, three minutes in; the second
/// carries an artist that isn't a string.
const String _document = '{"v":1,"i":1,"p":180000,"t":['
    '{"id":"/music/Holocene.flac","title":"Holocene",'
    '"uri":"/music/Holocene.flac","artist":"Bon Iver","durationMs":336000},'
    '{"id":"/music/Calgary.flac","title":"Calgary",'
    '"uri":"/music/Calgary.flac","artist":5,"album":["Bon Iver"],'
    '"durationMs":250000}'
    ']}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      SharedPreferencesPlaybackSessionStore.key: _document,
    });
  });

  test('the store reads the session, leaving out what it cannot read',
      () async {
    final PersistedPlaybackSession? session =
        await const SharedPreferencesPlaybackSessionStore().load();

    expect(session?.tracks.map((Track t) => t.uri), <String>[
      '/music/Holocene.flac',
      '/music/Calgary.flac',
    ]);
    expect(session?.current?.uri, '/music/Calgary.flac');
    expect(session?.current?.artistName, isNull);
    expect(session?.position, const Duration(minutes: 3));
  });

  test('restore brings the queue back and keeps the record', () async {
    final FakePlaybackController controller = FakePlaybackController();
    final PlaybackSessionPersistence persistence = PlaybackSessionPersistence(
      store: const SharedPreferencesPlaybackSessionStore(),
      controller: controller,
      playbackStates: const Stream<PlaybackState>.empty(),
      localFileExists: (_) => true,
    );
    addTearDown(controller.dispose);
    addTearDown(persistence.dispose);

    await persistence.restore();

    expect(controller.restoreSessionCount, 1);
    expect(controller.state.currentTrack?.uri, '/music/Calgary.flac');
    expect(controller.state.previous.map((Track t) => t.uri),
        <String>['/music/Holocene.flac']);
    expect(
      await const SharedPreferencesPlaybackSessionStore().load(),
      isNotNull,
      reason: 'the saved queue was cleared',
    );
  });
}
