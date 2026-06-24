# Contributor roadmap

This is a map of where help is genuinely useful right now — not a corporate
roadmap or a promise of dates. Linthra is early alpha, built by a small group of
people who care about owning their music. Pick whatever looks fun; small
contributions are welcome and land fast.

For the higher-level product direction — the phased plan from the v0.1.7
stabilization pass through Backup/Restore, the optional Linthra Connect, and
Linthra Desktop — see the [product roadmap](./roadmap.md). This page is its
task-level companion.

New to the project? Start with [CONTRIBUTING.md](../CONTRIBUTING.md) for setup,
then come back here to find something to work on.

## Testing

Real-world testing is the single most valuable thing right now, and most of it
needs no code. File a report (there are issue templates for each) with what you
ran and what happened:

- **Jellyfin** — different versions, reverse proxies, Cloudflare Tunnels, big
  vs. small libraries. ([#79](https://github.com/thezupzup/linthra/issues/79))
- **Navidrome / Subsonic** — Navidrome and other Subsonic-compatible servers.
  ([#80](https://github.com/thezupzup/linthra/issues/80))
- **Cast devices** — speakers, TVs, displays. Watch for duplicate local + Cast
  playback. ([#81](https://github.com/thezupzup/linthra/issues/81))
- **Android Auto** — real head units and the Desktop Head Unit.
  ([#82](https://github.com/thezupzup/linthra/issues/82))
- **Different Android versions** — especially Android 13+ where the runtime
  notification permission applies.

Reminder: no tokens, passwords, or full private server URLs in reports — a
version number and a description are plenty.

## Documentation

- **More screenshots** — the core set is committed
  ([#77](https://github.com/thezupzup/linthra/issues/77)); still useful are
  Downloads with tracks downloaded, Android Auto, Cast, or a tablet layout, plus
  a short demo GIF/video ([#91](https://github.com/thezupzup/linthra/issues/91)).
- **Install & setup guides** — make first-run smoother for newcomers.
- **Troubleshooting** — capture the gotchas you hit so the next person doesn't.
- **Bug-report docs** — help testers write clear, secret-free reports
  ([#78](https://github.com/thezupzup/linthra/issues/78)).

## UI / UX

- **Empty states** — blank screens that explain what to do next
  ([#89](https://github.com/thezupzup/linthra/issues/89)).
- **Accessibility** — clearer screen-reader labels and TalkBack support
  ([#90](https://github.com/thezupzup/linthra/issues/90)).
- **Library polish** — browsing, sorting, and search refinements.
- **Now Playing polish** — small touches on the most-used screen.

## Providers

Sources sit behind one `MusicSource` interface, so new backends slot in without
touching the rest of the app.

- **WebDAV / NAS** — research and design first, then implementation
  ([#86](https://github.com/thezupzup/linthra/issues/86)).
- **Future self-hosted sources** — ideas welcome if they fit the streaming-first,
  secret-safe model.

## Playback

- **Streaming resilience** — graceful recovery on weak networks, without
  duplicate playback or leaked tokens
  ([#83](https://github.com/thezupzup/linthra/issues/83)).
- **Queue polish** — reordering, "play next", and saving the queue.
- **ReplayGain / volume normalization** — a later, nice-to-have refinement.

## Release readiness

These are honest checklists, not claims that Linthra is on any store yet.

- **F-Droid prep** — metadata, license/dependency audit, reproducible build
  notes ([#87](https://github.com/thezupzup/linthra/issues/87)).
- **Play Store closed-testing prep** — data safety, signing, screenshots,
  testing group ([#88](https://github.com/thezupzup/linthra/issues/88)).

## Suggested issue labels

If you maintain or triage issues, these labels keep things easy to navigate.
Most map directly to the areas above:

| Label | For |
| --- | --- |
| `good first issue` | Scoped, approachable, light on context |
| `help wanted` | Where an extra pair of hands would help most |
| `testing` | Compatibility and real-hardware reports |
| `documentation` | Docs, guides, screenshots |
| `ui-polish` | Visual and interaction refinements |
| `accessibility` | Screen-reader and TalkBack work |
| `jellyfin` | Jellyfin-specific |
| `navidrome` | Navidrome / Subsonic-specific |
| `cast` | Chromecast / Cast |
| `android-auto` | Android Auto / head units |
| `playback` | Streaming, queue, audio behaviour |
| `privacy` | Secrets, permissions, data handling |
| `f-droid` | F-Droid readiness |
| `play-store` | Google Play readiness |

Don't see your idea here? Open an issue anyway — this list isn't exhaustive, and
fresh perspectives are how the roadmap grows.
