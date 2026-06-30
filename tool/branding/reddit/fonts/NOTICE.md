# Fonts used by the Reddit brand assets

The Reddit banner artwork (`assets/brand/reddit/linthra-reddit-banner-*`)
embeds two open-source typefaces. Both are licensed under the
**SIL Open Font License, Version 1.1**, which permits embedding and
redistribution.

| Font | Use | File | License |
| --- | --- | --- | --- |
| **Space Grotesk** | the *Linthra* wordmark | `SpaceGrotesk-variable.woff2` | `SpaceGrotesk-OFL.txt` |
| **Inter** | taglines / secondary line | `Inter-variable.woff2` | `Inter-OFL.txt` |

- Space Grotesk — © 2020 The Space Grotesk Project Authors
  (https://github.com/floriankarsten/space-grotesk)
- Inter — © 2020 The Inter Project Authors
  (https://github.com/rsms/inter)

Both `*.woff2` files are the **latin** subset of the variable font (full weight
axis). They are embedded as base64 `data:` URIs inside the banner SVGs so the
SVGs render identically with no external fonts or network access.

The community icons use no text and therefore embed no fonts.
