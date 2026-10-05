import { config } from "./config";
import { getOrFetch, beginFetch, getStatus, startCacheJanitor } from "./cache";
import { search } from "./ytdlp";
import {
  ccUnauthorized,
  requireComputerCraft,
  streamUrl,
  verifyStreamAccess,
} from "./auth";

function originFrom(req: Request): string {
  if (config.publicBaseUrl) return config.publicBaseUrl;
  const url = new URL(req.url);
  return url.origin;
}

function toResult(
  hit: { id: string; name: string; artist: string; duration?: number; type: string },
  origin: string,
) {
  const stream = streamUrl(origin, hit.id);
  // prepare = same signed query, warms yt-dlp cache without sending the mp3 body
  const prepare = stream.replace("/stream/", "/prepare/");
  return {
    id: hit.id,
    name: hit.name,
    artist: hit.artist,
    duration: hit.duration,
    type: hit.type,
    stream,
    prepare,
  };
}

startCacheJanitor();

const server = Bun.serve({
  port: config.port,
  idleTimeout: 255,

  async fetch(req) {
    const url = new URL(req.url);

    // Render health check — no CC required
    if (req.method === "GET" && url.pathname === "/health") {
      return Response.json({
        ok: true,
        ytdlp: config.ytdlp,
        format: config.audioFormat,
        cacheTtlMs: config.cacheTtlMs,
        requireCcUa: config.requireCcUa,
        requireSignedStreams: config.requireSignedStreams,
        cookiesConfigured: Boolean(config.cookiesFile),
      });
    }

    // iPod-style API — ComputerCraft only
    if (req.method === "GET" && url.pathname === "/") {
      const ccBlock = requireComputerCraft(req);
      if (ccBlock) return ccBlock;

      const searchQ = url.searchParams.get("search");
      const id = url.searchParams.get("id");

      if (searchQ !== null) {
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
        try {
          const hits = await search(id);
          if (!hits[0]) return Response.json({ error: "not found" }, { status: 404 });
          return Response.json(toResult(hits[0], originFrom(req)));
        } catch (e) {
          const msg = e instanceof Error ? e.message : String(e);
          return Response.json({ error: msg }, { status: 502 });
        }
      }

      return ccUnauthorized();
    }

    // Warm cache — returns quickly (Render free HTTP limit ~30s). CC polls until ready.
    const prepareMatch = url.pathname.match(/^\/prepare\/([^/]+)\/?$/);
    if (req.method === "GET" && prepareMatch) {
      const videoId = decodeURIComponent(prepareMatch[1]);
      const exp = url.searchParams.get("exp");
      const sig = url.searchParams.get("sig");
      if (!verifyStreamAccess(videoId, exp, sig)) {
        return new Response("Forbidden — get a prepare URL from ComputerCraft search", {
          status: 403,
          headers: { "content-type": "text/plain; charset=utf-8" },
        });
      }
      try {
        let st = await getStatus(videoId);
        if (st.status === "idle" || st.status === "error") {
          // restart on error / start on idle
          beginFetch(videoId);
          st = await getStatus(videoId);
        } else if (st.status === "pending") {
          // already running
        }

        if (st.status === "ready") {
          return Response.json({
            ok: true,
            ready: true,
            id: st.id,
            size: st.size,
            contentType: st.contentType,
          });
        }
        if (st.status === "error") {
          return Response.json({ ok: false, ready: false, error: st.error }, { status: 502 });
        }
        // pending
        return Response.json({
          ok: true,
          ready: false,
          status: "pending",
          id: videoId,
          note: "yt-dlp still downloading; poll /prepare again in a few seconds",
        });
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error("[prepare]", videoId, msg);
        return Response.json({ ok: false, ready: false, error: msg }, { status: 502 });
      }
    }

    // Stream: Minecraft client (HQ Speakers) — no CC User-Agent; requires signed URL from search
    const streamMatch = url.pathname.match(/^\/stream\/([^/]+)\/?$/);
    if (req.method === "GET" && streamMatch) {
      const videoId = decodeURIComponent(streamMatch[1]);
      const exp = url.searchParams.get("exp");
      const sig = url.searchParams.get("sig");

      if (!verifyStreamAccess(videoId, exp, sig)) {
        return new Response("Forbidden — get a stream URL from ComputerCraft search", {
          status: 403,
          headers: { "content-type": "text/plain; charset=utf-8" },
        });
      }

      try {
        const track = await getOrFetch(videoId);
        const file = Bun.file(track.path);
        const size = file.size;
        const headers = new Headers({
          "content-type": track.contentType,
          "cache-control": "private, max-age=300",
          "accept-ranges": "bytes",
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
        console.error("[stream]", videoId, msg);
        return Response.json({ error: msg }, { status: 502 });
      }
    }

    const ccBlock = requireComputerCraft(req);
    if (ccBlock) return ccBlock;

    return new Response("not found", { status: 404 });
  },
});

console.log(
  `[cc-music-api] http://127.0.0.1:${server.port}  cc-only=${config.requireCcUa}  signed-streams=${config.requireSignedStreams}`,
);
