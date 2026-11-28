#!/usr/bin/env python3
"""issue・PR・コメントの本文に、書いてはいけないものが入っていないかを調べる（brain #110 の 1）。

止めるもの: 秘密の値と名前、弱点や攻め方の手順、DBの名前と接続先、金額、メールアドレス、
追加の禁止語（顧客名など。リポには置かず --extra か環境変数 PUBLIC_TEXT_EXTRA_FILE のファイルで渡す）。
注意だけで通すもの: パス、機械の名前、16進の並び、UUID の形など。

結果は「規則の名前・行番号・件数」だけを出す。当たった文字そのものは出さない。
本文を書き換えたり消したりはしない（見つけて知らせるだけ）。

使い方:
  python3 script/checks/public_text_check.py 下書き.md
  printf '%s' "$BODY" | python3 script/checks/public_text_check.py --extra 禁止語.txt
  --json を付けると機械向けの JSON で出す（skillsheet #615 など、呼び出す側のため）。
終了コード: 0=引っかかりなし、1=引っかかりあり、2=本文が空。
"""
import argparse
import json
import os
import re
import sys

TOKEN_PREFIXES = ["figd_", "ghp_", "gho_", "ghs_", "ghu_", "ghr_", "github_pat_", "sk-ant-", "sk-", "AKIA", "xoxb-", "xoxp-",
                  "cog_", "glpat-", "AIza", "npm_"]
# npm の標準の環境変数名（npm_config_cache など）は鍵ではないので止めない。
NPM_ENV_NAME_EXCLUDE = r"(?!npm_(?:config_|package_|lifecycle_|node_|execpath))"
TOKEN_PREFIX_PATTERN = (r"(?<![A-Za-z0-9_])" + NPM_ENV_NAME_EXCLUDE + r"(?:"
                        + "|".join(re.escape(x) for x in TOKEN_PREFIXES)
                        + r")(?!(?<=sk-)ant-(?![A-Za-z0-9_\-]))(?:[A-Za-z0-9_\-]{4,}|\.\.\.|…)")

