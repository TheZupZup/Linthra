# Product roadmap

This is the **product direction** for Linthra after v0.1.6 — what we want to build
next and, just as importantly, what we deliberately won't. It is a direction, not
a set of dated promises: Linthra is early alpha, built by a small group, and the
order below can shift as real-device testing tells us what actually matters.

For "where an extra pair of hands helps most right now," see the
[contributor roadmap](./contributor-roadmap.md) — that's the task-level companion
to this higher-level plan.

## North star

> **Linthra works on its own. Linthra Connect is optional.**

Every phase below is held to one rule: Linthra must stay **fully usable** without
any of the following.

- **No Docker.** No server-side component is ever required to use the app.
- **No account.** Nothing to sign up for; nothing phones home.
- **No desktop app.** The phone is complete on its own; Desktop (when it lands)
  is complete on its own too. Neither depends on the other.
- **No pairing code.** Pairing / QR (Linthra Connect, Phase 3) is a convenience
  for moving settings between devices — **optional, never a gate.**

If a feature can only work with a cloud service, a mandatory pairing step, or a
container running somewhere, it doesn't fit Linthra. These are non-negotiables,
not preferences.

## Phase 0 — Finish PR #244 cleanly ✅ done

[PR #244](https://github.com/thezupzup/linthra/pull/244) — *"Fix Android audio
focus: never stay silently ducked"* — is **merged**. It is scoped strictly to
audio focus / session / background-playback recovery, with no
provider/cache/Plex-Jellyfin-Subsonic/Cast-Android-Auto/version/F-Droid/dependency
changes.

- ✅ Battery tradeoff documented (in the PR and in code): keeping the media
  service foreground across a pause holds a `PARTIAL_WAKE_LOCK` only while
  *paused-not-stopped*; active playback and the stopped state are unaffected. See
  [docs/battery.md](./battery.md).
- ✅ CI green — Flutter checks, Build debug APK, and the Secret & privacy scan all
  passed on the merged commit.
- ✅ Real-device acceptance confirmed (text app keeps sound, voice start/stop
  restores, screen lock keeps playing, another app taking focus recovers without
  reopening Linthra).

The one intentional follow-up it left behind — a *battery-optimal* audio-focus
mode that keeps the service alive **only during a transient-focus pause** — rolls
into Phase 1.

## Phase 1 — v0.1.7 stabilization pass

**Goal:** make Linthra feel reliable as a daily-driver music player. Stability
before new features. The output is a *small set of focused PRs*, each
independently reviewable and validated on a real device — not one big change.

Focus areas, with the existing issues they map to:

- **Background playback reliability** — keep the gains from #244 solid across
  Doze, screen-off, and long pauses.
- **Audio-focus regressions** — guard the #244 behaviour with the deterministic
  focus tests already in place, and land the **battery-optimal follow-up** (keep
  `stopForegroundOnPause: true`, hold the service only across a transient-focus
  pause). See [docs/battery.md](./battery.md) → *Possible future work*.
- **Screen-lock playback** — no pause/mute on a brief screen-off focus blip.
- **Android Auto sanity** — real head-unit and Desktop-Head-Unit passes
  ([#82](https://github.com/thezupzup/linthra/issues/82)).
- **Offline cache reliability** — eviction, "keep offline" pinning, and
  Wi-Fi/mobile-data gating behave predictably ([docs/offline-cache.md](./offline-cache.md)).
- **Provider fallback reliability** — building on cached provider-reachability
  (#241), make an offline server fall back fast and correctly; finish
  provider-aware identity so favorites / play history / playlists never collide
  across providers ([#239](https://github.com/thezupzup/linthra/issues/239)).
- **UI polish where bugs are obvious** — empty states
  ([#89](https://github.com/thezupzup/linthra/issues/89)) and accessibility
  labels ([#90](https://github.com/thezupzup/linthra/issues/90)).
- **Streaming resilience on weak networks** — graceful stall/recovery without
  duplicate playback or leaked tokens
  ([#83](https://github.com/thezupzup/linthra/issues/83)).
- **Crash / log diagnostics** — extend the secret-free `StabilityDiagnostics`
  breadcrumbs only where they earn their keep.

**Deliberately out of scope for v0.1.7:** big new features · desktop work ·
Docker / server work · cloud / account work · large architecture rewrites (unless
a rewrite is genuinely required to fix a stability bug). Small issue cleanup only.

## Phase 2 — Backup / Restore without Docker

**Goal:** let users recover their Linthra setup on a new phone without Docker, an
account, or the cloud.

**V1 behaviour:** export a Linthra backup **file** from Android; import it on
another Android device. File export/import is the simplest first step; an optional
QR/code flow can be layered on later (Phase 3) using the *same* file as its
payload.

**What's in V1:** server type (Jellyfin / Navidrome / Subsonic / Plex / local),
server display name and URL, provider priority / default-source preferences, cache
preferences, and UI/app preferences. Favorites/playlists may come later but are
**not** required for V1.

**Security:** no passwords or tokens — V1 **does not export credentials at all**.
After restore, the user re-enters credentials per server. (An encrypted credential
backup is a separate, opt-in design for later.) Because there are no secrets, the
file needs no encryption — but it *does* list your server addresses, so it's
"treat like a bookmark," not "publish publicly."

The format is the deliverable: a small, documented, versioned JSON document that
Android exports/imports today and that **Linthra Desktop (Phase 4)** and **Linthra
Connect (Phase 3)** both understand. Full spec:
**[docs/backup-restore-format.md](./backup-restore-format.md).**

## Phase 3 — Linthra Connect foundation (optional)

**Goal:** an *optional* local pairing/sync concept for phone ↔ desktop. Linthra
must work fully without it — Connect only saves you from typing.

**V1 idea:** the phone shows a temporary pairing code / QR; the desktop
enters/scans it; the devices exchange setup data **locally** (the Phase 2 backup
document is the payload). Pairing can be revoked.

**Security requirements (all mandatory):**

- The code is **temporary**.
- The user must **approve** each pairing.
- A **"disconnect all paired devices"** control exists.
- **No public internet exposure** by default — local exchange only.
- **No mandatory account.**
- Connect only syncs/controls **Linthra** — never full phone control.

**Use cases:** import servers from phone to desktop · restore settings to a new
phone · (later) remote control and queue sync.

This phase is **design-first** — it starts as a design doc (like
[#178](https://github.com/thezupzup/linthra/issues/178) Plex and
[#86](https://github.com/thezupzup/linthra/issues/86) WebDAV did), with the
transport, the pairing handshake, and the approval/revocation model settled on
paper before any code.

## Phase 4 — Linthra Desktop / Windows MVP

**Goal:** Linthra as a real Windows app — **not** a remote for the phone. Desktop
must not depend on a phone being present.

**Normal flow:** install on Windows → add Jellyfin / Navidrome / Subsonic / Plex
servers directly → listen to music on Windows.

**Optional flow:** use a Linthra Connect code/QR (or a Phase 2 backup file) to
import server settings from Android — then re-enter passwords/tokens manually.

**V1 scope:** Windows first · standalone app · add/manage servers · browse/play
music · import settings from an Android backup or Connect if available.

**Avoid in V1:** full multi-device cloud sync · complex conflict resolution ·
mandatory accounts · any Docker dependency · server-side cache/preload.

## Phase 5 — Remote control & sync polish

Only **after** Android and Desktop basics are solid.

**Potential features:** control phone playback from desktop (play/pause/next/prev)
· view now-playing · view/edit the queue · launch playlists/albums from desktop to
phone · optional history/favorites sync · optional backup sync.

## Positioning

Linthra should grow into a **self-hosted music ecosystem** — phone, then desktop,
then optional links between them — **without ever forcing cloud, Docker, or
accounts** on anyone. The single line that keeps every phase honest:

> **Linthra works on its own. Linthra Connect is optional.**
