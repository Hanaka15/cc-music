import { readdirSync, statSync, unlinkSync, utimesSync, mkdirSync } from "node:fs";
import path from "node:path";
import { config } from "./config";
import { downloadAudio, normalizeId } from "./ytdlp";

export type CachedTrack = {
  id: string;
  path: string;
  contentType: string;
};

const inflight = new Map<string, Promise<CachedTrack>>();

function extForFormat(): string {
  return config.audioFormat === "ogg" ? "ogg" : config.audioFormat;
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

export async function getOrFetch(id: string): Promise<CachedTrack> {
  const videoId = normalizeId(id);
  if (!videoId) throw new Error("invalid id");

  const existing = cachePathFor(videoId);
  const file = Bun.file(existing);
  if (await file.exists()) {
    touch(existing);
    return {
      id: videoId,
      path: existing,
      contentType:
        config.audioFormat === "mp3"
          ? "audio/mpeg"
          : config.audioFormat === "ogg"
            ? "audio/ogg"
            : "audio/mp4",
    };
  }

  const pending = inflight.get(videoId);
  if (pending) return pending;

  const job = (async () => {
    mkdirSync(config.cacheDir, { recursive: true });
    const outBase = path.join(config.cacheDir, videoId);
    // Clean partials from a previous crash
    for (const name of readdirSync(config.cacheDir)) {
      if (name.startsWith(videoId) && name.endsWith(".part")) {
        try {
          unlinkSync(path.join(config.cacheDir, name));
        } catch {
          // ignore
        }
      }
    }
    const result = await downloadAudio(videoId, outBase);
    touch(result.path);
    return { id: videoId, path: result.path, contentType: result.contentType };
  })().finally(() => {
    inflight.delete(videoId);
  });

  inflight.set(videoId, job);
  return job;
}

export function startCacheJanitor() {
  purgeExpired();
  const every = Math.min(config.cacheTtlMs, 5 * 60 * 1000);
  setInterval(() => {
    const n = purgeExpired();
    if (n > 0) console.log(`[cache] purged ${n} expired file(s)`);
  }, every);
}