RULES = [
    ("秘密の名前(大文字_TOKEN等)", r"\b[A-Z0-9]+(?:_[A-Z0-9]+)*_(TOKEN|KEY|SECRET|PASSWORD|PASS|CREDENTIALS?)\b"),
    ("秘密の名前(サービスアカウント)", r"(?i)op_service_account"),
    ("秘密の値(key=/token=)", r"(?i)\b(key|token|secret|password)\s*="),
    ("秘密の値(ops_)", r"ops_"),
    ("秘密の値(よくある鍵の形)", r"\b(ghp_|gho_|github_pat_|sk-|xox[abp]-|AKIA)[A-Za-z0-9_\-]{6,}"),
    # 鍵の種類の頭。頭の後ろに 4 字以上、または「...」「…」が続けば、途中で切った形でも止める（brain #281）。
    # 頭だけの語（「figd_ の PAT」など）は止めない。前に英数字・_ が付く語（task-list の sk- など）も止めない。
    ("秘密の値(鍵の頭＋短い断片/省略)", TOKEN_PREFIX_PATTERN),
    ("秘密の値(秘密の言葉のすぐ後ろの長い並び)",
     r"(?i)\b(token|key|secret|password|passwd|api[_\-]?key)[\"']?(\s*[:=：]\s*|\s+)[\"']?(?=[A-Za-z0-9_\-+/=.]*\d)[A-Za-z0-9_\-+/=.]{16,}"),
    ("秘密の値(ハッシュの名前)", r"(?i)sha-?256"),
    ("弱点・攻撃の手順", r"(?i)(脆弱性|攻撃手順|攻撃の手順|exploit|payload|bypass|権限昇格|privilege escalation|injection)"),
    ("DBの名前・接続先",
     r"(?i)(postgres(ql)?://|mysql://|mongodb(\+srv)?://|neon\.tech|database_url|database_id|database_name|\bdb_?name\b|\bd1\b.*\bid\b)"),
    ("金額", r"(?i)(¥\s*\d|\d[\d,]*\s*(円|万円)|\$\s*\d|\d[\d,.]*\s*(usd|jpy|ドル))"),
    ("メールアドレス", r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"),
]

NOTICES = [
    ("注意: パス", r"(?i)(\b[A-Z]:\\|/workspace|/home/|/Users/|/private/tmp|~/|/mnt/|/cursor/stores|/opt/)"),
    ("注意: 機械の名前", r"(?i)(mac\s*-?mini|\bwsl\b)"),
    ("注意: 16進の並び(コミット番号などなら問題なし)", r"\b(?=[0-9a-fA-F]*[a-fA-F])[0-9a-fA-F]{7,63}\b"),
    ("注意: 64字以上の16進", r"\b[0-9a-fA-F]{64,}\b"),
    ("注意: 26字の並び", r"\b(?=[A-Za-z0-9]*[A-Za-z])(?=[A-Za-z0-9]*[0-9])[A-Za-z0-9]{26}\b"),
    ("注意: UUIDの形", r"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"),
    ("注意: opの呼び出し", r"(?i)\bop\s+(read|item|signin|whoami|vault|run|inject)\b"),
]

# 付けてよいリンク（Notion の PBI、GitHub の issue・PR・コミット）は、16進と ID の検査の前に外す
ALLOWED_URL = re.compile(
    r"https://(app\.notion\.com/p/[0-9a-f]{32}|www\.notion\.so/[^\s)]*|github\.com/[\w.\-]+/[\w.\-]+/"
    r"((issues|pull)/\d+(#issuecomment-\d+)?|(blob|tree|commit)/[^\s)]+))(\?pvs=\d+)?")
URL_SENSITIVE = {"注意: 26字の並び", "注意: 16進の並び(コミット番号などなら問題なし)"}


def load_extra(path):
    if not path:
        return []
    with open(path, encoding="utf-8") as f:
        return [w.strip() for w in f if w.strip() and not w.startswith("#")]


def check(text, extra=()):
    """本文を調べて (止めるもの, 注意) を返す。どちらも (規則の名前, 行番号, 件数) の並び。"""
    hits, notes = [], []
    for n, line in enumerate(text.splitlines(), 1):
        stripped = ALLOWED_URL.sub(" ", line)
        for name, pat in RULES:
            c = len(re.findall(pat, stripped if name in URL_SENSITIVE else line))
            if c:
                hits.append((name, n, c))
        for name, pat in NOTICES:
            c = len(re.findall(pat, stripped if name in URL_SENSITIVE else line))
            if c:
                notes.append((name, n, c))
        for i, w in enumerate(extra, 1):
            c = line.lower().count(w.lower())
            if c:
                hits.append((f"追加の禁止語 {i} 番目", n, c))
    return hits, notes


def report(hits, notes, lines):
    out = [f"  {n} 行目: {name} × {c}（止めない。書いてよいか自分で確かめる）" for name, n, c in notes]
    if hits:
        out.append(f"止める: {len(hits)} 件引っかかりました（当たった文字は表示しません）")
        out += [f"  {n} 行目: {name} × {c}" for name, n, c in hits]
    else:
        out.append(f"OK: 引っかかり 0 件（{lines} 行、{len(RULES)} 規則）")
    return "\n".join(out)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--extra", metavar="禁止語ファイル",
                        help="追加の禁止語ファイル（環境変数 PUBLIC_TEXT_EXTRA_FILE より優先。最後の指定が効く）")
    parser.add_argument("--json", action="store_true", help="機械向けの JSON で出す")
    parser.add_argument("files", nargs="*", metavar="ファイル", help="調べるファイル。無ければ標準入力")
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)
    extra_path = args.extra or os.environ.get("PUBLIC_TEXT_EXTRA_FILE") or None
    as_json = args.json
    files = args.files
    if files:
        parts = []
        for fp in files:
            with open(fp, encoding="utf-8") as f:
                parts.append(f.read())
        text = "\n".join(parts)
    else:
        text = sys.stdin.read()
    if not text.strip():
        print("止める: 文が空です")
        return 2
    hits, notes = check(text, load_extra(extra_path))
    if as_json:
        print(json.dumps({"ok": not hits,
                          "hits": [{"rule": r, "line": n, "count": c} for r, n, c in hits],
                          "notices": [{"rule": r, "line": n, "count": c} for r, n, c in notes]},
                         ensure_ascii=False))
    else:
        print(report(hits, notes, len(text.splitlines())))
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
