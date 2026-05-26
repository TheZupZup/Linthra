# Reporting a bug

Linthra can build a high-quality, **secret-free** bug report entirely on your
device, so a problem can be described precisely without leaking anything
sensitive. This page explains the flow, what the report contains, and the
privacy guarantees behind it.

> **Nothing is sent automatically.** The report is generated locally and shown
> to you for review. Linthra has **no backend**, uses **no GitHub token**, and
> **never** uploads your data to Claude/OpenAI/Anthropic or any third‑party or
> AI service. Every share action is an explicit tap you take.

## How to use it

1. Open **Settings → Report a bug**.
2. Fill in the short fields (summary, what happened, steps, expected) — all
   optional; blanks become neutral placeholders.
3. Choose what to include with the toggles (see [below](#what-you-can-toggle)).
4. **Review the live preview.** It is exactly what will be copied, saved, or
   prefilled.
5. Pick an action:
   - **Copy bug report** — puts the Markdown on your clipboard.
   - **Share bug report** — copies it so you can paste it into email, chat, or an
     issue. _(A native share sheet may be added later; today this copies.)_
   - **Open GitHub issue** — opens your browser at a **prefilled but
     unsubmitted** [new issue](https://github.com/thezupzup/linthra/issues/new).
     You review and submit it yourself.
   - **Save report file** — writes `linthra-bug-report.md` into the app's private
     documents directory.

## Report format

The report is Markdown so it pastes cleanly into a GitHub issue:

```markdown
# Linthra bug report

## Summary
…

## What happened
…

## Steps to reproduce
1.
2.
3.

## Expected behavior
…

## Diagnostics
```text
Linthra diagnostics
App version: …
Jellyfin: connected
Jellyfin host: music.example.com
…
```

## Recent app events   ← only when you opt in
```text
lifecycle: resumed
output: cast
error: load
```
```

## What you can toggle

- **Include playback state** — the current output, status, and a non‑reversible
  hashed tag of the playing track's id (never the id, title, or URL).
- **Include cache state** — how much offline cache is used of your limit.
- **Include recent app events** — the last few structural breadcrumbs the app
  records in memory (lifecycle transitions, playback‑output handoffs, pre‑cache
  decisions, and error *kinds*). Useful for diagnosing freezes/ANRs.

## Why it is secret‑free

The diagnostics block reuses the same builder as **Settings → Diagnostics**
([`AppDiagnostics`](../lib/core/diagnostics/app_diagnostics.dart)), which is
secret‑free *by construction*:

- Server addresses are always reduced to **host[:port]** (`hostOnly`), so a full
  authenticated URL can never carry a token, an `api_key` query, or a
  `user:pass@` prefix into the report.
- The "last error" is a stable **enum name**, never a raw error string (which
  could contain a tokenized URL or a path).
- The current track is a **hash tag** (e.g. `id#1a2b3c`), never the id/title/URL.
- File paths shown after **Save** are reduced to a basename behind a `…/` marker.

The **recent app events** come from
[`SafeEventLog`](../lib/core/diagnostics/safe_event_log.dart), a bounded,
in‑memory ring buffer fed by
[`StabilityDiagnostics`](../lib/core/services/stability_diagnostics.dart). Each
entry is only a fixed label (an output name, a lifecycle state, an error kind) —
there is no field for a token, password, URL, track title, or path. The buffer
is never written to disk and is cleared when the process ends.

Even so: **review the preview before sharing.** Anything *you* type into the
free‑text fields is your responsibility — don't paste secrets there.

## The "fix it with an agent" idea (you drive it)

A natural next step is to paste a report into Claude or another coding agent to
get a fix faster. That is a great workflow — **and it stays entirely in your
hands.** Linthra will never do this for you or in the background: it does not
contact any AI service, and it has no automatic upload of any kind. If you want
an agent to look at a bug, *you* copy the report and *you* paste it where you
choose.

## See also

- [docs/dependency-license-audit.md §7 (Reporting a bug)](./dependency-license-audit.md#reporting-a-bug-browser-hand-off-no-auto-send)
  — why `url_launcher` is the only added dependency and how it stays F‑Droid‑clean.
- [docs/privacy-policy.md](./privacy-policy.md) — the overall privacy posture.
- The GitHub issue forms under [`.github/ISSUE_TEMPLATE`](../.github/ISSUE_TEMPLATE)
  — used when you open an issue directly on the website.
