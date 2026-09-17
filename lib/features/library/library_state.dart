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
    this.localRootsUnreadable = false,
  });

  const LibraryState.loading() : this(status: LibraryStatus.loading);

  const LibraryState.loaded(List<Track> tracks)
      : this(status: LibraryStatus.loaded, tracks: tracks);

  const LibraryState.error(String message, {bool localRootsUnreadable = false})
      : this(
          status: LibraryStatus.error,
          errorMessage: message,
          localRootsUnreadable: localRootsUnreadable,
        );

  final LibraryStatus status;
  final List<Track> tracks;
  final String? errorMessage;

  /// Whether *this* failure is a local folder that could not be read.
  ///
  /// Set only by the scan that diagnosed it, so the screen can offer that
  /// folder's own recovery instead of a generic retry. Everything else leaves
  /// it false, including a catalog that will not load while a drive happens to
  /// be out somewhere else in the library: that error is not the folder's, and
  /// answering it with "reconnect the drive" would bury it.
  final bool localRootsUnreadable;

  /// True only once a load has succeeded but returned no tracks, so the screen
  /// can distinguish "nothing here" from "still loading".
  bool get isEmpty => status == LibraryStatus.loaded && tracks.isEmpty;
}
