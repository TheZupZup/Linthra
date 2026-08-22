import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/application_lifecycle.dart';
import 'app/linthra_app.dart';
import 'core/models/theme_mode_preference.dart';
import 'data/repositories/theme_mode_store_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Read the saved theme mode before the container exists so the first frame
  // paints in the user's chosen mode.
  final ThemeModePreference storedThemeMode = await readStoredThemeMode();

  final container = ProviderContainer(
    overrides: productionApplicationOverrides(
      storedThemeMode: storedThemeMode,
    ),
  );

  final ApplicationHandle lifecycle = await bootstrapApplication(container);

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: LinthraApp(lifecycle: lifecycle),
    ),
  );
}
