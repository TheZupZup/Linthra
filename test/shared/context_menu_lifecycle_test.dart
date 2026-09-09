import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/shared/widgets/context_menu_region.dart';

/// A menu is a route, so it outlives the surface that opened it (#386).
///
/// Inside the desktop shell that surface can be a pane, and a pane goes away on
/// an ordinary resize. The popup stays up on the navigator, so a pick can land
/// after the row that offered it has been unmounted, and everything the action
/// would reach for (the row's ref, an ancestor to hang a dialog on) has gone
/// with it.
class _Host extends StatefulWidget {
  const _Host({required this.onSelected, super.key});

  final ValueChanged<String> onSelected;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  bool _showRegion = true;

  /// Stands in for the resize that drops the pane.
  void removeRegion() => setState(() => _showRegion = false);

  @override
  Widget build(BuildContext context) {
    if (!_showRegion) return const Center(child: Text('pane gone'));
    return ContextMenuRegion<String>(
      itemBuilder: (BuildContext context) => const <PopupMenuEntry<String>>[
        PopupMenuItem<String>(value: 'a', child: Text('Play next')),
      ],
      onSelected: widget.onSelected,
      child: const SizedBox.expand(child: Center(child: Text('row'))),
    );
  }
}

void main() {
  testWidgets('a pick that lands after the region is gone is dropped',
      (tester) async {
    final List<String> picked = <String>[];
    final GlobalKey<_HostState> key = GlobalKey<_HostState>();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: _Host(key: key, onSelected: picked.add)),
      ),
    );

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.text('row')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('Play next'), findsOneWidget);

    // The window crosses a pane threshold: the row is unmounted, the menu is
    // still up on top of what replaced it.
    key.currentState!.removeRegion();
    await tester.pumpAndSettle();
    expect(find.text('pane gone'), findsOneWidget);
    expect(find.text('Play next'), findsOneWidget);

    await tester.tap(find.text('Play next'));
    await tester.pumpAndSettle();

    // Nothing dispatched into the dead tree, and nothing thrown.
    expect(picked, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a pick on a region that is still there runs as usual',
      (tester) async {
    final List<String> picked = <String>[];

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: _Host(onSelected: picked.add))),
    );

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.text('row')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Play next'));
    await tester.pumpAndSettle();

    expect(picked, <String>['a']);
  });
}
