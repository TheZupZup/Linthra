import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/shared/focus/list_keyboard_navigation.dart';

/// Home, End, and a grid's row wrap (#390): the collection keys Flutter's
/// traversal cannot supply, because in a lazily-built list the far end has no
/// focus node to find until something has scrolled it into range.

String? _focusedLabel() {
  final BuildContext? context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return null;
  final Finder text = find.descendant(
    of: find.byWidget(context.widget),
    matching: find.byType(Text),
  );
  if (text.evaluate().isEmpty) return null;
  return (text.evaluate().first.widget as Text).data;
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  // One frame to scroll, one for the rows the scroll built.
  await tester.pump();
  await tester.pump();
}

Future<void> _pumpList(WidgetTester tester, {int count = 200}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 300,
          child: ListKeyboardNavigation(
            child: ListView.builder(
              itemExtent: 50,
              itemCount: count,
              itemBuilder: (BuildContext context, int index) =>
                  ListTile(title: Text('row $index'), onTap: () {}),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// A 4-wide grid, which is what makes a row break something to walk through.
Future<void> _pumpGrid(WidgetTester tester, {required bool wrapRows}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 300,
          width: 400,
          child: ListKeyboardNavigation(
            wrapRows: wrapRows,
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisExtent: 100,
              ),
              itemCount: 80,
              itemBuilder: (BuildContext context, int index) => InkWell(
                onTap: () {},
                child: Center(child: Text('cell $index')),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('a long list', () {
    testWidgets('End reaches the last row, which was never built',
        (tester) async {
      await _pumpList(tester);
      Focus.of(tester.element(find.text('row 0'))).requestFocus();
      await tester.pump();
      expect(find.text('row 199'), findsNothing);

      await _press(tester, LogicalKeyboardKey.end);

      expect(_focusedLabel(), 'row 199');
    });

    testWidgets('Home comes back to the first', (tester) async {
      await _pumpList(tester);
      Focus.of(tester.element(find.text('row 0'))).requestFocus();
      await tester.pump();
      await _press(tester, LogicalKeyboardKey.end);
      expect(_focusedLabel(), 'row 199');

      await _press(tester, LogicalKeyboardKey.home);

      expect(_focusedLabel(), 'row 0');
    });

    testWidgets('the arrow keys still walk it row by row', (tester) async {
      await _pumpList(tester);
      Focus.of(tester.element(find.text('row 0'))).requestFocus();
      await tester.pump();

      for (int i = 0; i < 12; i++) {
        await _press(tester, LogicalKeyboardKey.arrowDown);
      }

      expect(_focusedLabel(), 'row 12');
    });
  });

  group('a grid', () {
    testWidgets('→ carries on into the next row', (tester) async {
      await _pumpGrid(tester, wrapRows: true);
      Focus.of(tester.element(find.text('cell 3'))).requestFocus();
      await tester.pump();

      await _press(tester, LogicalKeyboardKey.arrowRight);

      expect(_focusedLabel(), 'cell 4');
    });

    testWidgets('← comes back over the same break', (tester) async {
      await _pumpGrid(tester, wrapRows: true);
      Focus.of(tester.element(find.text('cell 4'))).requestFocus();
      await tester.pump();

      await _press(tester, LogicalKeyboardKey.arrowLeft);

      expect(_focusedLabel(), 'cell 3');
    });

    testWidgets('→ inside a row is still the plain move', (tester) async {
      await _pumpGrid(tester, wrapRows: true);
      Focus.of(tester.element(find.text('cell 1'))).requestFocus();
      await tester.pump();

      await _press(tester, LogicalKeyboardKey.arrowRight);

      expect(_focusedLabel(), 'cell 2');
    });

    testWidgets('a column of rows does not wrap', (tester) async {
      await _pumpGrid(tester, wrapRows: false);
      Focus.of(tester.element(find.text('cell 3'))).requestFocus();
      await tester.pump();

      await _press(tester, LogicalKeyboardKey.arrowRight);

      expect(_focusedLabel(), 'cell 3');
    });
  });

  testWidgets('typing keeps Home and End', (tester) async {
    // Home/End only mean "start/end of line" on the desktop bindings, which is
    // the case this guard exists for.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final TextEditingController controller = TextEditingController(
      text: 'hello',
    );
    addTearDown(controller.dispose);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListKeyboardNavigation(
              child: ListView(
                children: <Widget>[
                  TextField(controller: controller),
                  for (int i = 0; i < 40; i++)
                    ListTile(title: Text('row $i'), onTap: () {}),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      controller.selection = const TextSelection.collapsed(offset: 5);

      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pumpAndSettle();

      // Start of the line, not the top of the list: a search box inside a list
      // is still a text field first.
      expect(controller.selection.baseOffset, 0);
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<EditableText>(),
        isNotNull,
        reason: 'the keyboard never left the field',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
