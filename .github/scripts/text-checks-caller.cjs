// issue と PR の本文のチェックの呼び出し側（#11）。コメントは見ない（workflow が本文の作成・編集でだけ動く）。
// github-script が require するので CommonJS で書く。兄弟リポの同名ファイルと中身をそろえる。
// 判定は brain #110 の本体の写し（.github/scripts/text-checks/ の Python）に任せ、
// ここでは「対象外の判定」「本体の CLI を --json で呼ぶ」「知らせる文を作る」だけをする。
// 当たった文字そのものや追加の禁止語は、知らせる文にもログにも出さない（本体も規則名だけを返す）。
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const CHECKS_DIR = path.join(__dirname, "text-checks");
// 組織の既定フォーム・PRテンプレートと、このリポで使われている見出しを、本体の見出しの別名として渡す設定（brain #135・#139）。
const HEADINGS_CONFIG = path.join(__dirname, "..", "text-checks.headings.json");

function isBotActor(login, config) {
  if (!login) return false;
  return login.endsWith("[bot]") || (config.skipActors || []).includes(login);
}

function shouldSkipFormat({ kind, author, labels = [], draft = false, title = "" }, config) {
  if (isBotActor(author, config)) return true;
  if (kind === "pull_request" && draft) return true;
  if (kind === "issue") {
    if (labels.some((l) => (config.skipIssueLabels || []).includes(l))) return true;
    // 組織の SBI フォームは本文を空にする決まりなので、[SBI] 付きの件名は書き方チェックを飛ばす。
    if ((config.skipIssueTitlePrefixes || []).some((p) => title.startsWith(p))) return true;
  }
  return false;
}

// 追加の禁止語はリポにもログにも置かないので、secret の中身だけを runner の一時ファイルに書いて
// 本体へはパスで渡す（1行1語、# で始まる行は注釈）。未設定なら null。
function writeExtraFile(raw, dir) {
  if (!raw?.trim()) return null;
  const file = path.join(dir, `public-text-extra-${process.pid}.txt`);
  fs.writeFileSync(file, raw.endsWith("\n") ? raw : `${raw}\n`, { mode: 0o600 });
  return file;
}

function runCli(script, args, text, extraFile) {
  const env = { ...process.env };
  delete env.PUBLIC_TEXT_EXTRA_FILE;
  delete env.TEXT_CHECKS_CONFIG;
  if (extraFile) env.PUBLIC_TEXT_EXTRA_FILE = extraFile;
  return spawnSync("python3", [path.join(CHECKS_DIR, script), ...args, "--json"], {
    input: text,
    encoding: "utf8",
    env,
  });
}

// 公開内容チェック。本文が空（終了コード 2）は書いてはいけないものが無いので OK とする。
function runPublicCheck(text, { extraFile = null } = {}) {
  const r = runCli("public_text_check.py", [], text || "", extraFile);
  if (r.status === 2) return { ok: true, hits: [], notices: [] };
  if (r.status !== 0 && r.status !== 1)
    throw new Error(`public_text_check.py が終了コード ${r.status} で止まりました`);
  const data = JSON.parse(r.stdout);
  return { ok: data.ok, hits: data.hits, notices: data.notices };
}

// 書き方チェック。kind は issue か pr。既定ではこのリポの見出しの設定を渡す。configFile: null で本体の既定だけで判定する。
function runFormatCheck(text, kind, { configFile = HEADINGS_CONFIG } = {}) {
  const args = ["--kind", kind, ...(configFile ? ["--config", configFile] : [])];
  const r = runCli("format_check.py", args, text || "", null);
  if (r.status !== 0 && r.status !== 1)
    throw new Error(`format_check.py が終了コード ${r.status} で止まりました`);
  const data = JSON.parse(r.stdout);
  return { ok: data.ok, problems: data.problems };
}

// 規則ごとにまとめる（同じ規則が何行にも当たったら1行にする）。
function groupHits(hits) {
  const byRule = new Map();
  for (const h of hits) {
    const g = byRule.get(h.rule) || { rule: h.rule, count: 0, lines: [] };
    g.count += h.count;
    g.lines.push(h.line);
    byRule.set(h.rule, g);
  }
  return [...byRule.values()];
}

function formatReport(kind, result, config, key = kind) {
  const marker = `${config.marker}:${key}`;
  if (kind === "public") {
    if (result.ok) return `${marker}\n公開内容チェック: OK（当たった規則はありません）`;
    const rows = groupHits(result.hits).map(
      (g) => `- ${g.rule}: ${g.count}件、${g.lines.join("・")}行目`,
    );
    return [
      marker,
      "公開内容チェック: 要確認",
      "公開リポに書いてはいけない形の文字が見つかりました。当たった文字はここには書きません。本文を直してください。",
      ...rows,
    ].join("\n");
  }
  if (result.ok) return `${marker}\n書き方チェック: OK`;
  return [
    marker,
    "書き方チェック: 足りない項目があります",
    ...result.problems.map((p) => `- ${p}`),
  ].join("\n");
}

module.exports = {
  CHECKS_DIR,
  HEADINGS_CONFIG,
  isBotActor,
  shouldSkipFormat,
  writeExtraFile,
  runPublicCheck,
  runFormatCheck,
  groupHits,
  formatReport,
};
