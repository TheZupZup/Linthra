import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the app's UI is on screen right now.
///
/// This exists for battery, not for UI: while music plays with the screen off,
/// `audio_service` deliberately keeps the process (and the Flutter isolate)
/// alive, so a timer that only refreshes something *nobody can see* keeps
/// firing for the whole session — waking the CPU, and on a poll like the server
/// availability probe the cellular radio too. Background work that exists to
/// keep the visible UI honest gates on this and stands down while hidden; the
/// app-resume path re-runs it the moment the user comes back. See
/// `docs/features/battery.md`.
///
/// It says nothing about playback: audio keeps playing exactly as before while
/// this is `false`. Nothing that affects sound, the media session, or a
/// download may read it.
///
/// Defaults to visible, so a host that never reports a lifecycle transition
/// (tests, a platform without the observer) behaves exactly as it did before
/// this existed.
class AppVisibility extends Notifier<bool> {
  @override
  bool build() => true;

  /// The app became visible (`resumed`).
  void onShown() => _set(true);

  /// The app is no longer on screen (`paused` / `hidden`). A brief `inactive`
  /// — a permission dialog, a notification shade pull — is deliberately *not*
  /// hidden: it is over in a moment, and standing down for it would cost more
  /// than it saves.
  void onHidden() => _set(false);

  void _set(bool visible) {
    if (state != visible) state = visible;
  }
}

/// The live "is the UI on screen?" signal, published by the root app widget's
/// lifecycle observer.
final appVisibilityProvider = NotifierProvider<AppVisibility, bool>(
  AppVisibility.new,
);
