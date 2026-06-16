/// # Now Playing preview data
///
/// Hand-written, fake playback states for the dev-only Now Playing preview
/// (`now_playing_preview_main.dart`). They let you see every variation of the
/// screen — different providers, paused / buffering / error states, long titles,
/// missing artwork — **without** connecting Plex, Jellyfin, or Navidrome.
///
/// This file is pure data: it never reaches the network or a real provider. The
/// track URIs (`plex:` / `jellyfin:` / `subsonic:` / a file path) only drive the
/// "Playing from …" label, exactly as they do in the real app.
///
/// Add your own sample by appending a [NowPlayingPreviewSample] to
/// [nowPlayingPreviewSamples].
library;

import '../core/models/playback_source.dart';
import '../core/models/playback_state.dart';
import '../core/models/repeat_mode.dart';
import '../core/models/track.dart';

/// One named sample shown in the preview's picker.
class NowPlayingPreviewSample {
  const NowPlayingPreviewSample({
    required this.name,
    required this.state,
    this.showArtwork = true,
  });

  /// The label shown in the preview's sample picker.
  final String name;

  /// The fake playback state the Now Playing screen renders.
  final PlaybackState state;

  /// Whether the preview should inject a real (bundled) cover so you can see the
  /// blurred-artwork hero and background. Set false to preview the no-artwork
  /// fallback (placeholder cover + brand gradient backdrop).
  final bool showArtwork;
}

// A handful of fake tracks. Artwork is injected by the preview screen (from a
// bundled image) for samples with showArtwork = true, so these stay offline.
const Track _localTrack = Track(
  id: 'preview-local',
  title: 'Midnight Pull',
  uri: '/music/the-violet-hours/midnight_pull.mp3',
  artistName: 'The Violet Hours',
  albumName: 'Afterglow',
  duration: Duration(minutes: 3, seconds: 48),
);

const Track _plexTrack = Track(
  id: 'preview-plex',
  title: 'Paper Lanterns',
  uri: 'plex:60412',
  artistName: 'Harbor & Vine',
  albumName: 'Tideline',
  duration: Duration(minutes: 4, seconds: 5),
);

const Track _jellyfinTrack = Track(
  id: 'preview-jellyfin',
  title: 'Slow Static',
  uri: 'jellyfin:9f3a2b',
  artistName: 'Carrier Wave',
  albumName: 'Low Orbit',
  duration: Duration(minutes: 3, seconds: 21),
);

const Track _subsonicTrack = Track(
  id: 'preview-subsonic',
  title: 'Copper Sky',
  uri: 'subsonic:tr-8841',
  artistName: 'Marisol Reyes',
  albumName: 'Dust & Gold',
  duration: Duration(minutes: 5, seconds: 12),
);

const Track _longTrack = Track(
  id: 'preview-long',
  title:
      'An Almost Unreasonably Long Song Title That Should Wrap and Ellipsize',
  uri: 'jellyfin:long-1',
  artistName: 'A Collective With a Notably Long and Winding Name Ensemble',
  albumName: 'The Deluxe Anniversary Remastered Edition (Bonus Tracks)',
  duration: Duration(minutes: 6, seconds: 2),
);

// A couple of upcoming tracks so the Next button is enabled and the queue sheet
// has something to show.
const List<Track> _upNext = <Track>[
  Track(
    id: 'preview-next-1',
    title: 'Glasswing',
    uri: 'plex:60413',
    artistName: 'Harbor & Vine',
    albumName: 'Tideline',
    duration: Duration(minutes: 3, seconds: 30),
  ),
  Track(
    id: 'preview-next-2',
    title: 'Northbound',
    uri: 'plex:60414',
    artistName: 'Harbor & Vine',
    albumName: 'Tideline',
    duration: Duration(minutes: 4, seconds: 1),
  ),
];

/// The samples shown in the preview, in picker order. Edit, reorder, or extend
/// this list freely — it only affects the dev preview.
const List<NowPlayingPreviewSample> nowPlayingPreviewSamples =
    <NowPlayingPreviewSample>[
  NowPlayingPreviewSample(
    name: 'Playing · Plex',
    state: PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _plexTrack,
      source: PlaybackSource.streamingDirect,
      upNext: _upNext,
      hasPrevious: true,
      position: Duration(minutes: 1, seconds: 12),
      duration: Duration(minutes: 4, seconds: 5),
    ),
  ),
  NowPlayingPreviewSample(
    name: 'Playing · Jellyfin',
    state: PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _jellyfinTrack,
      source: PlaybackSource.streamingDirect,
      upNext: _upNext,
      hasPrevious: true,
      position: Duration(minutes: 0, seconds: 47),
      duration: Duration(minutes: 3, seconds: 21),
    ),
  ),
  NowPlayingPreviewSample(
    name: 'Playing · Navidrome',
    state: PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _subsonicTrack,
      source: PlaybackSource.streamingDirect,
      position: Duration(minutes: 2, seconds: 30),
      duration: Duration(minutes: 5, seconds: 12),
    ),
  ),
  NowPlayingPreviewSample(
    name: 'Playing · Local file',
    state: PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _localTrack,
      source: PlaybackSource.localFile,
      upNext: _upNext,
      hasPrevious: true,
      position: Duration(minutes: 1, seconds: 40),
      duration: Duration(minutes: 3, seconds: 48),
      shuffleEnabled: true,
      repeatMode: RepeatMode.all,
    ),
  ),
  NowPlayingPreviewSample(
    name: 'Playing · Offline cache',
    state: PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _jellyfinTrack,
      source: PlaybackSource.offlineCache,
      position: Duration(minutes: 0, seconds: 18),
      duration: Duration(minutes: 3, seconds: 21),
    ),
  ),
  NowPlayingPreviewSample(
    name: 'Paused',
    state: PlaybackState(
      status: PlaybackStatus.paused,
      currentTrack: _plexTrack,
      source: PlaybackSource.streamingDirect,
      position: Duration(minutes: 1, seconds: 12),
      duration: Duration(minutes: 4, seconds: 5),
    ),
  ),
  NowPlayingPreviewSample(
    name: 'Buffering',
    state: PlaybackState(
      status: PlaybackStatus.buffering,
      currentTrack: _jellyfinTrack,
      source: PlaybackSource.streamingDirect,
      position: Duration(minutes: 0, seconds: 5),
      duration: Duration(minutes: 3, seconds: 21),
    ),
  ),
  NowPlayingPreviewSample(
    name: 'Long title & artist',
    state: PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _longTrack,
      source: PlaybackSource.streamingDirect,
      position: Duration(minutes: 3, seconds: 0),
      duration: Duration(minutes: 6, seconds: 2),
    ),
  ),
  NowPlayingPreviewSample(
    name: 'No artwork',
    showArtwork: false,
    state: PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _localTrack,
      source: PlaybackSource.localFile,
      position: Duration(minutes: 0, seconds: 30),
      duration: Duration(minutes: 3, seconds: 48),
    ),
  ),
  NowPlayingPreviewSample(
    name: 'Error',
    showArtwork: false,
    state: PlaybackState(
      status: PlaybackStatus.error,
      currentTrack: _jellyfinTrack,
      errorMessage: 'Your Jellyfin session has expired.',
    ),
  ),
  NowPlayingPreviewSample(
    name: 'Nothing playing',
    showArtwork: false,
    state: PlaybackState.idle,
  ),
];
