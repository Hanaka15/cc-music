import { createHmac, timingSafeEqual } from "node:crypto";
import { config } from "./config";

export function isComputerCraft(ua: string | null): boolean {
  return !!ua && /computercraft\//i.test(ua);
}

export function ccUnauthorized(): Response {
  return new Response("This API only works from inside of the ComputerCraft program", {
    status: 403,
    headers: { "content-type": "text/plain; charset=utf-8" },
  });
}

export function requireComputerCraft(req: Request): Response | null {
  if (!config.requireCcUa) return null;
  if (!isComputerCraft(req.headers.get("user-agent"))) return ccUnauthorized();
  return null;
}

function signPayload(payload: string): string {
  return createHmac("sha256", config.streamSigningSecret).update(payload).digest("hex").slice(0, 32);
}

/** Stream URLs are opened by Minecraft clients (not CC). Issue a signed URL after CC search. */
export function streamUrl(origin: string, videoId: string): string {
  const exp = Math.floor(Date.now() / 1000) + config.streamTokenTtlSec;
  const sig = signPayload(`${videoId}.${exp}`);
  const base = `${origin}/stream/${encodeURIComponent(videoId)}`;
  return `${base}?exp=${exp}&sig=${sig}`;
}

export function verifyStreamAccess(videoId: string, expParam: string | null, sigParam: string | null): boolean {
  if (!config.requireSignedStreams) return true;
  if (!expParam || !sigParam) return false;
  const exp = Number(expParam);
  if (!Number.isFinite(exp) || exp < Math.floor(Date.now() / 1000)) return false;
  const expected = signPayload(`${videoId}.${exp}`);
  if (expected.length !== sigParam.length) return false;
  try {
    return timingSafeEqual(Buffer.from(expected), Buffer.from(sigParam));
  } catch {
    return false;
  }
}
