// text-checks のテスト（#11）。判定の本体は brain #110 の写し（Python）で、ここでは
// ①写しが元のコミットから一字もずれていないこと、②写しが本体と同じ結果を返すこと（本体の examples）、
// ③呼び出し側（text-checks-caller.cjs）が規則名だけを返し、当たった文字や追加の語を出さないことを確かめる。
// 秘密の形の例は、検査ツールに本物と間違われないよう文字をつないで作る（どれも作り物）。
import { createHash } from "node:crypto";
import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";

const require = createRequire(import.meta.url);
const caller = require("../.github/scripts/text-checks-caller.cjs");
const config = require("../.github/text-checks.config.json");
const source = require("../.github/text-checks.source.json");

const ROOT = path.resolve(import.meta.dirname, "..");
const EXAMPLES = path.join(caller.CHECKS_DIR, "examples");
const example = (name) => readFileSync(path.join(EXAMPLES, name), "utf8");
const join = (...parts) => parts.join("");

function listFiles(dir) {
  return readdirSync(dir).flatMap((name) => {
    const full = path.join(dir, name);
    return statSync(full).isDirectory() ? listFiles(full) : [full];
  });
}

const tmpDirs = [];
afterEach(() => {
  while (tmpDirs.length) rmSync(tmpDirs.pop(), { recursive: true, force: true });
});
const makeTmpDir = () => {
  const dir = mkdtempSync(path.join(tmpdir(), "text-checks-"));
  tmpDirs.push(dir);
  return dir;
};

describe("vendored copy drift check", () => {
  it("records the source repo and pinned commit", () => {
    expect(source.status).toBe("vendored");
    expect(source.repo).toBe("kouiso/brain");
    expect(source.issue).toBe(110);
    expect(source.commit).toMatch(/^[0-9a-f]{40}$/);
  });

  for (const f of source.files) {
    it(`${f.path} matches the recorded sha256`, () => {
      const actual = createHash("sha256")
        .update(readFileSync(path.join(ROOT, f.path)))
        .digest("hex");
      expect(actual).toBe(f.sha256);
    });
  }

  it("has no unlisted files in the vendored directory", () => {
    const listed = source.files.map((f) => f.path).sort();
    const present = listFiles(caller.CHECKS_DIR)
      .map((p) => path.relative(ROOT, p))
      .filter((p) => !p.includes("__pycache__"))
      .sort();
    expect(present).toEqual(listed);
  });
});

const CORE = { configFile: null };

describe("upstream examples (no repo config)", () => {
  it("accepts issue_ok and rejects issue_ng with the upstream messages", () => {
    expect(caller.runFormatCheck(example("issue_ok.md"), "issue", CORE)).toEqual({
      ok: true,
      problems: [],
    });
    expect(caller.runFormatCheck(example("issue_ng.md"), "issue", CORE)).toEqual({
      ok: false,
      problems: [
        "「今どこまで」が未記入です",
        "「次にやること」が未記入です",
        "見出し「誰の判断待ち」がありません",
      ],
    });
  });

  it("accepts pr_ok and rejects pr_ng with the upstream messages", () => {
    expect(caller.runFormatCheck(example("pr_ok.md"), "pr", CORE)).toEqual({
      ok: true,
      problems: [],
    });
    expect(caller.runFormatCheck(example("pr_ng.md"), "pr", CORE)).toEqual({
      ok: false,
      problems: ["見出し「変更内容」がありません", "「関連Issue」に #番号 か issue の URL がありません"],
    });
  });

  it("accepts public_ok (commit ids are notices only)", () => {
    const r = caller.runPublicCheck(example("public_ok.md"));
    expect(r.ok).toBe(true);
    expect(r.hits).toEqual([]);
  });

  it("turns green after the body is fixed", () => {
    const fixed = example("issue_ng.md")
      .replace("### 今どこまで\n-", "### 今どこまで\n- 作った")
      .replace("<!-- ここに書く -->", "- 呼ぶ側を作る\n\n## 誰の判断待ち\n- 副長");
    expect(caller.runFormatCheck(fixed, "issue", CORE).ok).toBe(true);
  });
});

