import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/shared/layout/desktop_presentation.dart';

void main() {
  testWidgets('only desktop platforms present as desktop', (tester) async {
    late bool desktop;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            desktop = usesDesktopPresentation(context);
            return const SizedBox();
          },
        ),
      ),
    );

    expect(
      desktop,
      <TargetPlatform>{
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      }.contains(defaultTargetPlatform),
    );
  }, variant: TargetPlatformVariant.all());

  testWidgets('follows the theme rather than the host', (tester) async {
    late bool desktop;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        home: Builder(
          builder: (BuildContext context) {
            desktop = usesDesktopPresentation(context);
            return const SizedBox();
          },
        ),
      ),
    );

    expect(desktop, isTrue);
  });
}
