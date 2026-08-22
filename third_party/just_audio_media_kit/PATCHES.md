# Patched `just_audio_media_kit` 2.1.0

Upstream: https://pub.dev/packages/just_audio_media_kit/versions/2.1.0

## Why

Headless Linux CI has no PipeWire/Pulse audio device. libmpv autoselects
PipeWire on Ubuntu and fails to open the WAV even when `ALSA_CONFIG_PATH`
points the default PCM at the null plugin. The smoke test needs to set
`ao=alsa` on each libmpv instance before playback starts.

Upstream exposes `setProperty` internally but no public hook for extra mpv
options at player creation (unlike `prefetchPlaylist`).

## Changes

1. `JustAudioMediaKit.mpvProperties` — optional map, default empty.
2. `MediaKitPlayer` applies each entry via `setProperty` after `Player()`
   construction (same timing as `prefetch-playlist`).

Production leaves `mpvProperties` empty; only `tool/linux_audio_backend_smoke.dart`
sets `{ 'ao': 'alsa' }`.