describe("headings config for this repo", () => {
  it("accepts the org feature form headings with config, fails without", () => {
    // 組織の新規開発フォームの見出し: なぜ欲しいか → 背景、どうなったら終わりか → 完了条件
    const pbi = "### なぜ欲しいか（必須）\n探す手間を減らす。\n\n### どうなったら終わりか（必須）\n- 一覧に出る\n";
    expect(caller.runFormatCheck(pbi, "issue", CORE).ok).toBe(false);
    expect(caller.runFormatCheck(pbi, "issue")).toEqual({ ok: true, problems: [] });
  });

  it("accepts the org bug form headings (なぜ直したいか / 何が起きたか)", () => {
    const bug =
      "### なぜ直したいか（必須）\n落ちる。\n\n### 何が起きたか（必須）\n- 開くと落ちる\n\n### どうなったら終わりか（必須）\n- 開ける\n";
    expect(caller.runFormatCheck(bug, "issue")).toEqual({ ok: true, problems: [] });
  });

  it("accepts hand-written issue headings used in this repo (再現 / 完了条件)", () => {
    // #219 の形: 再現・原因・対処・完了条件
    const issue =
      "## 再現\n- ピッカーから Google フォトを開けない\n\n## 対処\n- GET_CONTENT に戻す\n\n## 完了条件\n- [ ] 写真を追加できる\n";
    expect(caller.runFormatCheck(issue, "issue")).toEqual({ ok: true, problems: [] });
  });

  it("accepts hand-written issue headings (目的 / 受け入れ条件)", () => {
    const issue = "## 目的\n速くする。\n\n## 受け入れ条件\n- スクロールが引っかからない\n";
    expect(caller.runFormatCheck(issue, "issue")).toEqual({ ok: true, problems: [] });
  });

  it("accepts the org default PR template (関連 Issue / 概要・背景・妥協点 / やったこと)", () => {
    const pr =
      "## 関連 Issue\n\n- Closes #11\n\n## 概要・背景・妥協点\n\ntext-checks を移植した。\n\n## やったこと\n\n- workflow と写しを足した\n\n## やっていないこと\n\n- なし\n";
    expect(caller.runFormatCheck(pr, "pr")).toEqual({ ok: true, problems: [] });
  });

  it("rejects a PR without a summary section (対象 issue / 変更内容 / 検証 only)", () => {
    // #218 系の形: 概要にあたる欄が無いので 概要 不足で赤
    const pr = "## 対象 issue\n\nCloses #182\n\n## 変更内容\n\n- テストを足した\n\n## 検証\n\n- pnpm test\n";
    const r = caller.runFormatCheck(pr, "pr");
    expect(r.ok).toBe(false);
    expect(r.problems).toContain("見出し「概要」がありません");
  });

  it("rejects a related-issue heading with no issue number", () => {
    const pr =
      "## 関連 Issue\n\n- Closes #\n- Refs:\n\n## 概要・背景・妥協点\n\nx\n\n## やったこと\n\n- y\n";
    const r = caller.runFormatCheck(pr, "pr");
    expect(r.ok).toBe(false);
    expect(r.problems).toContain("「関連Issue」に #番号 か issue の URL がありません");
  });

  it("does not count the CodeRabbit summary as a summary section", () => {
    const pr =
      "## Summary by CodeRabbit\n\n自動生成の要約。\n\n## 変更内容\n\n- x\n\n## 関連 Issue\n\nCloses #1\n";
    const r = caller.runFormatCheck(pr, "pr");
    expect(r.ok).toBe(false);
    expect(r.problems).toContain("見出し「概要」がありません");
  });
});

