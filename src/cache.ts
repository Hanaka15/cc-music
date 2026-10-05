import { readdirSync, statSync, unlinkSync, utimesSync, mkdirSync } from "node:fs";
import path from "node:path";
import { config } from "./config";
import { downloadAudio, normalizeId } from "./ytdlp";

export type CachedTrack = {
  id: string;
  path: string;
  contentType: string;
};

export type JobStatus =
  | { status: "ready"; id: string; path: string; contentType: string; size: number }
  | { status: "pending"; id: string }
  | { status: "error"; id: string; error: string }
  | { status: "idle"; id: string };

const inflight = new Map<string, Promise<CachedTrack>>();
const failures = new Map<string, string>();

function extForFormat(): string {
  return config.audioFormat === "ogg" ? "ogg" : config.audioFormat;
}

function contentTypeForFormat(): string {
  return config.audioFormat === "mp3"
    ? "audio/mpeg"
    : config.audioFormat === "ogg"
      ? "audio/ogg"
      : "audio/mp4";
}

function cachePathFor(id: string): string {
  return path.join(config.cacheDir, `${id}.${extForFormat()}`);
}

function touch(filePath: string) {
  const now = new Date();
  try {
    utimesSync(filePath, now, now);
  } catch {
    // ignore
  }
}

export function purgeExpired(): number {
  mkdirSync(config.cacheDir, { recursive: true });
  const now = Date.now();
  let removed = 0;
  for (const name of readdirSync(config.cacheDir)) {
    if (name.startsWith(".")) continue;
    const full = path.join(config.cacheDir, name);
    try {
      const st = statSync(full);
      if (!st.isFile()) continue;
      const age = now - st.mtimeMs;
      if (age > config.cacheTtlMs) {
        unlinkSync(full);
        removed++;
      }
    } catch {
      // ignore
    }
  }
  return removed;
}

async function peekReady(videoId: string): Promise<CachedTrack | null> {
  const existing = cachePathFor(videoId);
  const file = Bun.file(existing);
  if (!(await file.exists())) return null;
  touch(existing);
  return {
    id: videoId,
    path: existing,
    contentType: contentTypeForFormat(),
  };
}

function startJob(videoId: string): Promise<CachedTrack> {
  const pending = inflight.get(videoId);
  if (pending) return pending;

  failures.delete(videoId);
  const job = (async () => {
    mkdirSync(config.cacheDir, { recursive: true });
    const outBase = path.join(config.cacheDir, videoId);
    for (const name of readdirSync(config.cacheDir)) {
      if (name.startsWith(videoId) && name.endsWith(".part")) {
        try {
          unlinkSync(path.join(config.cacheDir, name));
        } catch {
          // ignore
        }
      }
    }
    console.log(`[yt-dlp] start ${videoId}`);
    const result = await downloadAudio(videoId, outBase);
    touch(result.path);
    console.log(`[yt-dlp] done ${videoId} -> ${result.path}`);
    return { id: videoId, path: result.path, contentType: result.contentType };
  })()
    .catch((err) => {
      const msg = err instanceof Error ? err.message : String(err);
      failures.set(videoId, msg);
      console.error(`[yt-dlp] fail ${videoId}`, msg);
      throw err;
    })
    .finally(() => {
      inflight.delete(videoId);
    });

  inflight.set(videoId, job);
  return job;
}

/** Kick off download without waiting (Render free tier ~30s HTTP limit). */
export function beginFetch(id: string): string {
  const videoId = normalizeId(id);
  if (!videoId) throw new Error("invalid id");
  void startJob(videoId).catch(() => {
    // error stored in failures
  });
  return videoId;
}

export async function getStatus(id: string): Promise<JobStatus> {
  const videoId = normalizeId(id);
  if (!videoId) throw new Error("invalid id");

  const ready = await peekReady(videoId);
  if (ready) {
    const size = Bun.file(ready.path).size;
    return {
      status: "ready",
      id: videoId,
      path: ready.path,
      contentType: ready.contentType,
      size,
    };
  }

  if (failures.has(videoId)) {
    return { status: "error", id: videoId, error: failures.get(videoId) || "download failed" };
  }

  if (inflight.has(videoId)) {
    return { status: "pending", id: videoId };
  }

  return { status: "idle", id: videoId };
}

export async function getOrFetch(id: string): Promise<CachedTrack> {
  const videoId = normalizeId(id);
  if (!videoId) throw new Error("invalid id");

  const ready = await peekReady(videoId);
  if (ready) return ready;

  return startJob(videoId);
}

export function startCacheJanitor() {
  purgeExpired();
  const every = Math.min(config.cacheTtlMs, 5 * 60 * 1000);
  setInterval(() => {
    const n = purgeExpired();
    if (n > 0) console.log(`[cache] purged ${n} expired file(s)`);
  }, every);
}
