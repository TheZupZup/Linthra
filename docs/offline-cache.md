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

## Smart pre-cache follows the same policy

Smart pre-cache warms a small, fixed number of **upcoming** queued tracks (1, 3,
5, or 10 — configurable in **Settings → Smart pre-cache**) so the next songs
start instantly and play offline. It is deliberately modest and **never
downloads the whole library**. It follows the **same mobile-data policy** as
manual downloads: on Wi-Fi always, on mobile data only when you've allowed it,
and never offline. Pre-cache is best-effort — when the connection isn't allowed
it simply skips (it doesn't queue), and pre-cached tracks are the first to be
evicted under the cache limit.

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
