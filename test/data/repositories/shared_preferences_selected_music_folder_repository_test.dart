import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/shared_preferences_selected_music_folder_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('SharedPreferencesSelectedMusicFolderRepository', () {
    const repository = SharedPreferencesSelectedMusicFolderRepository();

    test('reads nothing when no folder has ever been selected', () async {
      expect(await repository.getSelectedFolders(), isEmpty);
    });

    test('round-trips several folders in order', () async {
      await repository.setSelectedFolders(<String>['/music', '/media/usb']);

      expect(
        await const SharedPreferencesSelectedMusicFolderRepository()
            .getSelectedFolders(),
        <String>['/music', '/media/usb'],
      );
    });

    test('an existing single-folder user keeps their folder', () async {
      // What a build before multi-folder support left behind.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'selected_music_folder': '/home/me/Music',
      });

      expect(
        await repository.getSelectedFolders(),
        <String>['/home/me/Music'],
      );
    });

    test('the single-folder key keeps working after an upgrade', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'selected_music_folder': '/home/me/Music',
      });

      await repository.setSelectedFolders(<String>['/home/me/Music', '/usb']);

      // Downgrading to a single-folder build must not land on an empty
      // library, so the old key still names the first folder.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('selected_music_folder'), '/home/me/Music');
    });

    test('the list wins once it has been written', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'selected_music_folder': '/stale',
        'selected_music_folders': <String>['/music', '/usb'],
      });

      expect(
        await repository.getSelectedFolders(),
        <String>['/music', '/usb'],
      );
    });

    test('clearing forgets both the list and the legacy folder', () async {
      await repository.setSelectedFolders(<String>['/music', '/usb']);

      await repository.clearSelectedFolders();

      final prefs = await SharedPreferences.getInstance();
      expect(await repository.getSelectedFolders(), isEmpty);
      expect(prefs.getString('selected_music_folder'), isNull);
      expect(prefs.getStringList('selected_music_folders'), isNull);
    });

    test('setting an empty selection clears rather than storing nothing',
        () async {
      await repository.setSelectedFolders(<String>['/music']);

      await repository.setSelectedFolders(<String>[]);

      expect(await repository.getSelectedFolders(), isEmpty);
    });
  });
}
