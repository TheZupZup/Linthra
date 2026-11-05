import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/playlists/widgets/create_playlist_dialog.dart';

void main() {
  testWidgets('rename dialog allows clearing a description', (
    WidgetTester tester,
  ) async {
    PlaylistEdit? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              return TextButton(
                onPressed: () async {
                  result = await showRenamePlaylistDialog(
                    context,
                    initialName: 'My Music',
                    initialDescription: 'Old description',
                  );
                },
                child: const Text('Rename'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Description (optional)'),
      '',
    );

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.name, 'My Music');
    expect(result!.description, '');
  });
}
