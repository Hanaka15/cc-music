import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";

function resolveYtdlp(): string {
  if (process.env.YTDLP_PATH) return process.env.YTDLP_PATH;
  const local = path.join(process.cwd(), "bin", "yt-dlp");
  if (existsSync(local)) return local;
  return "yt-dlp";
}

function resolveFfmpeg(): string {
  if (process.env.FFMPEG_PATH) return process.env.FFMPEG_PATH;
  return "ffmpeg";
}

/**
 * Resolve a Netscape cookies.txt path for yt-dlp.
 * Prefer (in order):
 *   YTDLP_COOKIES          — path to a file already on disk
 *   YTDLP_COOKIES_B64      — base64 of cookies.txt (best for Render secrets)
 *   YTDLP_COOKIES_CONTENT  — raw cookies.txt body in an env var
 */
function resolveCookiesFile(): string {
  const existing = process.env.YTDLP_COOKIES || "";
  if (existing && existsSync(existing)) return existing;

  const dir = process.env.CACHE_DIR || path.join(process.cwd(), ".cache");
  mkdirSync(dir, { recursive: true });
  const out = path.join(dir, "youtube-cookies.txt");

  const b64 = process.env.YTDLP_COOKIES_B64 || "";
  if (b64.trim()) {
    const raw = Buffer.from(b64.replace(/\s+/g, ""), "base64").toString("utf8");
    writeFileSync(out, raw, { mode: 0o600 });
    return out;
  }

  const content = process.env.YTDLP_COOKIES_CONTENT || "";
  if (content.trim()) {
    // Render env UI often mangles newlines; accept \n escapes
    const raw = content.includes("\\n") ? content.replace(/\\n/g, "\n") : content;
    writeFileSync(out, raw.endsWith("\n") ? raw : raw + "\n", { mode: 0o600 });
    return out;
  }

  return "";
}

export const config = {
  port: Number(process.env.PORT || 8080),
  /** Stream links in JSON — Render sets RENDER_EXTERNAL_URL automatically. */
  publicBaseUrl: (
    process.env.PUBLIC_BASE_URL ||
    process.env.RENDER_EXTERNAL_URL ||
    ""
  ).replace(/\/+$/, ""),
  audioFormat: (process.env.AUDIO_FORMAT || "mp3") as "mp3" | "ogg" | "m4a",
  audioQuality: process.env.AUDIO_QUALITY || "5",
  cacheDir: process.env.CACHE_DIR || path.join(process.cwd(), ".cache"),
  /** Delete cached audio this long after last access (default 1 hour). */
  cacheTtlMs: Number(process.env.CACHE_TTL_MS || 1000 * 60 * 60),
  maxSearchResults: Number(process.env.MAX_SEARCH_RESULTS || 10),
  requireCcUa: (process.env.REQUIRE_CC_UA || "true") !== "false",
  /** HMAC secret for /stream links returned from search (set on Render for production). */
  streamSigningSecret:
    process.env.STREAM_SIGNING_SECRET || "cc-music-dev-change-in-production",
  streamTokenTtlSec: Number(process.env.STREAM_TOKEN_TTL_SEC || 60 * 60 * 24),
  requireSignedStreams: (process.env.REQUIRE_SIGNED_STREAMS || "true") !== "false",
  ytdlp: resolveYtdlp(),
  ffmpeg: resolveFfmpeg(),
  cookiesFile: resolveCookiesFile(),
  maxDurationSec: Number(process.env.MAX_DURATION_SEC || 60 * 30),
};

mkdirSync(config.cacheDir, { recursive: true });
