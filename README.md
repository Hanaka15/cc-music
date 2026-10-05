# cc-music

YouTube music for **ComputerCraft** + **CC:HQ Speakers**, with a **yt-dlp** API (Docker).

- **API** — search YouTube, stream MP3; ephemeral disk cache (default 1h, then delete)
- **Client** — `client/music.lua` → `speakerPlay(streamUrl)` (nothing stored on the MC server)

## Deploy on Render (free tier, no card required for basic use)

Repo: **https://github.com/Hanaka15/cc-music**

### Option A — Blueprint (easiest)

1. Open [Render Dashboard](https://dashboard.render.com) → **New** → **Blueprint**
2. Connect GitHub → select **`Hanaka15/cc-music`**
3. Render reads `render.yaml` and creates the web service
4. Wait for deploy; your URL will be like `https://cc-music.onrender.com`

### Option B — Manual Docker web service

1. **New** → **Web Service** → connect this repo  
2. **Runtime:** Docker  
3. **Plan:** Free  
4. **Health check path:** `/health`  
5. Deploy

### After deploy

1. Copy your Render URL (e.g. `https://cc-music.onrender.com`)
2. Edit `client/music.lua` on the CC computer:

```lua
local api_base_url = "https://cc-music.onrender.com/"
```

3. Enable **HTTP** on the Minecraft/CC server config.

`RENDER_EXTERNAL_URL` is set by Render, so stream links in search JSON should work without extra env vars. If not, set **`PUBLIC_BASE_URL`** in Render → Environment to your exact HTTPS URL.

### Render free tier notes

- Service **sleeps after ~15 minutes** idle — first request wakes it (30–60s+), first song may take longer while yt-dlp runs.
- **512 MB RAM** — enough for short tracks; very long videos may fail (API default max 30 min).

---

## Local API

```bash
bun install
bun run dev
```

```bash
curl -A 'computercraft/1.100.0' 'http://127.0.0.1:8080/?v=1&search=test'
```

---

## Repo layout

```
client/music.lua   # CC player (HQ Speakers)
src/               # Bun + yt-dlp API
Dockerfile
render.yaml        # Render Blueprint
fly.toml           # Optional (Fly.io — often requires card)
```

---

## Environment

| Variable | Purpose |
|----------|---------|
| `PUBLIC_BASE_URL` | Override public HTTPS base for stream URLs |
| `RENDER_EXTERNAL_URL` | Set automatically on Render |
| `CACHE_TTL_MS` | Cache lifetime on disk (default 1h) |
| `YTDLP_COOKIES` | Cookies file path if YouTube blocks the host |

---

## YouTube “Sign in to confirm you’re not a bot”

Render’s IP is a datacenter address. YouTube often blocks yt-dlp there unless you pass **cookies from a logged-in browser**.

1. On your PC, export Netscape `cookies.txt` while logged into [youtube.com](https://www.youtube.com)  
   (browser extension “Get cookies.txt LOCALLY”, or `yt-dlp --cookies-from-browser firefox --cookies cookies.txt --skip-download 'https://www.youtube.com'`).
2. Encode it:

```bash
./scripts/cookies-to-b64.sh ./cookies.txt
```

3. In **Render → your service → Environment**, add secret:

| Key | Value |
|-----|--------|
| `YTDLP_COOKIES_B64` | paste the one-line base64 output |

4. **Save** → wait for redeploy. Check `GET /health` — `"cookiesConfigured": true`.

Cookies expire / get rotated; if bot checks return, re-export and update the secret.  
Do **not** commit `cookies.txt` to git.

## Security

- **Search / metadata** — only requests with `User-Agent: computercraft/...` (CC:T HTTP API).
- **Streams** — `/stream/:id` without a signature returns 403. Search returns signed URLs (`?exp=&sig=`) for HQ Speakers; browsers cannot search, so they cannot obtain valid stream links.
- Set **`STREAM_SIGNING_SECRET`** on Render to a long random string (recommended after deploy).

Personal / fair-use only; respect copyright and YouTube ToS.