describe("skip rules", () => {
  it("skips bot actors, draft PRs, alert labels, and [SBI] titles for the format check", () => {
    expect(caller.shouldSkipFormat({ kind: "issue", author: "github-actions[bot]" }, config)).toBe(true);
    expect(caller.shouldSkipFormat({ kind: "pull_request", author: "devin-ai-integration[bot]" }, config)).toBe(true);
    expect(caller.shouldSkipFormat({ kind: "pull_request", author: "someone", draft: true }, config)).toBe(true);
    expect(
      caller.shouldSkipFormat({ kind: "issue", author: "someone", labels: ["ci-failure"] }, config),
    ).toBe(true);
    // 組織の SBI フォームは本文を空にする決まりなので、件名の [SBI] で飛ばす（#97・#53 の形）。
    expect(
      caller.shouldSkipFormat({ kind: "issue", author: "someone", title: "[SBI] ロゴの案を決める" }, config),
    ).toBe(true);
    expect(
      caller.shouldSkipFormat({ kind: "issue", author: "someone", title: "[PBI][bug] 落ちる" }, config),
    ).toBe(false);
    expect(caller.shouldSkipFormat({ kind: "issue", author: "someone", labels: ["bug"] }, config)).toBe(false);
    // devin ラベルは人間の PBI にも付くので対象外にしない（#11 自体が devin ラベル）。
    expect(
      caller.shouldSkipFormat({ kind: "issue", author: "someone", labels: ["devin"] }, config),
    ).toBe(false);
    expect(
      caller.shouldSkipFormat({ kind: "pull_request", author: "someone", draft: false }, config),
    ).toBe(false);
  });
});

const FAKE = {
  "秘密の値(よくある鍵の形)": join("これを使う: ", "gh", "p_", "EXAMPLEONLY0000"),
  "DBの名前・接続先": join("接続先は ", "postgres", "://example/test"),
  メールアドレス: join("連絡先は someone", "@", "example.com"),
  金額: join("見積もりは 120,000", "円"),
};

describe("public text check", () => {
  for (const [rule, text] of Object.entries(FAKE)) {
    it(`flags a fabricated example by rule name: ${rule}`, () => {
      const r = caller.runPublicCheck(`ふつうの1行目\n${text}`);
      expect(r.ok).toBe(false);
      // 本体の規則は増えることがあるので、期待の規則が当たることだけ見る
      expect(r.hits.some((h) => h.rule === rule && h.line === 2 && h.count === 1)).toBe(true);
    });
  }

  it("reports only rule names and line numbers, never the matched text", () => {
    const text = FAKE.メールアドレス;
    const report = caller.formatReport("public", caller.runPublicCheck(text), config);
    expect(report.startsWith(`${config.marker}:public\n`)).toBe(true);
    expect(report).toMatch(/- メールアドレス: 1件、1行目/);
    expect(report.includes("example.com")).toBe(false);
  });

  it("treats an empty body as OK (upstream exit code 2)", () => {
    expect(caller.runPublicCheck("").ok).toBe(true);
    expect(caller.runPublicCheck("  \n").ok).toBe(true);
  });

  it("does not create an extra file when the secret is unset, and judges by the builtin rules", () => {
    const dir = makeTmpDir();
    expect(caller.writeExtraFile(undefined, dir)).toBe(null);
    expect(caller.writeExtraFile("  \n", dir)).toBe(null);
    expect(caller.runPublicCheck("サンプル商事さんの件", { extraFile: null }).ok).toBe(true);
  });

  it("flags an extra forbidden word by number only, never printing the word", () => {
    const dir = makeTmpDir();
    const file = caller.writeExtraFile("# 注釈\nサンプル商事", dir);
    expect(statSync(file).mode & 0o777).toBe(0o600);
    const r = caller.runPublicCheck("サンプル商事さんの件", { extraFile: file });
    expect(r.hits).toEqual([{ rule: "追加の禁止語 1 番目", line: 1, count: 1 }]);
    const report = caller.formatReport("public", r, config, "public-body");
    expect(report.startsWith(`${config.marker}:public-body\n`)).toBe(true);
    expect(report.includes("サンプル商事")).toBe(false);
  });
});

describe("format report", () => {
  it("starts with the marker and lists the upstream problem messages", () => {
    const r = caller.runFormatCheck(example("pr_ng.md"), "pr");
    const report = caller.formatReport("format", r, config);
    expect(report.split("\n")[0]).toBe(`${config.marker}:format`);
    expect(report).toMatch(/- 見出し「変更内容」がありません/);
    expect(caller.formatReport("format", { ok: true, problems: [] }, config)).toBe(
      `${config.marker}:format\n書き方チェック: OK`,
    );
  });
});
