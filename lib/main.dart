import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/sonara_app.dart';
import 'data/repositories/music_library_repository_provider.dart';

void main() {
  // ProviderScope hosts all Riverpod state for the app. The running app
  // persists its catalog to SQLite via the Drift override; tests keep the
  // in-memory default unless they opt into the Drift binding.
  runApp(
    ProviderScope(
      overrides: [driftMusicLibraryRepositoryOverride],
      child: const SonaraApp(),
    ),
  );
}
