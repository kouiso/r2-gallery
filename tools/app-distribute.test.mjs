import { execFileSync } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const SCRIPT = join(process.cwd(), "tools/app-distribute.sh");
const PUBSPEC = join(process.cwd(), "flutter/pubspec.yaml");
const PKG = join(process.cwd(), "package.json");

function sh(args, env = {}) {
  try {
    const stdout = execFileSync("bash", [SCRIPT, ...args], {
      encoding: "utf8",
      env: { ...process.env, ...env },
      timeout: 15_000,
    });
    return { code: 0, out: stdout, err: "" };
  } catch (e) {
    return {
      code: e.status ?? 1,
      out: String(e.stdout ?? ""),
      err: String(e.stderr ?? ""),
    };
  }
}

describe("app-distribute.sh", () => {
  it("passes bash syntax check", () => {
    const r = execFileSync("bash", ["-n", SCRIPT], { encoding: "utf8" });
    expect(r).toBe("");
  });

  it("fails fast listing the first missing env var", () => {
    const clean = Object.fromEntries(
      Object.entries(process.env).filter(([k]) => !k.startsWith("QN_") && k !== "FIREBASE_APP_ID"),
    );
    const r = sh([], clean);
    expect(r.code).toBe(1);
    expect(r.err).toContain("missing env:");
  });

  it("never embeds firebase ids or credentials in the script", () => {
    const src = readFileSync(SCRIPT, "utf8");
    expect(src).not.toMatch(/\d+:[0-9a-f]+:android:/); // firebase app id shape
    expect(src).not.toMatch(/AIza[0-9A-Za-z_-]{20,}/); // google api key shape
  });
});

// firebase-tools を本当に叩かんよう、PATH の先頭に引数を書き出すだけの pnpm を置いて流す
function distributeWith(env) {
  const dir = mkdtempSync(join(tmpdir(), "app-distribute-"));
  try {
    const apk = join(dir, "app.apk");
    writeFileSync(apk, "apk");
    const argsFile = join(dir, "args");
    const pnpm = join(dir, "pnpm");
    writeFileSync(pnpm, `#!/usr/bin/env bash\nprintf '%s\\n' "$@" > "${argsFile}"\n`);
    chmodSync(pnpm, 0o755);
    const clean = Object.fromEntries(
      Object.entries(process.env).filter(([k]) => !k.startsWith("QN_")),
    );
    const r = sh([apk], {
      ...clean,
      PATH: `${dir}:${process.env.PATH}`,
      FIREBASE_APP_ID: "test-app",
      ...env,
    });
    let args = null;
    try {
      args = readFileSync(argsFile, "utf8").trim().split("\n");
    } catch (e) {
      if (e.code !== "ENOENT") throw e;
    }
    return { ...r, args };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe("app-distribute.sh tester allow list", () => {
  it("pins the allow list to the owner only", () => {
    // なぜ: 宛先を広げるにはこの行を変える PR が要る、という状態を保つ
    const src = readFileSync(SCRIPT, "utf8");
    const lines = src.split("\n").filter((l) => l.startsWith("ALLOWED_TESTERS="));
    expect(lines).toEqual(['ALLOWED_TESTERS=("kouiso@ritmo.co.jp")']);
  });

  it("uploads to the owner, normalising case and spaces", () => {
    const r = distributeWith({ QN_TESTERS: " Kouiso@Ritmo.co.jp " });
    expect(r.code).toBe(0);
    expect(r.args).toContain("--testers");
    expect(r.args[r.args.indexOf("--testers") + 1]).toBe("kouiso@ritmo.co.jp");
  });

  it("uploads without notifying anyone when no tester is given", () => {
    const r = distributeWith({});
    expect(r.code).toBe(0);
    expect(r.args).not.toContain("--testers");
    expect(r.args).not.toContain("--groups");
  });

  it("refuses a tester outside the allow list before uploading", () => {
    const r = distributeWith({ QN_TESTERS: "kouiso@ritmo.co.jp,someone@example.com" });
    expect(r.code).toBe(1);
    expect(r.err).toContain("refused: tester not in allow list: someone@example.com");
    expect(r.args).toBeNull();
  });

  it("refuses tester groups because their members cannot be checked", () => {
    const r = distributeWith({ QN_TESTERS: "kouiso@ritmo.co.jp", QN_GROUPS: "beta-testers" });
    expect(r.code).toBe(1);
    expect(r.err).toContain("refused: QN_GROUPS");
    expect(r.args).toBeNull();
  });
});

describe("version sync", () => {
  it("keeps the Flutter version in sync with package.json", () => {
    const { version } = JSON.parse(readFileSync(PKG, "utf8"));
    expect(version).toMatch(/^\d+\.\d+\.\d+/);
    // なぜ: pubspec は `version: x.y.z+code` 固定。更新し忘れで FAD の版名だけ古くなる事故を防ぐ。
    const pubspec = readFileSync(PUBSPEC, "utf8");
    expect(pubspec).toMatch(new RegExp(`^version: ${version}\\+\\d+$`, "m"));
  });
});
