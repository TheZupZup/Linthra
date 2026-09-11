# Offline cache & downloads

Linthra's offline model is **explicit and user-controlled** — Plexamp-style,
open-source, with no surprise downloads. This page covers the network policy
(Wi-Fi vs. mobile data), the cache size limit, and smart pre-cache.

## Wi-Fi only by default

Out of the box Linthra downloads and pre-caches **only on Wi-Fi**. If you start
a download (or smart pre-cache wants to warm a track) while on mobile data, it
**waits** instead of spending your data — the track is queued, and the UI shows
a friendly reason rather than failing silently:

> Downloads are limited to Wi-Fi. Turn on "Allow mobile data" in Settings to
> download over mobile data.

When you're fully offline, a requested download is queued until a connection
returns:

> You're offline. This download will start automatically when you're back
> online.

Local (on-device) tracks are never affected by the network policy — they're
already on disk, so "Keep offline" records them immediately.

## Allowing mobile data

To let downloads and smart pre-cache run over mobile data/LTE:

1. Open **Settings → Downloads & network** (the same toggle is also on the
   **Downloads** tab).
2. Turn on **Allow mobile data for downloads**.
3. Confirm the prompt:

   > **Use mobile data for downloads?**
   > Caching music over mobile data may use a lot of data depending on your
   > library and cache settings.

   Choose **Allow mobile data** to opt in, or **Cancel** to stay Wi-Fi-only.

The setting is persisted across restarts. Turning it back off applies
immediately (no confirmation needed); in-flight downloads on mobile data stop
queueing for Wi-Fi again.

> ⚠️ **Mobile data can be expensive.** With this on, manual downloads and smart
> pre-cache may use a lot of cellular data depending on your library size and
> cache limit. The cache **size limit still applies**, and Linthra never
> downloads your whole library automatically.

### Network policy at a glance

| Connection | Allow mobile data **off** (default) | Allow mobile data **on** |
| ---------- | ----------------------------------- | ------------------------ |
| Wi-Fi      | Download                            | Download                 |
| Mobile     | Queue (wait for Wi-Fi)              | Download                 |
| Offline    | Queue (wait for a connection)       | Queue (wait)             |
| Unknown    | Queue (treated conservatively)      | Download                 |

An **unknown** connection type is treated like mobile data: it downloads only
when you've allowed mobile data, so an undetermined link is never assumed to be
unmetered.

## Cache size limit always applies

A configurable **size limit** (4 GB by default; presets up to 16 GB, or a
custom value) keeps the cache from filling your phone. Allowing mobile data
**never** raises or bypasses this limit. When the cache is full, Linthra evicts,
in order:

1. **Smart pre-cached** tracks (automatic, evictable) first.
2. Then **least-recently-played, unpinned** downloads.

It never evicts a track you **pinned** with "Keep offline", and never the track
playing right now. If a new download still won't fit, it's refused with a
friendly "not enough cache space" message instead of deleting something you
wanted.

## Downloading a whole album or playlist

Open an album or a playlist and use **Download all** (the download button in an
album's app bar, or **Download all** in a playlist's menu). It is offered only
where you have one specific album or playlist open. There is deliberately **no
"download my whole library" button anywhere**.

It always asks first, naming the exact number of songs, and starts nothing until
you confirm. From there it is the same download path a single track takes, so
everything above still holds:

- The **Wi-Fi / mobile-data policy** applies per track. On a Wi-Fi-only device
  the songs are queued, and you get the same friendly explanation a single
  queued track gives.
- The **cache size limit** applies. A song the cache cannot fit is skipped and
  named in the summary, and the batch carries on (one oversized track should not
  cost you the rest of the album). If several in a row will not fit, the cache
  really is out of room, so the batch stops there and says so rather than
  downloading more songs it would have to throw away.
- **Pinned ("Keep offline") tracks are never evicted** to make room, exactly as
  before.
- Songs you **already** have offline are skipped, not re-downloaded, so asking
  for an album again costs nothing and cannot disturb the copies you have.
- A song listed twice in a playlist is downloaded once.
- **On-device songs are left alone.** In a mixed playlist, files already on your
  device are not part of the batch: their bytes are already there, and their
  rows offer no offline action for the same reason.
- If you are **offline**, the songs are queued and you start them again from the
  **Downloads** screen once you are back online. Nothing retries on its own.

While a batch runs, the **Downloads** screen shows which album or playlist it is
and how far along it is, with a **Stop** button. Stopping is safe: nothing is
deleted, the songs already downloaded stay downloaded, and only the handful of
requests already in flight finish. Individual songs can still be cancelled or
retried per row, as always.

## Smart pre-cache follows the same policy

Smart pre-cache warms a small number of **upcoming** queued tracks (1, 3, 5, 10,
20, or 50 — or a custom value up to 200 — configurable in **Settings → Smart
pre-cache**, default 3) so the next songs start instantly and play offline. It
is deliberately modest and **never downloads the whole library**. It follows the
**same mobile-data policy** as manual downloads: on Wi-Fi always, on mobile data
only when you've allowed it, and never offline. Pre-cache is best-effort — when the connection isn't allowed
it simply skips (it doesn't queue), and pre-cached tracks are the first to be
evicted under the cache limit.

A pre-cached track is **not** the same thing as a download, and the library rows
say so: a copy the user asked for reads as **Downloaded**, while one the app
prefetched ahead of play reads as **Cached for offline play**. The distinction is
the one already recorded on the entry itself (`CachedTrack.preloaded`), and it
matters because only the first is a promise — a pre-cached copy can be evicted
under the cache limit at any time. When the server is away, either kind of copy
reads as **Playing from offline copy**, because at that point the copy is the
only reason the row still plays. See
[library.md § Track status in the library](./library.md#track-status-in-the-library).

## Security & privacy

- Track URIs and cache metadata carry only a non-secret track id, an id-derived
  file name, the source's URI scheme, a byte size, timestamps, and the pinned
  flag — **never a Jellyfin token or an authenticated URL**.
- The credential-bearing download URL is minted only at fetch time inside the
  source's downloader; the repository never sees, stores, or logs it.
- Network-policy and "cache full" messages are friendly and **secret-free** —
  they never include a URL, token, or file path, so the UI shows them verbatim.

## Manual Android checklist

1. Disable Wi-Fi and use LTE/mobile data.
2. With **Allow mobile data** off, try downloading a Jellyfin track.
3. Confirm the friendly "limited to Wi-Fi" message and a **queued** state.
4. Enable **Allow mobile data** in Settings and confirm the dialog.
5. Try downloading again.
6. Confirm the download/cache works over LTE.
7. Enable smart pre-cache and confirm it follows the same setting.
8. Confirm the cache size limit still applies (downloads evict, never overflow).
9. Turn **Allow mobile data** back off and confirm LTE downloads queue again.
