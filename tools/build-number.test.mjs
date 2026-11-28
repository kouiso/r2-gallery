import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { computeBuildNumber, resolveCommit, ShallowCloneError } from "./build-number.mjs";

function git(dir, args) {
  return execFileSync("git", args, { cwd: dir, encoding: "utf8" }).trim();
}

// first-parent が 5 つの履歴を持つ一時 repo を作る。
// main: c1 -> c2 -> c3 -> c4 -> merge(dev)。dev 側の d1/d2 は first-parent に入らない。
// pubspec は commit せず置くだけでよい（採番は作業ツリーのファイルを読む）。
function makeRepo() {
  const dir = mkdtempSync(join(tmpdir(), "r2g-build-number-"));
  git(dir, ["init", "-q", "-b", "main"]);
  git(dir, ["config", "user.email", "t@example.com"]);
  git(dir, ["config", "user.name", "t"]);
  mkdirSync(join(dir, "flutter"), { recursive: true });
  writeFileSync(join(dir, "flutter/pubspec.yaml"), "version: 1.2.3+1000\n");
  // 浅い clone でも pubspec が読めるよう、履歴に入れておく
  git(dir, ["add", "flutter/pubspec.yaml"]);
  const firstParent = [];
  const commit = (msg, empty = true) => {
    git(dir, ["commit", "-q", ...(empty ? ["--allow-empty"] : []), "-m", msg]);
    firstParent.push(git(dir, ["rev-parse", "HEAD"]));
  };
  commit("c1", false);
  commit("c2");
  git(dir, ["checkout", "-qb", "dev"]);
  git(dir, ["commit", "-q", "--allow-empty", "-m", "d1"]);
  git(dir, ["commit", "-q", "--allow-empty", "-m", "d2"]);
  git(dir, ["checkout", "-q", "main"]);
  commit("c3");
  commit("c4");
  git(dir, ["merge", "-q", "--no-ff", "-m", "merge dev", "dev"]);
  firstParent.push(git(dir, ["rev-parse", "HEAD"]));
  return { dir, firstParent };
}

describe("build number", () => {
  it("adds the first-parent count to the base", () => {
    const { dir } = makeRepo();
    try {
      expect(computeBuildNumber(dir)).toBe(1005);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("refuses a shallow clone", () => {
    const { dir } = makeRepo();
    const clone = mkdtempSync(join(tmpdir(), "r2g-shallow-"));
    try {
      // file:// を付けないと手元の clone では --depth が無視されて浅くならない
      git(clone, ["clone", "-q", "--depth", "1", `file://${dir}`, "c"]);
      expect(() => computeBuildNumber(join(clone, "c"))).toThrow(ShallowCloneError);
    } finally {
      rmSync(dir, { recursive: true, force: true });
      rmSync(clone, { recursive: true, force: true });
    }
  });

  it("resolves a build number back to its commit", () => {
    const { dir, firstParent } = makeRepo();
    try {
      expect(resolveCommit(dir, 1003)).toBe(firstParent[2]);
      expect(resolveCommit(dir, 1005)).toBe(firstParent[4]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("returns null for a number outside the history", () => {
    const { dir } = makeRepo();
    try {
      expect(resolveCommit(dir, 999)).toBeNull();
      expect(resolveCommit(dir, 1006)).toBeNull();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("fetches full history and passes the build number in web-deploy", () => {
    const wf = readFileSync(join(process.cwd(), ".github/workflows/web-deploy.yml"), "utf8");
    expect(wf).toContain("fetch-depth: 0");
    expect(wf).toContain("tools/build-number.mjs");
  });
});
