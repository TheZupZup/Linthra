import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/application_lifecycle.dart';
import 'app/linthra_app.dart';
import 'core/models/desktop_density.dart';
import 'core/models/theme_mode_preference.dart';
import 'data/repositories/desktop_density_store_provider.dart';
import 'data/repositories/theme_mode_store_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Read the saved theme mode before the container exists so the first frame
  // paints in the user's chosen mode.
  final ThemeModePreference storedThemeMode = await readStoredThemeMode();

  // Same reason, one frame later would be one relayout too many: density
  // decides every row height, so it is resolved before the first frame too.
  final DesktopDensity storedDesktopDensity = await readStoredDesktopDensity();

  // One container backs the whole app so the *same* PlaybackController and
  // MusicLibraryRepository instances drive both the UI (through providers) and
  // the platform media session: Android Auto browses the real catalog and the
  // notification / lock screen reflect the real controller. The production
  // bindings it applies — the Drift catalog, the shared_preferences stores, the
  // encrypted session storage, the real downloader/share/lyrics/cast services —
  // each carry their reasoning in [productionApplicationOverrides]. Tests keep
  // the in-memory defaults unless they opt into these bindings.
  final container = ProviderContainer(
    overrides: productionApplicationOverrides(
      storedThemeMode: storedThemeMode,
      storedDesktopDensity: storedDesktopDensity,
    ),
  );

  // Everything `main` used to do inline between the container and `runApp`:
  // attaching the media session, starting the side-effect services, warming the
  // persisted sessions, and installing the global artwork hooks. The handle it
  // returns owns all of it, and shutting it down releases all of it.
  //
  // A bootstrap that fails has already released whatever it managed to create
  // (see [bootstrapApplication]) and rethrows, so the app never reaches `runApp`
  // half-initialized — and never leaves a database or socket behind either.
  final ApplicationHandle lifecycle = await bootstrapApplication(container);

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: LinthraApp(lifecycle: lifecycle),
    ),
  );
}
