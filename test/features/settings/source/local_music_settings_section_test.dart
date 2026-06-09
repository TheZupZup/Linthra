import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/settings/source/local_music_settings_section.dart';

Future<void> _pump(
  WidgetTester tester, {
  String? initialFolder,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        selectedMusicFolderRepositoryProvider.overrideWithValue(
          InMemorySelectedMusicFolderRepository(initialFolder: initialFolder),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: LocalMusicSettingsSection()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('LocalMusicSettingsSection', () {
    testWidgets('with no folder, invites the user to select one',
        (tester) async {
      await _pump(tester);

      expect(find.text('Local music'), findsOneWidget);
      expect(find.text('No folder selected yet.'), findsOneWidget);
      expect(find.text('Select a folder'), findsOneWidget);
      // No rescan/forget actions until a folder exists.
      expect(find.text('Rescan'), findsNothing);
      expect(find.text('Forget folder'), findsNothing);
    });

    testWidgets('with a SAF folder, shows a friendly label and the actions',
        (tester) async {
      await _pump(
        tester,
        initialFolder: 'content://com.android.externalstorage.documents/tree/'
            'primary%3AMusic%2Fmusi5',
      );

      // The opaque content:// URI is reduced to a recognizable folder label.
      expect(find.text('primary:Music/musi5'), findsOneWidget);
      expect(find.text('Rescan'), findsOneWidget);
      expect(find.text('Change'), findsOneWidget);
      expect(find.text('Forget folder'), findsOneWidget);
    });
  });
}
