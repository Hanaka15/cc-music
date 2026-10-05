import { readdirSync } from "node:fs";
import path from "node:path";
import { config } from "./config";

export type SearchHit = {
  id: string;
  name: string;
  artist: string;
  duration?: number;
  type: "track";
};

function baseArgs(): string[] {
  const args = [
    "--no-playlist",
    "--no-warnings",
    "--socket-timeout",
    "20",
    // YouTube requires a JS runtime to solve player challenges (EJS).
    "--js-runtimes",
    config.jsRuntime,
  ];
  if (config.cookiesFile) {
    args.push("--cookies", config.cookiesFile);
  }
  return args;
}

async function runYtdlp(args: string[]): Promise<{ ok: boolean; stdout: string; stderr: string }> {
  const proc = Bun.spawn([config.ytdlp, ...args], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  return { ok: code === 0, stdout, stderr };
}

function pickArtist(info: Record<string, unknown>): string {
  const channel = String(info.channel || info.uploader || info.creator || "").trim();
  return channel || "Unknown";
}

export function normalizeId(raw: string): string | null {
  const m = raw.match(/(?:v=|youtu\.be\/|shorts\/|live\/)?([A-Za-z0-9_-]{11})\b/);
  if (m) return m[1];
  if (/^[A-Za-z0-9_-]{11}$/.test(raw)) return raw;
  return null;
}

export async function search(query: string): Promise<SearchHit[]> {
  const q = query.trim();
  if (!q) return [];

  if (/^https?:\/\//i.test(q) || normalizeId(q)) {
    const target = /^https?:\/\//i.test(q)
      ? q
      : `https://www.youtube.com/watch?v=${normalizeId(q)}`;
    const { ok, stdout, stderr } = await runYtdlp([
      ...baseArgs(),
      "--dump-single-json",
      "--skip-download",
      target,
    ]);
    if (!ok) throw new Error(stderr.trim().split("\n").pop() || "yt-dlp metadata failed");
    const info = JSON.parse(stdout) as Record<string, unknown>;
    const id = String(info.id || normalizeId(q) || "");
    if (!id) return [];
    return [
      {
        id,
        name: String(info.title || id),
        artist: pickArtist(info),
        duration: typeof info.duration === "number" ? info.duration : undefined,
        type: "track",
      },
    ];
  }

  const { ok, stdout, stderr } = await runYtdlp([
    ...baseArgs(),
    "--flat-playlist",
    "--dump-single-json",
    `ytsearch${config.maxSearchResults}:${q}`,
  ]);
  if (!ok) throw new Error(stderr.trim().split("\n").pop() || "yt-dlp search failed");

  const data = JSON.parse(stdout) as { entries?: Array<Record<string, unknown>> };
  return (data.entries || [])
    .map((e) => {
      const id = String(e.id || "");
      if (!id) return null;
      return {
        id,
        name: String(e.title || id),
        artist: pickArtist(e),
        duration: typeof e.duration === "number" ? e.duration : undefined,
        type: "track" as const,
      };
    })
    .filter((x): x is SearchHit => x !== null);
}

function contentTypeFor(format: string): string {
  if (format === "mp3") return "audio/mpeg";
  if (format === "ogg") return "audio/ogg";
  if (format === "m4a") return "audio/mp4";
  return "application/octet-stream";
}

export async function downloadAudio(
  id: string,
  outBase: string,
): Promise<{ path: string; contentType: string }> {
  const videoId = normalizeId(id);
  if (!videoId) throw new Error("invalid id");

  const url = `https://www.youtube.com/watch?v=${videoId}`;
  const format = config.audioFormat;
  const outTemplate = `${outBase}.%(ext)s`;

  const args = [
    ...baseArgs(),
    "-x",
    "--audio-format",
    format,
    "--audio-quality",
    config.audioQuality,
    "--match-filter",
    `duration <= ${config.maxDurationSec}`,
    "-o",
    outTemplate,
  ];

  // yt-dlp wants a directory containing ffmpeg/ffprobe, not the word "ffmpeg".
  if (config.ffmpeg.includes("/")) {
    args.push("--ffmpeg-location", path.dirname(config.ffmpeg));
  }

  args.push(url);

  const { ok, stderr } = await runYtdlp(args);
  if (!ok) throw new Error(stderr.trim().split("\n").slice(-5).join("\n") || "yt-dlp download failed");

  const dir = path.dirname(outBase);
  const base = path.basename(outBase);
  const candidates = readdirSync(dir).filter(
    (n) => n === `${base}.${format}` || (n.startsWith(base + ".") && !n.endsWith(".part")),
  );
  const preferred = candidates.find((n) => n.endsWith(`.${format}`)) || candidates[0];
  if (!preferred) throw new Error(`download finished but no file for ${videoId}`);

  return {
    path: path.join(dir, preferred),
    contentType: contentTypeFor(format),
  };
}
