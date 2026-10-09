// Takes finished gesture logs and gesture check reports from Conductor and files them in R2 as
// <kind>/<install id>/<file name>, where DuckDB reads them (scripts/recordings.sql). PUT only, one
// bearer token shared by every copy of the app, nothing to read back: listing and downloading go
// through R2 directly.
//
// The token ships inside the app, so treat it as public. What stands between a leaked token and
// the bucket: only the two file names Conductor writes, under a UUID install ID, under 100 MB, at
// most a few a minute per install and per address, and never over a file that's already there.

export interface Env {
  RECORDINGS: R2Bucket;
  UPLOAD_TOKEN: string;
  PER_INSTALL: RateLimit;
  PER_ADDRESS: RateLimit;
}

/** The platform stops request bodies here too; the app skips a recording that gzips bigger. */
const MAX_BYTES = 100 * 1024 * 1024;

/** Only the names Conductor writes, so a stolen token can't fill the bucket with anything else. */
const FILE_NAMES: Record<string, RegExp> = {
  recordings: /^gestures-\d{4}-\d{2}-\d{2}-\d{6}(-\d+)?\.jsonl\.gz$/,
  reports: /^gesture-check-\d{4}-\d{2}-\d{2}-\d{6}\.json$/,
};
const INSTALL_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const SHA256_HEX = /^[0-9a-f]{64}$/;
/** R2 keeps 2 KB of custom metadata per object; a header past this is cut, not refused. */
const METADATA_CHARS = 200;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method !== "PUT") return reply(405, "PUT /recordings/<file> or /reports/<file>");
    const address = request.headers.get("CF-Connecting-IP") ?? "unknown";
    if (!(await env.PER_ADDRESS.limit({ key: address })).success) return reply(429, "too many uploads from this address");
    if (!(await tokenMatches(request.headers.get("Authorization"), env.UPLOAD_TOKEN))) return reply(401, "bad token");

    const parts = new URL(request.url).pathname.split("/").slice(1);
    const [kind, name] = parts;
    const pattern = FILE_NAMES[kind];
    if (parts.length !== 2 || !pattern) return reply(404, "unknown path");
    if (!pattern.test(name)) return reply(400, "not a file name Conductor writes");
    const install = request.headers.get("X-Conductor-Install") ?? "";
    if (!INSTALL_ID.test(install)) return reply(400, "X-Conductor-Install missing or not a UUID");
    if (!(await env.PER_INSTALL.limit({ key: install })).success) return reply(429, "too many uploads from this install");
    const length = Number(request.headers.get("Content-Length"));
    if (!Number.isFinite(length) || length <= 0) return reply(411, "Content-Length needed");
    if (length > MAX_BYTES) return reply(413, `over ${MAX_BYTES} bytes`);
    const sha256 = request.headers.get("X-Conductor-SHA256")?.toLowerCase() ?? "";
    if (!SHA256_HEX.test(sha256)) return reply(400, "X-Conductor-SHA256 missing or not hex");

    const key = `${kind}/${install}/${name}`;
    // The same file again is a retry after a lost reply, and the first copy stands. A different
    // file under the same name is someone else's, or a corrupt one, and is refused.
    const existing = await env.RECORDINGS.head(key);
    if (existing) return existing.checksums.toJSON().sha256 === sha256 ? reply(200, key) : reply(409, "a different file has that name");
    const customMetadata: Record<string, string> = { received: new Date().toISOString() };
    for (const [header, field] of [["X-Conductor-Version", "version"], ["X-Conductor-OS", "os"]]) {
      const value = request.headers.get(header);
      if (value) customMetadata[field] = value.slice(0, METADATA_CHARS);
    }
    try {
      // R2 checks both the checksum and absence atomically, including concurrent first uploads.
      const stored = await env.RECORDINGS.put(key, request.body, {
        onlyIf: new Headers({ "If-None-Match": "*" }),
        sha256,
        httpMetadata: { contentType: request.headers.get("Content-Type") ?? "application/octet-stream" },
        customMetadata,
      });
      if (!stored) {
        const winner = await env.RECORDINGS.head(key);
        if (!winner) return reply(503, "file changed during upload; retry");
        return winner.checksums.toJSON().sha256 === sha256 ? reply(200, key) : reply(409, "a different file has that name");
      }
    } catch (error) {
      return reply(400, `not stored: ${error instanceof Error ? error.message : String(error)}`);
    }
    return reply(201, key);
  },
} satisfies ExportedHandler<Env>;

function reply(status: number, body: string): Response {
  return new Response(body, { status, headers: { "Content-Type": "text/plain" } });
}

/** Compares digests, so neither the token's bytes nor its length show in the timing. */
async function tokenMatches(header: string | null, token: string): Promise<boolean> {
  if (!token) return false;
  const given = header?.replace(/^Bearer /, "") ?? "";
  const [a, b] = await Promise.all([digest(given), digest(token)]);
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

async function digest(text: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}
