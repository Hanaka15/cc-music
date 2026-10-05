# cc-music

YouTube music for **ComputerCraft** + **CC:HQ Speakers**, with a small **yt-dlp** API you can deploy on **Fly.io**.

- **API** — search YouTube, stream MP3 via temporary disk cache (auto-delete, default 1h)
- **Client** — `client/music.lua` uses `speakerPlay(streamUrl)` (no DFPWM, no files on the MC server)

## Deploy on Fly.io

1. Install [flyctl](https://fly.io/docs/hands-on/install-flyctl/) and log in: `fly auth login`
2. From this directory:

```bash
fly launch --no-deploy
# Accept Dockerfile, pick region; change app name in fly.toml if needed

fly deploy

fly secrets set PUBLIC_BASE_URL=https://YOUR_APP.fly.dev
```

3. On a CC computer, edit `client/music.lua`:

```lua
local api_base_url = "https://YOUR_APP.fly.dev/"
```

4. Copy the script onto the computer and run it (HTTP enabled on the server).

## Local API

```bash
bun install
bun run dev
```

```bash
curl -A 'computercraft/1.100.0' 'http://127.0.0.1:8080/?v=1&search=test'
```

## Repo layout

```
client/music.lua   # CC:Tweaked + HQ Speakers player
src/               # Bun API (yt-dlp + ffmpeg)
Dockerfile         # Used by Fly.io
fly.toml           # Fly config
```

## Environment (Fly secrets / `fly.toml`)

| Variable | Purpose |
|----------|---------|
| `PUBLIC_BASE_URL` | HTTPS base for stream URLs in search JSON |
| `CACHE_TTL_MS` | How long to keep cached mp3 on disk (default 1h) |
| `YTDLP_COOKIES` | Optional path to cookies file if YouTube blocks the host |

## Notes

Personal / fair-use only. First play after idle may take a while (download + transcode).
