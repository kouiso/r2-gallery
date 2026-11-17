import { createRequire } from "node:module";
import { readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const directory = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(directory, "../../..");
const require = createRequire(path.join(root, "package.json"));
const poolRequire = createRequire(require.resolve("@cloudflare/vitest-pool-workers/config"));
const { Miniflare } = poolRequire("miniflare");
const { build } = poolRequire("esbuild");
const config = await readFile(path.join(root, "worker/wrangler.test.toml"), "utf8");
const fixtureVar = (name) => config.match(new RegExp(`^${name} = "([^"]+)"`, "m"))[1];
const baseline = execFileSync("git", ["show", "3e82f57:worker/src/routes/media.ts"], {
  cwd: root,
  encoding: "utf8",
});

// 本番コードを変更せず、ローカルの合成 R2 に対する境界ごとの時間と読出し回数だけを記録する。
const entry = `
import worker from './worker/src/index.ts';
import { signedUrl } from './worker/src/lib/sign.ts';
export default {
  async fetch(request, env, ctx) {
    const key = 'probe/video.mp4';
    const clock = () => performance.now();
    const startedSign = clock();
    const mediaUrl = await signedUrl(env, 'https://probe.test', 'm', 'a', key);
    const sign_url_ms = clock() - startedSign;
    const calls = [];
    const original = env.LIB_A;
    const traced = new Proxy(original, {
      get(target, property) {
        if (property === 'get' || property === 'head') return async (...args) => {
          const started = clock();
          const result = await target[property](...args);
          calls.push({ method: property, elapsed_ms: clock() - started, range: args[1]?.range ?? null });
          return result;
        };
        const value = Reflect.get(target, property);
        return typeof value === 'function' ? value.bind(target) : value;
      },
    });
    const metaStart = clock();
    const meta = worker.fetch(new Request('https://probe.test/v1/a/meta?key=' + encodeURIComponent(key), {
      headers: { authorization: 'Bearer ' + env.ACCESS_TOKEN },
    }), env, ctx).then(async response => {
      const body = await response.json();
      return { status: response.status, review_present: body.meta !== null, elapsed_ms: clock() - metaStart };
    });
    const range = new URL(request.url).searchParams.get('range');
    const method = new URL(request.url).searchParams.get('method') ?? 'GET';
    const startedMedia = clock();
    const response = await worker.fetch(new Request(mediaUrl, { method, headers: range ? { range } : {} }),
      { ...env, LIB_A: traced }, ctx);
    const media_headers_ms = clock() - startedMedia;
    let bytes = 0;
    let media_first_chunk_ms = null;
    if (response.body) {
      const reader = response.body.getReader();
      for (;;) {
        const next = await reader.read();
        if (next.done) break;
        if (media_first_chunk_ms === null) media_first_chunk_ms = clock() - startedMedia;
        bytes += next.value.byteLength;
      }
    }
    const media_body_complete_ms = clock() - startedMedia;
    return Response.json({ sign_url_ms, media_headers_ms, media_first_chunk_ms, media_body_complete_ms,
      response_bytes: bytes, status: response.status, content_range: response.headers.get('content-range'),
      r2_calls: calls, meta: await meta });
  }
};
`;

const results = [];
for (const variant of ["before", "after"]) {
  const bundle = await build({
    stdin: {
      contents: entry,
      resolveDir: root,
      sourcefile: "local-startup-probe.js",
      loader: "js",
    },
    bundle: true,
    format: "esm",
    platform: "browser",
    target: "es2022",
    write: false,
    plugins:
      variant === "before"
        ? [
            {
              name: "baseline-media-only",
              setup(build) {
                build.onLoad({ filter: /routes\/media\.ts$/ }, () => ({
                  contents: baseline,
                  loader: "ts",
                }));
              },
            },
          ]
        : [],
  });
  const mf = new Miniflare({
    modules: true,
    script: bundle.outputFiles[0].text,
    compatibilityDate: "2026-09-01",
    r2Buckets: ["LIB_A", "META"],
    r2Persist: false,
    d1Databases: ["REVIEW_DB"],
    d1Persist: false,
    bindings: {
      ACCESS_TOKEN: fixtureVar("ACCESS_TOKEN"),
      SIGNING_SECRET: fixtureVar("SIGNING_SECRET"),
      URL_TTL_SECONDS: fixtureVar("URL_TTL_SECONDS"),
      REVIEW_LIBS: "a",
      LIBRARIES: JSON.stringify([{ id: "a", title: "Synthetic fixture", binding: "LIB_A" }]),
    },
  });
  try {
    await mf.ready;
    const bucket = await mf.getR2Bucket("LIB_A");
    await bucket.put(
      "probe/video.mp4",
      Uint8Array.from({ length: 256 * 1024 }, (_, i) => i % 251),
      { httpMetadata: { contentType: "video/mp4" } },
    );
    const db = await mf.getD1Database("REVIEW_DB");
    await db.exec(
      "CREATE TABLE image_review (id INTEGER, r2_key TEXT, verdict TEXT, round INTEGER, label TEXT, intent_comment TEXT, director_score REAL, director_comment TEXT, created_at INTEGER)",
    );
    await db.exec(
      "CREATE TABLE image_review_criterion (id INTEGER, review_id INTEGER, criterion_key TEXT, weight REAL, panel_score REAL, director_score REAL, is_veto INTEGER, comment TEXT)",
    );
    await db
      .prepare("INSERT INTO image_review VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
      .bind(1, "probe/video.mp4", "fixture", 1, "fixture", null, 1, null, 1)
      .run();
    for (let n = 0; n < 6; n++) {
      const response = await mf.dispatchFetch("https://probe.test/probe?range=bytes=-65536");
      results.push({
        variant,
        sample: n === 0 ? "first_in_fresh_local_isolate" : `repeat_${n}`,
        ...(await response.json()),
      });
    }
    const head = await mf.dispatchFetch("https://probe.test/probe?method=HEAD");
    results.push({ variant, sample: "head_after_repeats", ...(await head.json()) });
  } finally {
    await mf.dispose();
  }
}
console.log(
  JSON.stringify(
    {
      scope:
        "Synthetic local Miniflare Worker; not Flutter, browser playback, production, or CDN cold-start latency",
      baseline_media_ref: "3e82f57",
      synthetic_object_bytes: 256 * 1024,
      cache:
        "No CDN Cache API or browser/native media cache; warm samples reuse local R2/D1 and HMAC CryptoKey in one isolate",
      clock:
        "Worker performance.now; local scheduler and I/O quantization apply. Runtime startup and fixture seeding excluded.",
      results,
    },
    null,
    2,
  ),
);
