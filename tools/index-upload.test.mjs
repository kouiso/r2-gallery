import { execFileSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import sharp from "sharp";
import { afterEach, describe, expect, it } from "vitest";
import { IMAGE_EXT, VIDEO_EXT } from "../worker/src/lib/const";

const TOOL = join(process.cwd(), "tools/index-upload.mjs");
// A wrangler path that cannot exist: any upload attempt during a dry-run would crash the tool.
const NO_WRANGLER = ["--wrangler", "/nonexistent/wrangler-must-not-run"];
const scratchDirs = [];

// "jpe?g|png" -> ["jpe?g", "png"]
const alternatives = (re) => re.source.match(/\(([^)]+)\)/)[1].split("|");
// "jpe?g" -> ["jpeg", "jpg"]
const extensions = (re) =>
  alternatives(re).flatMap((alt) => {
    const m = alt.match(/^(.*)(.)\?(.*)$/);
    return m ? [m[1] + m[2] + m[3], m[1] + m[3]] : [alt];
  });

function scratch() {
  const dir = mkdtempSync(join(tmpdir(), "index-upload-test-"));
  scratchDirs.push(dir);
  return dir;
}

function run(args) {
  try {
    const stdout = execFileSync("node", [TOOL, ...args], { encoding: "utf8", stdio: "pipe" });
    return { code: 0, out: stdout, err: "" };
  } catch (e) {
    return { code: e.status ?? 1, out: String(e.stdout ?? ""), err: String(e.stderr ?? "") };
  }
}

function writeIndex(dir, data) {
  const file = join(dir, "index.json");
  writeFileSync(file, typeof data === "string" ? data : JSON.stringify(data));
  return file;
}

function dryRun(index, extra = []) {
  return run([
    "--index",
    index,
    "--lib",
    "a",
    "--meta-bucket",
    "b",
    "--dry-run",
    ...NO_WRANGLER,
    ...extra,
  ]);
}

