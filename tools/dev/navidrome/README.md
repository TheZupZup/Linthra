# Local Navidrome dev server

A throwaway [Navidrome](https://www.navidrome.org/) (Subsonic-compatible) server
for testing Linthra's Navidrome / Subsonic provider without a production server.

```bash
# 1. Add a few audio files
cp ~/some-music/*.mp3 tools/dev/navidrome/music/

# 2. Start it (http://localhost:4533)
docker compose -f tools/dev/navidrome/docker-compose.yml up -d

# 3. Connect Linthra → Settings → Navidrome / Subsonic
#    URL: http://<your-LAN-IP>:4533   user: admin   pass: admin
```

See **[docs/navidrome-dev-setup.md](../../../docs/navidrome-dev-setup.md)** for
the full walkthrough (connecting from an emulator vs. a real device, the HTTP /
cleartext note, troubleshooting, and the manual test checklist).

> Local testing only — plain http, a throwaway `admin/admin` user. Don't expose
> it to the internet or reuse the password.
