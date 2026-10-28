import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

const TOOL = join(process.cwd(), "tools/leak-check.mjs");
const NOREPLY = "1+tester@users.noreply.github.com";

// Each case builds its own throwaway repository so the result never depends on
// this checkout's history, refs, or the developer's git config.
const isolated = Object.fromEntries(
  Object.entries(process.env).filter(([k]) => !k.startsWith("QN_") && !k.startsWith("GIT_")),
);
const gitEnv = {
  ...isolated,
  GIT_CONFIG_GLOBAL: "/dev/null",
  GIT_CONFIG_NOSYSTEM: "1",
};

const repos = [];
afterEach(() => {
  while (repos.length) rmSync(repos.pop(), { recursive: true, force: true });
});

function git(cwd, args, env = {}) {
  return execFileSync("git", args, { cwd, encoding: "utf8", env: { ...gitEnv, ...env } });
}

function makeRepo() {
  const dir = mkdtempSync(join(tmpdir(), "leak-check-"));
  repos.push(dir);
  git(dir, ["init", "-q", "-b", "main"]);
  return dir;
}

function commit(dir, files, { message = "init", email = NOREPLY, committerEmail = email } = {}) {
  for (const [path, body] of Object.entries(files)) {
    mkdirSync(dirname(join(dir, path)), { recursive: true });
    writeFileSync(join(dir, path), body);
  }
  git(dir, ["add", "-A"]);
  git(dir, ["commit", "-q", "--no-gpg-sign", "-m", message], {
    GIT_AUTHOR_NAME: "tester",
    GIT_AUTHOR_EMAIL: email,
    GIT_COMMITTER_NAME: "tester",
    GIT_COMMITTER_EMAIL: committerEmail,
  });
  return git(dir, ["rev-parse", "HEAD"]).trim();
}