const HAS_FFMPEG = (() => {
  try {
    execFileSync("ffmpeg", ["-version"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
})();

function makeVideo(file, seconds) {
  // mpeg4 is ffmpeg's built-in encoder, so this works without optional codec libraries.
  execFileSync("ffmpeg", [
    "-loglevel",
    "error",
    "-f",
    "lavfi",
    "-i",
    "testsrc=size=1280x720:rate=10",
    "-t",
    String(seconds),
    "-c:v",
    "mpeg4",
    file,
  ]);
}

// Fake wrangler: records each argv and keeps a copy of the uploaded file.
function fakeWrangler(dir) {
  const store = join(dir, "store");
  mkdirSync(store);
  const log = join(dir, "calls.jsonl");
  const path = join(dir, "fake-wrangler.mjs");
  writeFileSync(
    path,
    `#!/usr/bin/env node
import { appendFileSync, copyFileSync, readdirSync } from "node:fs";
const argv = process.argv.slice(2);
const copy = ${JSON.stringify(store)} + "/" + readdirSync(${JSON.stringify(store)}).length;
copyFileSync(argv[argv.indexOf("--file") + 1], copy);
appendFileSync(${JSON.stringify(log)}, JSON.stringify({ argv, copy }) + "\\n");
`,
  );
  chmodSync(path, 0o755);
  const calls = () =>
    existsSync(log)
      ? readFileSync(log, "utf8")
          .trim()
          .split("\n")
          .map((l) => JSON.parse(l))
      : [];
  return { path, calls };
}

function upload(index, media, wrangler, extra = []) {
  return run([
    "--index",
    index,
    "--lib",
    "lib1",
    "--meta-bucket",
    "meta",
    "--media-root",
    media,
    "--wrangler",
    wrangler.path,
    ...extra,
  ]);
}

afterEach(() => {
  while (scratchDirs.length) rmSync(scratchDirs.pop(), { recursive: true, force: true });
});

describe("index-upload", () => {
  it("requires --index, --lib and --meta-bucket", () => {
    const r = run([]);
    expect(r.code).toBe(1);
    expect(r.err).toContain("required:");
  });

  it("rejects non-slug library ids", () => {
    const r = run(["--index", "x.json", "--lib", "bad lib!", "--meta-bucket", "b"]);
    expect(r.code).toBe(1);
    expect(r.err).toContain("--lib must be a slug");
  });

  it("reports a missing or malformed index file without a stack trace", () => {
    const dir = scratch();
    const missing = dryRun(join(dir, "nope.json"));
    expect(missing.code).toBe(1);
    expect(missing.err).toContain("cannot read index");
    expect(missing.err).not.toContain("    at ");

    const broken = dryRun(writeIndex(dir, "{not json"));
    expect(broken.code).toBe(1);
    expect(broken.err).toContain("cannot read index");
    expect(broken.err).not.toContain("    at ");
  });

  it("rejects an unsupported index version", () => {
    const r = dryRun(writeIndex(scratch(), { version: 2, albums: [] }));
    expect(r.code).toBe(1);
    expect(r.err).toContain("version must be 1");
  });

  it.each([
    [".system/x.jpg", "system prefix"],
    [".trash/x.jpg", "trash prefix"],
    ["../x.jpg", "parent traversal"],
    ["pics/../../x.jpg", "nested traversal"],
    ["/abs/x.jpg", "absolute path"],
    ["notes.txt", "non-media extension"],
    ["", "empty key"],
  ])("rejects key %j (%s)", (key) => {
    const r = dryRun(writeIndex(scratch(), { version: 1, items: [{ key }], albums: [] }));
    expect(r.code).toBe(1);
    expect(r.err).toContain("invalid key");
  });

  it.each([
    [".system/x.jpg", "system prefix"],
    ["../x.jpg", "parent traversal"],
    ["/abs/x.jpg", "absolute path"],
    ["notes.txt", "non-media extension"],
    [123, "non-string value"],
  ])("rejects thumb key %j (%s)", (thumb) => {
    const r = dryRun(
      writeIndex(scratch(), { version: 1, items: [{ key: "a.jpg", thumb }], albums: [] }),
    );
    expect(r.code).toBe(1);
    expect(r.err).toContain("invalid thumb key");
  });

  it("accepts a declared thumb pointing at a media key", () => {
    const r = dryRun(
      writeIndex(scratch(), {
        version: 1,
        items: [{ key: "a.jpg", thumb: "b.jpg" }, { key: "b.jpg" }],
        albums: [],
      }),
    );
    expect(r.code).toBe(0);
    expect(r.err).toBe("");
  });

  it.each([
    ["../x.jpg", "parent traversal"],
    [".trash/x.jpg", "trash prefix"],
    ["notes.txt", "non-media extension"],
  ])("rejects cover key %j (%s)", (cover) => {
    const r = dryRun(
      writeIndex(scratch(), {
        version: 1,
        albums: [{ id: "x", title: "t", cover, items: [{ key: "a.jpg" }] }],
      }),
    );
    expect(r.code).toBe(1);
    expect(r.err).toContain("invalid cover key");
  });

  it("rejects duplicate and reserved album ids", () => {
    const album = (id) => ({ id, title: "t", items: [{ key: "a.jpg" }] });
    const dup = dryRun(writeIndex(scratch(), { version: 1, albums: [album("x"), album("x")] }));
    expect(dup.code).toBe(1);
    expect(dup.err).toContain("duplicate album id: x");

    const reserved = dryRun(writeIndex(scratch(), { version: 1, albums: [album("__other__")] }));
    expect(reserved.code).toBe(1);
    expect(reserved.err).toContain("reserved album id: __other__");
  });

  it("declares exactly the worker's image and video extensions", () => {
    const source = readFileSync(TOOL, "utf8");
    const declared = (name) => source.match(new RegExp(`const ${name} = "([^"]+)"`))[1];
    expect(declared("IMAGE")).toBe(alternatives(IMAGE_EXT).join("|"));
    expect(declared("VIDEO")).toBe(alternatives(VIDEO_EXT).join("|"));
  });

  it("accepts every extension the worker serves and treats images and videos like it", () => {
    const dir = scratch();
    const media = join(dir, "media");
    mkdirSync(media);
    const images = extensions(IMAGE_EXT);
    const videos = extensions(VIDEO_EXT);
    const keys = [...images.map((e) => `img.${e}`), ...videos.map((e) => `vid.${e}`)];
    for (const key of keys) writeFileSync(join(media, key), "fake");
    const index = writeIndex(dir, { version: 1, items: keys.map((key) => ({ key })), albums: [] });

    // without --video-thumbs only images get a thumbnail
    const r = dryRun(index, ["--media-root", media]);
    expect(r.err).toBe("");
    expect(r.code).toBe(0);
    for (const e of images) expect(r.out).toContain(`/img.${e}.webp`);
    for (const e of videos) expect(r.out).not.toContain(`/vid.${e}.webp`);
    expect(r.out).toContain(`${images.length} uploaded, ${videos.length} skipped`);
  });

  it("dry-run plans index and thumbnail uploads without invoking wrangler", () => {
    const dir = scratch();
    const index = writeIndex(dir, {
      version: 1,
      items: [{ key: "pics/a.jpg" }, { key: "pics/missing.jpg" }, { key: "clips/v.mp4" }],
      albums: [{ id: "al", title: "Album", items: [{ key: "pics/b.png" }] }],
    });
    const media = join(dir, "media");
    mkdirSync(join(media, "pics"), { recursive: true });
    mkdirSync(join(media, "clips"), { recursive: true });
    writeFileSync(join(media, "pics/a.jpg"), "fake");
    writeFileSync(join(media, "pics/b.png"), "fake");
    writeFileSync(join(media, "clips/v.mp4"), "fake");

    const r = dryRun(index, ["--media-root", media]);
    expect(r.code).toBe(0);
    expect(r.out).toContain("dry-run: would upload .system/index-a.json");
    expect(r.out).toContain("dry-run: would upload .system/thumbs/a/pics/a.jpg.webp");
    expect(r.out).toContain("dry-run: would upload .system/thumbs/a/pics/b.png.webp");
    // a missing source and (without --video-thumbs) the video are skipped, not planned
    expect(r.out).not.toContain("missing.jpg.webp");
    expect(r.out).not.toContain("v.mp4.webp");
    expect(r.out).toMatch(/2 uploaded, 2 skipped/);

    const withVideo = dryRun(index, ["--media-root", media, "--video-thumbs"]);
    expect(withVideo.code).toBe(0);
    expect(withVideo.out).toContain("dry-run: would upload .system/thumbs/a/clips/v.mp4.webp");
    expect(withVideo.out).toMatch(/3 uploaded, 1 skipped/);
  });

  it("uploads a real WebP thumbnail and the index only under .system/ of the meta bucket", async () => {
    const dir = scratch();
    const media = join(dir, "media");
    mkdirSync(join(media, "pics"), { recursive: true });
    await sharp({ create: { width: 1200, height: 800, channels: 3, background: "#3a6" } })
      .jpeg()
      .toFile(join(media, "pics/a.jpg"));
    const indexData = { version: 1, items: [{ key: "pics/a.jpg", note: "n" }], albums: [] };
    const index = writeIndex(dir, indexData);
    const wrangler = fakeWrangler(dir);

    const r = upload(index, media, wrangler);
    expect(r.err).toBe("");
    expect(r.code).toBe(0);
    expect(r.out).toMatch(/1 uploaded, 0 skipped/);

    const calls = wrangler.calls();
    expect(calls.map((c) => c.argv[3])).toEqual([
      "meta/.system/thumbs/lib1/pics/a.jpg.webp",
      "meta/.system/index-lib1.json",
    ]);
    for (const c of calls) {
      expect(c.argv.slice(0, 3)).toEqual(["r2", "object", "put"]);
      expect(c.argv).toContain("--remote");
    }

    const thumb = await sharp(calls[0].copy).metadata();
    expect(thumb.format).toBe("webp");
    expect(Math.max(thumb.width, thumb.height)).toBe(512);
    expect(calls[0].argv).toContain("image/webp");
    expect(JSON.parse(readFileSync(calls[1].copy, "utf8"))).toEqual(indexData);
    expect(calls[1].argv).toContain("application/json");
    // the uploaded index is a temp copy that the tool removes on exit
    expect(existsSync(calls[1].argv[calls[1].argv.indexOf("--file") + 1])).toBe(false);
  });

  it("stops with a readable error before uploading the index when a video cannot be decoded", () => {
    const dir = scratch();
    const media = join(dir, "media");
    mkdirSync(join(media, "clips"), { recursive: true });
    writeFileSync(join(media, "clips/broken.mp4"), "not a video");
    const index = writeIndex(dir, { version: 1, items: [{ key: "clips/broken.mp4" }], albums: [] });
    const wrangler = fakeWrangler(dir);

    const r = upload(index, media, wrangler, ["--video-thumbs"]);
    expect(r.code).toBe(1);
    expect(r.err).toContain("could not extract a poster frame from clips/broken.mp4");
    expect(r.err).not.toContain("    at ");
    expect(wrangler.calls()).toEqual([]);
  });

  it.skipIf(!HAS_FFMPEG).each([
    ["clips/long.mkv", 2],
    ["clips/short.mp4", 0.2], // shorter than the 0.5s seek: falls back to the first frame
  ])("renders a WebP poster for %s via ffmpeg", async (key, seconds) => {
    const dir = scratch();
    const media = join(dir, "media");
    mkdirSync(join(media, "clips"), { recursive: true });
    makeVideo(join(media, key), seconds);
    const index = writeIndex(dir, { version: 1, items: [{ key }], albums: [] });
    const wrangler = fakeWrangler(dir);

    const r = upload(index, media, wrangler, ["--video-thumbs"]);
    expect(r.err).toBe("");
    expect(r.code).toBe(0);
    const [thumb] = wrangler.calls();
    expect(thumb.argv[3]).toBe(`meta/.system/thumbs/lib1/${key}.webp`);
    const meta = await sharp(thumb.copy).metadata();
    expect(meta.format).toBe("webp");
    expect([meta.width, meta.height]).toEqual([512, 288]);
  });

  it("removes its scratch dir when interrupted mid-upload", () => {
    const dir = scratch();
    const index = writeIndex(dir, { version: 1, items: [{ key: "a.mp4" }], albums: [] });
    const log = join(dir, "files.txt");
    // Fake wrangler: records the uploaded file, then delivers Ctrl-C to the tool and itself.
    const fake = join(dir, "interrupting-wrangler.mjs");
    writeFileSync(
      fake,
      `#!/usr/bin/env node
import { appendFileSync } from "node:fs";
const argv = process.argv.slice(2);
appendFileSync(${JSON.stringify(log)}, argv[argv.indexOf("--file") + 1] + "\\n");
process.kill(process.ppid, "SIGINT");
process.kill(process.pid, "SIGINT");
`,
    );
    chmodSync(fake, 0o755);

    const r = run(["--index", index, "--lib", "l", "--meta-bucket", "m", "--wrangler", fake]);
    expect(r.code).not.toBe(0);
    const uploaded = readFileSync(log, "utf8").trim().split("\n")[0];
    expect(uploaded).toContain("qn-index-");
    expect(existsSync(dirname(uploaded))).toBe(false);
  });
});
