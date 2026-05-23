import '../../core/models/track.dart';

/// Where the Library screen is in its load lifecycle.
enum LibraryStatus { loading, loaded, error }

/// Immutable snapshot the [LibraryScreen] renders from.
///
/// The screen never reaches into the repository directly — it reads this
/// state and the controller is the only thing that mutates it.
class LibraryState {
  const LibraryState({
    required this.status,
    this.tracks = const <Track>[],
    this.errorMessage,
  });

  const LibraryState.loading() : this(status: LibraryStatus.loading);

  const LibraryState.loaded(List<Track> tracks)
      : this(status: LibraryStatus.loaded, tracks: tracks);

  const LibraryState.error(String message)
      : this(status: LibraryStatus.error, errorMessage: message);

  final LibraryStatus status;
  final List<Track> tracks;
  final String? errorMessage;

  /// True only once a load has succeeded but returned no tracks, so the screen
  /// can distinguish "nothing here" from "still loading".
  bool get isEmpty => status == LibraryStatus.loaded && tracks.isEmpty;
}
