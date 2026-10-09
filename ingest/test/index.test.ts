import { describe, expect, it } from "vitest";
import worker, { type Env } from "../src/index";

// The documented upload limit is part of the server contract.
const MAX_BYTES = 100 * 1024 * 1024;

async function sha256(text: string): Promise<string> {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Enough of R2 to test against: keeps bodies, checks the checksum like R2 does. */
class FakeBucket {
  objects = new Map<string, { body: string; options: R2PutOptions | undefined }>();
  writes = 0;
  async head(key: string) {
    const stored = this.objects.get(key);
    if (!stored) return null;
    const sha = stored.options?.sha256;
    return { key, checksums: { toJSON: () => ({ sha256: sha }) } } as unknown as R2Object;
  }
  async put(key: string, body: ReadableStream | null, options?: R2PutOptions) {
    const text = await new Response(body).text();
    if (options?.sha256 && options.sha256 !== (await sha256(text))) throw new Error("The SHA-256 checksum you specified did not match what we received.");
    const condition = options?.onlyIf;
    const createOnly = condition instanceof Headers
      ? condition.get("If-None-Match") === "*"
      : condition?.etagDoesNotMatch === "*";
    if (createOnly && this.objects.has(key)) return null;
    this.objects.set(key, { body: text, options });
    this.writes += 1;
    return { key } as R2Object;
  }
}

/** Both requests see the object missing before either gets to store its body. */
class ConcurrentBucket extends FakeBucket {
  private heads = 0;
  private release!: () => void;
  private ready = new Promise<void>((resolve) => { this.release = resolve; });

  override async head(key: string) {
    const existing = await super.head(key);
    this.heads += 1;
    if (this.heads === 2) this.release();
    if (this.heads <= 2) await this.ready;
    return existing;
  }
}

const INSTALL = "0f3a6c5e-1b2d-4e7f-8a9b-0c1d2e3f4a5b";
const allow = { limit: async () => ({ success: true }) };
const deny = { limit: async () => ({ success: false }) };

function env(limits: Partial<Pick<Env, "PER_INSTALL" | "PER_ADDRESS">> = {}, bucket = new FakeBucket()): Env & { RECORDINGS: FakeBucket } {
  return { RECORDINGS: bucket, UPLOAD_TOKEN: "secret", PER_INSTALL: allow, PER_ADDRESS: allow, ...limits } as never;
}

async function put(path: string, body = "{}", headers: Record<string, string> = {}, method = "PUT"): Promise<Request> {
  return new Request(`https://logs.example${path}`, {
    method,
    body: method === "PUT" ? body : undefined,
    headers: {
      Authorization: "Bearer secret",
      "X-Conductor-Install": INSTALL,
      "X-Conductor-SHA256": await sha256(body),
      "Content-Length": String(body.length),
      ...headers,
    },
  });
}

describe("the upload server", () => {
  it("files a recording under its kind, install and name, checksummed, with the app's headers", async () => {
    const e = env();
    const response = await worker.fetch(
      await put("/recordings/gestures-2026-10-06-120000.jsonl.gz", "gzip bytes", {
        "Content-Type": "application/gzip",
        "X-Conductor-Version": "0.1.0",
        "X-Conductor-OS": "Version 15.1 (Build 24B83)".padEnd(500, "!"),
      }),
      e,
    );
    expect(response.status).toBe(201);
    expect(await response.text()).toBe(`recordings/${INSTALL}/gestures-2026-10-06-120000.jsonl.gz`);
    const stored = e.RECORDINGS.objects.get(`recordings/${INSTALL}/gestures-2026-10-06-120000.jsonl.gz`);
    expect(stored?.body).toBe("gzip bytes");
    expect(stored?.options?.sha256).toBe(await sha256("gzip bytes"));
    expect(stored?.options?.httpMetadata).toEqual({ contentType: "application/gzip" });
    expect(stored?.options?.customMetadata?.version).toBe("0.1.0");
    expect(stored?.options?.customMetadata?.os).toHaveLength(200);
    expect(stored?.options?.customMetadata?.received).toMatch(/^\d{4}-/);
  });

  it("takes a report, repeats the same file quietly, and refuses a different file under that name", async () => {
    const e = env();
    expect((await worker.fetch(await put("/reports/gesture-check-2026-10-06-121500.json", '{"date":1}'), e)).status).toBe(201);
    expect((await worker.fetch(await put("/reports/gesture-check-2026-10-06-121500.json", '{"date":1}'), e)).status).toBe(200);
    expect((await worker.fetch(await put("/reports/gesture-check-2026-10-06-121500.json", '{"date":2}'), e)).status).toBe(409);
    expect(e.RECORDINGS.objects.get(`reports/${INSTALL}/gesture-check-2026-10-06-121500.json`)?.body).toBe('{"date":1}');
  });

  it("keeps the first file when different first uploads race for the same name", async () => {
    const e = env({}, new ConcurrentBucket());
    const path = "/reports/gesture-check-2026-10-06-121500.json";
    const requests = await Promise.all([put(path, '{"date":1}'), put(path, '{"date":2}')]);
    const responses = await Promise.all(requests.map((request) => worker.fetch(request, e)));
    expect(responses.map((response) => response.status).sort()).toEqual([201, 409]);
    expect(e.RECORDINGS.writes).toBe(1);
    const key = `reports/${INSTALL}/gesture-check-2026-10-06-121500.json`;
    const winner = responses.findIndex((response) => response.status === 201);
    expect(e.RECORDINGS.objects.get(key)?.body).toBe(`{"date":${winner + 1}}`);
  });

  it("accepts a concurrent retry of identical bytes without rewriting the object", async () => {
    const e = env({}, new ConcurrentBucket());
    const path = "/reports/gesture-check-2026-10-06-121500.json";
    const requests = await Promise.all([put(path, '{"date":1}'), put(path, '{"date":1}')]);
    const responses = await Promise.all(requests.map((request) => worker.fetch(request, e)));
    expect(responses.map((response) => response.status).sort()).toEqual([200, 201]);
    expect(e.RECORDINGS.writes).toBe(1);
  });

  it("refuses a body that doesn't match its checksum", async () => {
    const e = env();
    const response = await worker.fetch(
      await put("/reports/gesture-check-2026-10-06-121500.json", "{}", { "X-Conductor-SHA256": await sha256("something else") }),
      e,
    );
    expect(response.status).toBe(400);
    expect(e.RECORDINGS.objects.size).toBe(0);
  });

  it("turns away anything that isn't a Conductor file from a known install with the token", async () => {
    const e = env();
    const cases: [Request, number][] = [
      [await put("/recordings/gestures-2026-10-06-120000.jsonl.gz", "{}", {}, "GET"), 405],
      [await put("/recordings/gestures-2026-10-06-120000.jsonl.gz", "{}", { Authorization: "Bearer secreT" }), 401],
      [await put("/recordings/gestures-2026-10-06-120000.jsonl.gz", "{}", { Authorization: "Bearer secret-and-more" }), 401],
      [await put("/videos/gestures-2026-10-06-120000.jsonl.gz"), 404],
      [await put("/recordings/a/gestures-2026-10-06-120000.jsonl.gz"), 404],
      [await put("/recordings/../secrets.txt"), 404], // the URL parser folds the .. away first
      [await put("/recordings/gestures-2026-10-06-120000.jsonl"), 400],
      [await put("/reports/gestures-2026-10-06-120000.jsonl.gz"), 400],
      [await put("/recordings/gestures-2026-10-06-120000.jsonl.gz", "{}", { "X-Conductor-Install": "me" }), 400],
      [await put("/recordings/gestures-2026-10-06-120000.jsonl.gz", "{}", { "Content-Length": String(MAX_BYTES + 1) }), 413],
      [await put("/recordings/gestures-2026-10-06-120000.jsonl.gz", "{}", { "X-Conductor-SHA256": "abc" }), 400],
    ];
    for (const [request, status] of cases) {
      const response = await worker.fetch(request, e);
      expect(response.status, `${request.method} ${new URL(request.url).pathname}`).toBe(status);
    }
    expect(e.RECORDINGS.objects.size).toBe(0);
  });

  it("rate limits by address before the token and by install after it", async () => {
    const byAddress = env({ PER_ADDRESS: deny });
    expect((await worker.fetch(await put("/reports/gesture-check-2026-10-06-121500.json", "{}", { Authorization: "nope" }), byAddress)).status).toBe(429);
    const byInstall = env({ PER_INSTALL: deny });
    expect((await worker.fetch(await put("/reports/gesture-check-2026-10-06-121500.json"), byInstall)).status).toBe(429);
    expect(byInstall.RECORDINGS.objects.size).toBe(0);
  });
});
