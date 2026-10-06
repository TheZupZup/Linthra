// One play-history entry that can't be read must not cost the rest.
//
// A last-played time outside DateTime's range (a damaged or hand-edited
// entry, or one from another build) threw out of the whole load. The
// repository then never loaded: every completed play was dropped without a
// word, on every launch, and Recently played / Most played had nothing.
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/play_history.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/default_play_history_repository.dart';
import 'package:linthra/data/repositories/shared_preferences_play_history_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _key = 'play_history_v1';

/// Played three times, as the app writes it, beside an entry whose time is
/// past the end of DateTime's range.
const String _document = '{'
    '"/music/Holocene.flac":{"c":3,"t":1700000000000},'
    '"/music/Calgary.flac":{"c":1,"t":9000000000000000}'
    '}';

const Track _holocene = Track(
  id: '/music/Holocene.flac',
  title: 'Holocene',
  uri: '/music/Holocene.flac',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{_key: _document});
  });

  test('the store reads the entries it can', () async {
    final PlayHistory loaded =
        await const SharedPreferencesPlayHistoryStore().load();

    expect(loaded.playCountFor('/music/Holocene.flac'), 3);
  });

  test('a completed play is still counted, and saved', () async {
    final DefaultPlayHistoryRepository repository =
        DefaultPlayHistoryRepository(
      store: const SharedPreferencesPlayHistoryStore(),
      now: () => DateTime(2026, 10, 6),
    );
    addTearDown(repository.dispose);

    await repository.recordCompletion(_holocene);

    expect(repository.current.playCountFor(_holocene.uri), 4);
    SharedPreferences.resetStatic();
    final PlayHistory relaunched =
        await const SharedPreferencesPlayHistoryStore().load();
    expect(relaunched.playCountFor(_holocene.uri), 4);
  });
}
