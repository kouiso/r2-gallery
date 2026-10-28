#!/usr/bin/env node
/**
 * Pre-publication hygiene check.
 *
 * Scans tracked files and the history of the checked-out ref (HEAD) for:
 *   1. forbidden file types that must never be tracked
 *   2. non-noreply author/committer emails
 *   3. operator-supplied forbidden words in file contents and commit messages
 *
 * 見るのは HEAD の履歴だけ。CI は main と各 PR の head を 1 つずつ clone して検査するので、
 * --all にすると手元の clone がたまたま持っとる別の枝（bot が書く pages-dist 等）まで拾って落ちる。
 *
 * tools/leak-check-allow-commits.txt に載せた commit だけ email 検査から外す。main に公開済みで
 * force push せんと書き換えられん commit のためで、同じ宛先でも他の commit に出たら落とす。
 *
 * The forbidden-word list is NEVER committed. Supply it via:
 *   QN_FORBIDDEN_WORDS_FILE  path to a newline/comma-separated list, or
 *   QN_FORBIDDEN_WORDS       comma-separated list (CI secret)
 *
 * Exit 0 = clean (or words not supplied), 1 = finding.
 */
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const git = (args) =>
  execFileSync("git", args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });

let failures = 0;
const fail = (msg) => {
  failures++;
  console.error(`FAIL ${msg}`);
};

/* ---------- 1. forbidden tracked files ---------- */
const files = git(["ls-files"]).split("\n").filter(Boolean);
const allow = new Set(["worker/wrangler.example.toml", "worker/wrangler.test.toml", ".env.example"]);
const bannedFile =
  /(^|\/)(google-services\.json|GoogleService-Info\.plist|wrangler\.toml|\.env(\..+)?|[^/]*\.keystore|[^/]*\.jks|[^/]*\.p12|index-[^/]*\.json|[^/]*\.index\.json)$/;
for (const f of files) {
  if (allow.has(f)) continue;
  if (bannedFile.test(f)) fail(`forbidden tracked file: ${f}`);
}

/* ---------- 2. author / committer emails ---------- */
const allowFile = join(git(["rev-parse", "--show-toplevel"]).trim(), "tools/leak-check-allow-commits.txt");
const allowedCommits = new Set(
  existsSync(allowFile)
    ? readFileSync(allowFile, "utf8")
        .split("\n")
        .map((l) => l.replace(/#.*/, "").trim())
        .filter(Boolean)
    : [],
);
// Claude のセッションは noreply@anthropic.com で commit する。個人を特定しない宛先なので許す
const noreply =
  /^([0-9]+\+[^@]+@users\.noreply\.github\.com|noreply@github\.com|noreply@anthropic\.com)$/;
const emails = new Set();
const flagged = new Set();
for (const line of git(["log", "HEAD", "--format=%H %ae %ce"]).split("\n").filter(Boolean)) {
  const [hash, ...addrs] = line.split(" ");
  for (const e of addrs) {
    emails.add(e);
    if (noreply.test(e) || allowedCommits.has(hash) || flagged.has(e)) continue;
    flagged.add(e);
    fail(`non-noreply commit email: ${e.replace(/./g, "*")}`);
  }
}

/* ---------- 3. forbidden words ---------- */
function loadWords() {
  const inline = process.env.QN_FORBIDDEN_WORDS;
  const file = process.env.QN_FORBIDDEN_WORDS_FILE;
  let raw = "";
  if (inline) raw += inline;
  if (file) {
    try {
      raw += `\n${readFileSync(file, "utf8")}`;
    } catch (e) {
      fail(`cannot read QN_FORBIDDEN_WORDS_FILE: ${String(e)}`);
    }
  }
  return raw
    .split(/[\n,]/)
    .map((w) => w.trim())
    .filter((w) => w.length > 0);
}

const words = loadWords();
if (words.length === 0) {
  console.log("no forbidden-word list supplied (QN_FORBIDDEN_WORDS[_FILE]); word scan skipped");
} else {
  const rx = new RegExp(
    words.map((w) => w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|"),
    "i",
  );
  for (const f of files) {
    let text;
    try {
      text = execFileSync("git", ["show", `HEAD:${f}`], {
        encoding: "utf8",
        maxBuffer: 32 * 1024 * 1024,
      });
    } catch {
      continue; // binary or unresolvable
    }
    if (text.includes("�")) continue; // binary
    const lines = text.split("\n");
    for (let i = 0; i < lines.length; i++) {
      if (rx.test(lines[i])) fail(`forbidden word in ${f}:${i + 1}`);
    }
  }
  // Match the message only: a short hex word would otherwise hit the commit hash itself.
  const messages = git(["log", "HEAD", "--format=%H%x01%s%n%b%x00"]);
  for (const entry of messages.split("\0")) {
    const body = entry.replace(/^\n/, "");
    const sep = body.indexOf("\x01");
    const hash = body.slice(0, sep);
    const message = sep < 0 ? "" : body.slice(sep + 1);
    if (!message.trim()) continue;
    if (rx.test(message)) fail(`forbidden word in commit message: ${hash.slice(0, 8)}`);
  }
}

if (failures) {
  console.error(`\n${failures} finding(s)`);
  process.exit(1);
}
console.log(`leak-check clean: ${files.length} files, ${emails.size} author email(s)`);
