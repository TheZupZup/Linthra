import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/application_lifecycle.dart';
import 'app/linthra_app.dart';
import 'core/app_info.dart';
import 'core/models/desktop_density.dart';
import 'core/models/theme_mode_preference.dart';
import 'data/repositories/desktop_density_store_provider.dart';
import 'data/repositories/theme_mode_store_provider.dart';

Future<void> main(List<String> arguments) async {
  // `linthra --version` on Linux, where the runner forwards its argv to this
  // entrypoint. Answered from the compiled [AppInfo.version], which is the
  // only copy of the version the shipped bundle carries, so the reply can
  // never be a manifest's claim about a build rather than the build itself —
  // that is what makes it worth asking an *installed* package
  // (scripts/flatpak_launch_smoke.sh does exactly that).
  //
  // Handled before any bootstrap, so it starts no database, socket or media
  // session. The runner shows its window only on Flutter's first frame
  // (linux/runner/my_application.cc), and this returns long before one, so
  // nothing appears on screen. Other platforms pass no entrypoint arguments,
  // so Android never takes this path.
  if (AppInfo.isVersionQuery(arguments)) {
    stdout.writeln(AppInfo.versionLine);
    // `exit` does not drain a buffered stdout on its own, and a version that
    // is printed but never flushed is the same as one never printed.
    await stdout.flush();
    exit(0);
  }

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
