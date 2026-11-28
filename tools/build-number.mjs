#!/usr/bin/env node
// 配るビルド（web-deploy・運用 repo の r2-flutter-build）が共通で使うビルド番号の正本。
// 番号 = pubspec.yaml の `version:` の `+` の後ろ（基準番号）
//        + `git rev-list --count --first-parent HEAD`。
// 同じ commit なら Web と APK と再実行で同じ番号になり、main の上では必ず増え、
// 番号から commit を逆に引ける（--resolve）。
// 使い方:
//   node tools/build-number.mjs            -> 番号だけを1行で出す
//   node tools/build-number.mjs --resolve N -> その番号を付けた commit の SHA を出す
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// 浅い clone では first-parent の数が実際より小さくなるので、間違った番号を付けないよう止める
export class ShallowCloneError extends Error {}

const VERSION_LINE = /^version:\s*([^\s+]+)(?:\+(\d+))?\s*$/m;

// pubspec.yaml の `version: X.Y.Z+N` の N（基準番号）を読む。`+` が無いと採番の基準が無いので Error
export function readBase(pubspecText) {
  const m = pubspecText.match(VERSION_LINE);
  if (!m) throw new Error("pubspec.yaml に version: 行が無い");
  if (m[2] === undefined) {
    throw new Error("pubspec.yaml の version: に +<基準番号> が無い");
  }
  return Number(m[2]);
}

// pubspec.yaml の `version: X.Y.Z+N` の X.Y.Z（利用者向けの版）を読む
export function readVersionName(pubspecText) {
  const m = pubspecText.match(VERSION_LINE);
  if (!m) throw new Error("pubspec.yaml に version: 行が無い");
  return m[1];
}

export function buildNumber(base, firstParentCount) {
  return base + firstParentCount;
}

// 番号 N を commit に戻す。firstParentShas は古い順で、
// i 番目（0 起点）の commit の first-parent 数は i+1 なので、N = base + (i+1)。
export function resolve(n, base, firstParentShas) {
  if (!Number.isInteger(n)) return null;
  const i = n - base - 1;
  if (i < 0 || i >= firstParentShas.length) return null;
  return firstParentShas[i];
}

function git(repoDir, args) {
  return execFileSync("git", args, { cwd: repoDir, encoding: "utf8" }).trim();
}

function baseOf(repoDir) {
  return readBase(readFileSync(join(repoDir, "flutter/pubspec.yaml"), "utf8"));
}

function assertNotShallow(repoDir) {
  if (git(repoDir, ["rev-parse", "--is-shallow-repository"]) === "true") {
    throw new ShallowCloneError("shallow clone: fetch full history");
  }
}

export function computeBuildNumber(repoDir) {
  const base = baseOf(repoDir);
  assertNotShallow(repoDir);
  const count = Number(git(repoDir, ["rev-list", "--count", "--first-parent", "HEAD"]));
  return buildNumber(base, count);
}

export function resolveCommit(repoDir, n) {
  const base = baseOf(repoDir);
  assertNotShallow(repoDir);
  const newestFirst = git(repoDir, ["rev-list", "--first-parent", "HEAD"]).split("\n");
  return resolve(n, base, newestFirst.reverse());
}

// CLI: repo の根はこのファイルの場所から決める（cwd に頼らない。
// web-deploy は flutter/ を作業場所にして ../tools/build-number.mjs を呼ぶ）
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
  try {
    const idx = process.argv.indexOf("--resolve");
    if (idx === -1) {
      console.log(computeBuildNumber(repoRoot));
    } else {
      const sha = resolveCommit(repoRoot, Number(process.argv[idx + 1]));
      // 範囲の外の番号は何も出さず失敗で返す
      if (sha === null) process.exit(1);
      console.log(sha);
    }
  } catch (e) {
    console.error(e instanceof ShallowCloneError ? e.message : String(e.message ?? e));
    process.exit(e instanceof ShallowCloneError ? 2 : 1);
  }
}
