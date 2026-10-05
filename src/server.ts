import { config } from "./config";
import { getOrFetch, startCacheJanitor } from "./cache";
import { search } from "./ytdlp";

function isComputerCraft(ua: string | null): boolean {
  return !!ua && /computercraft\//i.test(ua);
}

function unauthorized(): Response {
  return new Response("This API only works from inside of the ComputerCraft program", {
    status: 403,
    headers: { "content-type": "text/plain; charset=utf-8" },
  });
}

function originFrom(req: Request): string {
  if (config.publicBaseUrl) return config.publicBaseUrl;
  const url = new URL(req.url);
  return url.origin;
}

function toResult(hit: { id: string; name: string; artist: string; duration?: number; type: string }, origin: string) {
  return {
    id: hit.id,
    name: hit.name,
    artist: hit.artist,
    duration: hit.duration,
    type: hit.type,
    stream: `${origin}/stream/${encodeURIComponent(hit.id)}`,
  };
}

startCacheJanitor();

const server = Bun.serve({
  port: config.port,
  idleTimeout: 255,

  async fetch(req) {
    const url = new URL(req.url);
    const ua = req.headers.get("user-agent");

    if (req.method === "GET" && url.pathname === "/health") {
      return Response.json({
        ok: true,
        ytdlp: config.ytdlp,
        format: config.audioFormat,
        cacheTtlMs: config.cacheTtlMs,
      });
    }

    // Compatible with the old iPod-style query API
    if (req.method === "GET" && url.pathname === "/") {
      const searchQ = url.searchParams.get("search");
      const id = url.searchParams.get("id");

      if (searchQ !== null) {
        if (config.requireCcUa && !isComputerCraft(ua)) return unauthorized();
        try {
          const hits = await search(searchQ);
          const origin = originFrom(req);
          return Response.json(hits.map((h) => toResult(h, origin)));
        } catch (e) {
          const msg = e instanceof Error ? e.message : String(e);
          return Response.json({ error: msg }, { status: 502 });
        }
      }

      if (id) {
        if (config.requireCcUa && !isComputerCraft(ua)) return unauthorized();
        try {
          const hits = await search(id);
          if (!hits[0]) return Response.json({ error: "not found" }, { status: 404 });
          return Response.json(toResult(hits[0], originFrom(req)));
        } catch (e) {
          const msg = e instanceof Error ? e.message : String(e);
          return Response.json({ error: msg }, { status: 502 });
        }
      }

      return Response.json({
        name: "cc-music-api",
        version: "2",
        engine: "yt-dlp",
        storage: "ephemeral-cache",
        cacheTtlMs: config.cacheTtlMs,
        endpoints: {
          search: "/?v=1&search=query",
          track: "/?v=1&id=youtubeId",
          stream: "/stream/:id  (public — HQ Speakers / game clients)",
          health: "/health",
        },
        note: "Audio is cached on disk temporarily then deleted. Nothing permanent.",
      });
    }

    // PUBLIC stream for HQ Speakers (Minecraft clients do not send CC User-Agent)
    const streamMatch = url.pathname.match(/^\/stream\/([^/]+)\/?$/);
    if (req.method === "GET" && streamMatch) {
      const id = decodeURIComponent(streamMatch[1]);
      try {
        const track = await getOrFetch(id);
        const file = Bun.file(track.path);
        const size = file.size;
        const headers = new Headers({
          "content-type": track.contentType,
          "cache-control": "private, max-age=300",
          "accept-ranges": "bytes",
          "access-control-allow-origin": "*",
        });

        const range = req.headers.get("range");
        if (range) {
          const m = /^bytes=(\d*)-(\d*)$/.exec(range);
          if (m) {
            const start = m[1] ? Number(m[1]) : 0;
            const end = m[2] ? Number(m[2]) : size - 1;
            if (start <= end && end < size) {
              headers.set("content-range", `bytes ${start}-${end}/${size}`);
              headers.set("content-length", String(end - start + 1));
              return new Response(file.slice(start, end + 1), { status: 206, headers });
            }
          }
        }

        headers.set("content-length", String(size));
        return new Response(file, { status: 200, headers });
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error("[stream]", id, msg);
        return Response.json({ error: msg }, { status: 502 });
      }
    }

    if (req.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "access-control-allow-origin": "*",
          "access-control-allow-methods": "GET, OPTIONS",
          "access-control-allow-headers": "*",
        },
      });
    }

    return new Response("not found", { status: 404 });
  },
});

console.log(
  `[cc-music-api] http://127.0.0.1:${server.port}  ytdlp=${config.ytdlp}  format=${config.audioFormat}  ttl=${config.cacheTtlMs}ms`,
);