function run(cwd, env = {}) {
  try {
    const out = execFileSync("node", [TOOL], {
      cwd,
      encoding: "utf8",
      env: { ...gitEnv, ...env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    return { code: 0, out, err: "" };
  } catch (e) {
    return { code: e.status ?? 1, out: String(e.stdout ?? ""), err: String(e.stderr ?? "") };
  }
}

describe("leak-check", () => {
  it("passes a clean repository and skips the word scan when no list is supplied", () => {
    const dir = makeRepo();
    commit(dir, { "README.md": "hello\n", ".env.example": "KEY=\n" });
    const r = run(dir);
    expect(r.err).toBe("");
    expect(r.code).toBe(0);
    expect(r.out).toContain("word scan skipped");
    expect(r.out).toContain("leak-check clean: 2 files, 1 author email(s)");
  });

  it("treats a list of only separators and blanks as no list", () => {
    const dir = makeRepo();
    commit(dir, { "a.txt": "x\n" });
    const r = run(dir, { QN_FORBIDDEN_WORDS: " , ,\n" });
    expect(r.code).toBe(0);
    expect(r.out).toContain("word scan skipped");
  });

  it("flags every forbidden tracked file and keeps the allowlisted examples", () => {
    const dir = makeRepo();
    commit(dir, {
      ".env": "SECRET=1\n",
      ".env.local": "SECRET=1\n",
      ".env.example": "SECRET=\n",
      "android/app/google-services.json": "{}\n",
      "ios/App/GoogleService-Info.plist": "<plist/>\n",
      "worker/wrangler.toml": "name='x'\n",
      "worker/wrangler.example.toml": "name='x'\n",
      "worker/wrangler.test.toml": "name='x'\n",
      "keys/release.keystore": "k",
      "keys/upload.jks": "k",
      "keys/cert.p12": "k",
      "data/index-main.json": "{}\n",
      "data/lib.index.json": "{}\n",
      "src/ok.json": "{}\n",
    });
    const r = run(dir);
    expect(r.code).toBe(1);
    const flagged = r.err
      .split("\n")
      .filter((l) => l.startsWith("FAIL forbidden tracked file: "))
      .map((l) => l.slice("FAIL forbidden tracked file: ".length))
      .sort();
    expect(flagged).toEqual(
      [
        ".env",
        ".env.local",
        "android/app/google-services.json",
        "data/index-main.json",
        "data/lib.index.json",
        "ios/App/GoogleService-Info.plist",
        "keys/cert.p12",
        "keys/release.keystore",
        "keys/upload.jks",
        "worker/wrangler.toml",
      ].sort(),
    );
  });

  it("rejects a personal commit email without printing it, and accepts the GitHub committer", () => {
    const dir = makeRepo();
    commit(dir, { "a.txt": "a\n" }, { committerEmail: "noreply@github.com" });
    expect(run(dir).code).toBe(0);

    commit(dir, { "b.txt": "b\n" }, { email: "someone@example.com" });
    const r = run(dir);
    expect(r.code).toBe(1);
    expect(r.err).toContain("FAIL non-noreply commit email: ");
    expect(r.err).not.toContain("someone@example.com");
    expect(r.out).not.toContain("someone@example.com");
  });

  it("reports a forbidden word in file content by file and line, case-insensitively", () => {
    const dir = makeRepo();
    commit(dir, { "src/a.ts": "const a = 1;\nconst id = 'com.Canary-Word.app';\n" });
    const r = run(dir, { QN_FORBIDDEN_WORDS: "canary-word" });
    expect(r.code).toBe(1);
    expect(r.err).toContain("FAIL forbidden word in src/a.ts:2");
    expect(r.err).not.toContain("src/a.ts:1");
  });

  it("matches words literally, not as regular expressions", () => {
    const dir = makeRepo();
    commit(dir, { "a.txt": "axb\n" });
    expect(run(dir, { QN_FORBIDDEN_WORDS: "a.b" }).code).toBe(0);
  });

  it("scans the checked-out ref's history only, so each branch is judged on its own checkout", () => {
    const dir = makeRepo();
    commit(dir, { "a.txt": "a\n" });
    git(dir, ["checkout", "-q", "-b", "side"]);
    const hash = commit(dir, { "b.txt": "b\n" }, { message: "wip\n\nmentions canary-word here" });
    commit(dir, { "c.txt": "c\n" }, { email: "someone@example.com" });
    const onSide = run(dir, { QN_FORBIDDEN_WORDS: "canary-word" });
    expect(onSide.code).toBe(1);
    expect(onSide.err).toContain(`FAIL forbidden word in commit message: ${hash.slice(0, 8)}`);
    expect(onSide.err).toContain("FAIL non-noreply commit email: ");

    git(dir, ["checkout", "-q", "main"]);
    const onMain = run(dir, { QN_FORBIDDEN_WORDS: "canary-word" });
    expect(onMain.err).toBe("");
    expect(onMain.code).toBe(0);
  });

  it("accepts the Claude noreply address", () => {
    const dir = makeRepo();
    commit(dir, { "a.txt": "a\n" }, { email: "noreply@anthropic.com" });
    const r = run(dir);
    expect(r.err).toBe("");
    expect(r.code).toBe(0);
  });

  it("exempts only the commits listed in the allow file, not the address itself", () => {
    const dir = makeRepo();
    const published = commit(dir, { "a.txt": "a\n" }, { email: "someone@example.com" });
    expect(run(dir).code).toBe(1);

    commit(dir, {
      "tools/leak-check-allow-commits.txt": `# published already\n${published}  # trailing note\n`,
    });
    const allowed = run(dir);
    expect(allowed.err).toBe("");
    expect(allowed.code).toBe(0);

    commit(dir, { "b.txt": "b\n" }, { email: "someone@example.com" });
    const again = run(dir);
    expect(again.code).toBe(1);
    expect(again.err).toContain("FAIL non-noreply commit email: ");
    expect(again.err).not.toContain("someone@example.com");
  });

  it("scans the whole message even when it contains the internal field separator", () => {
    const dir = makeRepo();
    const hash = commit(
      dir,
      { "a.txt": "a\n" },
      { message: "subject\n\nbefore\x01after canary-word" },
    );
    const r = run(dir, { QN_FORBIDDEN_WORDS: "canary-word" });
    expect(r.code).toBe(1);
    expect(r.err).toContain(`FAIL forbidden word in commit message: ${hash.slice(0, 8)}`);
  });

  it("does not match a word against the commit hash itself", () => {
    const dir = makeRepo();
    const hash = commit(dir, { "a.txt": "a\n" }, { message: "plain message" });
    const r = run(dir, { QN_FORBIDDEN_WORDS: hash.slice(0, 7) });
    expect(r.err).toBe("");
    expect(r.code).toBe(0);
  });

  it("reads a newline- and comma-separated list from QN_FORBIDDEN_WORDS_FILE", () => {
    const dir = makeRepo();
    commit(dir, { "a.txt": "first-word\n", "b.txt": "second-word\n" });
    const list = join(dir, "..", `${dir.split("/").pop()}-words.txt`);
    writeFileSync(list, "unused\nfirst-word, second-word\n");
    repos.push(list);
    const r = run(dir, { QN_FORBIDDEN_WORDS_FILE: list });
    expect(r.code).toBe(1);
    expect(r.err).toContain("FAIL forbidden word in a.txt:1");
    expect(r.err).toContain("FAIL forbidden word in b.txt:1");
  });

  it("fails on an unreadable word-list file instead of silently skipping", () => {
    const dir = makeRepo();
    commit(dir, { "a.txt": "a\n" });
    const r = run(dir, { QN_FORBIDDEN_WORDS_FILE: join(dir, "missing-words.txt") });
    expect(r.code).toBe(1);
    expect(r.err).toContain("cannot read QN_FORBIDDEN_WORDS_FILE");
  });
});
