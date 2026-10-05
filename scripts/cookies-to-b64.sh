#!/usr/bin/env bash
# Encode a Netscape cookies.txt for the Render secret YTDLP_COOKIES_B64
# Usage: ./scripts/cookies-to-b64.sh ./cookies.txt
set -euo pipefail
FILE="${1:-}"
if [[ -z "$FILE" || ! -f "$FILE" ]]; then
  echo "Usage: $0 path/to/cookies.txt" >&2
  echo "" >&2
  echo "Export YouTube cookies (logged into youtube.com in the browser), then:" >&2
  echo "  1) Use a cookies.txt extension, or yt-dlp --cookies-from-browser firefox" >&2
  echo "  2) Run this script and paste the output into Render → Environment → YTDLP_COOKIES_B64" >&2
  exit 1
fi
# single-line base64 (no wraps) for easy paste into Render
base64 -w0 "$FILE" 2>/dev/null || base64 "$FILE" | tr -d '\n'
echo
