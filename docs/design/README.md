# Design

Designs for work that is not shipped yet. Each page says what would have to
be true, and how it would be built, before the feature lands. What already
ships is described in [features](../features/README.md).

## Bringing casting back

Casting is switched off in shipped builds while a reported security issue is
resolved (see [Cast](../features/cast.md)). These pages are the plan for
turning it back on safely.

| Document | What it covers |
| --- | --- |
| [Receiver trust](cast-receiver-trust.md) | What has to be true before casting comes back |
| [Hardened design](cast-hardened.md) | How casting could work again |
| [Media access](cast-media-access.md) | What a cast handoff lets the receiving device fetch, and nothing more |
| [Cast client](cast-client.md) | The Cast client built into the repository |

## Servers

| Document | What it covers |
| --- | --- |
| [WebDAV / NAS](webdav.md) | Playing music from a WebDAV share or a NAS |
| [Plex remote control](plex-remote-control.md) | Letting other Plex apps play, pause and skip on Linthra |
