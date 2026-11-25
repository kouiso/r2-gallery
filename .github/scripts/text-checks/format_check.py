#!/usr/bin/env python3
"""issue と PR の本文の書き方を調べる（brain #110 の 2）。AI は使わず、文字の規則だけで判定する。

issue: 次の5つの見出しがあり、中身が書いてあること。
  背景 / 今どこまで（今の状態 も可）/ 次にやること / 誰の判断待ち / 完了条件（完了の条件 も可）
PR:    概要 / 変更内容 / 関連Issue（中に #番号 か issue の URL があること。`Closes` / `Refs` でも可）
見出しだけ、「-」だけ、HTMLコメントだけ、「なし」「未記入」だけは未記入として扱う。
見出しの深さ（# の数）と、前の「①」などの番号は問わない。
前後の空白、全角と半角の括弧、絵文字、「(Why?)」のような括弧つきでも、見出しに名前や別名が含まれていれば同じ欄と見る。

使う側は設定ファイルで別名を足せる（既定の名前は、設定があってもそのまま通る）。
  {"issue": {"aliases": {"背景": ["(Why?)"]}, "optional": []},
   "pr": {"aliases": {"関連Issue": ["Issue リンク"]}, "extra_sections": ["見て欲しいポイント"]}}
CLI は --config パス。無ければ環境変数 TEXT_CHECKS_CONFIG。関数は check(text, kind, config=None)。

使い方:
  python3 script/checks/format_check.py --kind issue 本文.md
  python3 script/checks/format_check.py --kind issue --config 設定.json 本文.md
  printf '%s' "$BODY" | python3 script/checks/format_check.py --kind pr --json
終了コード: 0=そろっている、1=足りない、2=使い方または設定の誤り。
"""
import json
import os
import re
import sys
from pathlib import Path

ISSUE_SECTIONS = [
    ("背景", ("背景",)),
    ("今どこまで", ("今どこまで", "今の状態")),
    ("次にやること", ("次にやること",)),
    ("誰の判断待ち", ("誰の判断待ち",)),
    ("完了条件", ("完了条件", "完了の条件")),
]
PR_SECTIONS = [
    ("概要", ("概要",)),
    ("変更内容", ("変更内容",)),
    ("関連Issue", ("関連issue", "関連 issue")),
]
LINK = re.compile(r"(?i)\b(close[sd]?|fix(e[sd])?|resolve[sd]?|refs?)\s+([\w.\-]+/[\w.\-]+)?#\d+")
ISSUE_URL = re.compile(r"https?://github\.com/[\w.\-]+/[\w.\-]+/issues/\d+", re.I)
HASH_ISSUE = re.compile(r"(^|[^A-Za-z0-9_])#\d+\b")
HEADING = re.compile(r"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
EMPTY_WORDS = {"", "-", "ー", "なし", "未記入", "tbd", "todo", "n/a"}
WIDTH = str.maketrans({
    "（": "(", "）": ")", "［": "[", "］": "]", "｛": "{", "｝": "}",
    "？": "?", "！": "!", "：": ":", "；": ";", "　": " ",
})
KIND_KEYS = {"aliases", "extra_sections", "optional"}


class ConfigError(ValueError):
    """設定ファイルの中身や指定が正しくない。"""


def sections(text):
    """見出しごとに本文を分ける。返り値は {見出しの文字: 中身}。

    小見出し（# が今開いている欄より深い行）はその行ごと直前の欄の中身に入れる。
    欄の中身を小見出し以下に書く形で、親の欄が空扱いになるのを防ぐため。
    同じ名前の見出しが2回出たら中身をつなげる。片方が空でもう片方に書いた形で、
    先に出た空欄だけが残るのを防ぐため。
    """
    out, current, depth, buf = {}, None, 0, []
    for line in text.splitlines():
        m = HEADING.match(line)
        if m:
            level = len(m.group(1))
            if current is None or level <= depth:
                if current is not None:
                    body = "\n".join(buf)
                    out[current] = (out[current] + "\n" + body).strip("\n") if current in out else body
                current, depth, buf = m.group(2).strip(), level, []
            else:
                buf.append(line)
        elif current is not None:
            buf.append(line)
    if current is not None:
        body = "\n".join(buf)
        out[current] = (out[current] + "\n" + body).strip("\n") if current in out else body
    return out


def normalize_title(title):
    """照合用に、空白と全角半角の括弧・記号をそろえる。"""
    t = (title or "").strip().translate(WIDTH).lower()
    t = re.sub(r"\s+", " ", t)
    t = re.sub(r"\s*\(\s*", "(", t)
    t = re.sub(r"\s*\)\s*", ")", t)
    return t


def heading_matches(title, names):
    """見出しに、欄の名前または別名が含まれていれば True。"""
    t = normalize_title(title)
    if not t:
        return False
    for name in names:
        n = normalize_title(name)
        if n and n in t:
            return True
    return False


def is_empty(body):
    body = re.sub(r"<!--.*?-->", "", body, flags=re.S)
    # チェックボックスの印（[ ]・[x]）は中身の有無に関係ないので外す。
    # 外さないとフォーム初期値の「- [ ]」だけの欄が記入済みに見える。
    # 小見出し行も外す。小見出しは sections で親の欄の中身に入るので、
    # 見出しだけで本文が無い欄が記入済みに見えるのを防ぐため。
    rest = [
        re.sub(r"^\[\s*[xX]?\]\s*", "", ln.strip().lstrip("-*• ")).strip()
        for ln in body.splitlines()
        if not HEADING.match(ln)
    ]
    return all(r.lower() in EMPTY_WORDS for r in rest)


def has_issue_ref(body):
    """#番号、issue の URL、または Closes / Refs #番号 があれば True。"""
    return bool(LINK.search(body) or ISSUE_URL.search(body) or HASH_ISSUE.search(body))


def _known_labels(kind):
    base = ISSUE_SECTIONS if kind == "issue" else PR_SECTIONS
    return [label for label, _ in base]


def _resolve_label(key, known):
    for label in known:
        if key == label or key.lower() == label.lower():
            return label
    return None


def _string_list(value, where):
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(x, str) and x.strip() for x in value):
        raise ConfigError(f"「{where}」は空でない文字列の配列にしてください")
    return [x.strip() for x in value]


def validate_config(data):
    """設定の dict を検査して正規化する。未指定は None。"""
    if data is None:
        return None
    if not isinstance(data, dict):
        raise ConfigError("設定のトップはオブジェクトにしてください")
    unknown = set(data) - {"issue", "pr"}
    if unknown:
        raise ConfigError("設定のキーが違います: " + ", ".join(sorted(unknown)))
    out = {}
    for kind in ("issue", "pr"):
        if kind not in data:
            continue
        block = data[kind]
        if not isinstance(block, dict):
            raise ConfigError(f"「{kind}」はオブジェクトにしてください")
        bad = set(block) - KIND_KEYS
        if bad:
            raise ConfigError(f"「{kind}」のキーが違います: " + ", ".join(sorted(bad)))
        extras = _string_list(block.get("extra_sections"), f"{kind}.extra_sections")
        defaults = _known_labels(kind)
        for name in extras:
            if _resolve_label(name, defaults):
                raise ConfigError(
                    f"「{kind}.extra_sections」の「{name}」は既定の見出しです。aliases に書いてください"
                )
        known = defaults + extras
        aliases_in = block.get("aliases", {})
        if aliases_in is None:
            aliases_in = {}
        if not isinstance(aliases_in, dict):
            raise ConfigError(f"「{kind}.aliases」はオブジェクトにしてください")
        aliases = {}
        for key, val in aliases_in.items():
            if not isinstance(key, str) or not key.strip():
                raise ConfigError(f"「{kind}.aliases」のキーは空でない文字列にしてください")
            label = _resolve_label(key.strip(), known)
            if label is None:
                raise ConfigError(f"「{kind}.aliases」のキー「{key}」は見出しにありません")
            aliases[label] = _string_list(val, f"{kind}.aliases.{key}")
        optional = _string_list(block.get("optional"), f"{kind}.optional")
        resolved_optional = []
        for name in optional:
            label = _resolve_label(name, known)
            if label is None:
                raise ConfigError(f"「{kind}.optional」の「{name}」は見出しにありません")
            resolved_optional.append(label)
        out[kind] = {"aliases": aliases, "extra_sections": extras, "optional": resolved_optional}
    return out


def load_config(source):
    """パスまたは dict を読んで検査する。未指定は None。失敗は ConfigError。"""
    if source is None or source == "":
        return None
    if isinstance(source, dict):
        return validate_config(source)
    path = Path(source)
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ConfigError(f"設定ファイルが読めません: {exc}")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ConfigError(f"設定がJSONではありません: {exc}")
    return validate_config(data)


def section_plan(kind, config=None):
    """検査する見出しの一覧を返す。各要素は (正式名, 名前と別名, 任意か)。"""
    if kind not in ("issue", "pr"):
        raise ConfigError("--kind は issue か pr です")
    cfg = (config or {}).get(kind) or {}
    aliases = cfg.get("aliases") or {}
    extras = cfg.get("extra_sections") or []
    optional = set(cfg.get("optional") or [])
    base = ISSUE_SECTIONS if kind == "issue" else PR_SECTIONS
    plan = []
    for label, names in base:
        plan.append((label, tuple(names) + tuple(aliases.get(label, ())), label in optional))
    for label in extras:
        names = (label,) + tuple(aliases.get(label, ()))
        plan.append((label, names, label in optional))
    return plan


def check(text, kind, config=None):
    """足りないものの一覧を返す。空ならそろっている。

    config は検査済みの dict、ファイルのパス、または None。
    設定が不正なときは ConfigError を送る。
    """
    if kind not in ("issue", "pr"):
        raise ConfigError("--kind は issue か pr です")
    cfg = load_config(config) if not isinstance(config, dict) else validate_config(config)
    found = sections(text)
    problems = []
    for label, names, optional in section_plan(kind, cfg):
        body = next((found[t] for t in found if heading_matches(t, names)), None)
        if body is None:
            if optional:
                continue
            problems.append(f"見出し「{label}」がありません")
        elif is_empty(body):
            problems.append(f"「{label}」が未記入です")
        elif kind == "pr" and label == "関連Issue" and not has_issue_ref(body):
            problems.append("「関連Issue」に #番号 か issue の URL がありません")
    return problems


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    kind, as_json, config_path, files = "issue", False, None, []
    i = 0
    while i < len(args):
        if args[i] in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        if args[i] == "--kind":
            if i + 1 >= len(args):
                print("--kind には issue か pr を付けてください", file=sys.stderr)
                return 2
            kind = args[i + 1]
            i += 2
        elif args[i] == "--config":
            if i + 1 >= len(args):
                print("--config には設定ファイルのパスを付けてください", file=sys.stderr)
                return 2
            config_path = args[i + 1]
            i += 2
        elif args[i] == "--json":
            as_json = True
            i += 1
        elif args[i].startswith("-"):
            print("使える引数は --kind --config --json とファイルです", file=sys.stderr)
            return 2
        else:
            files.append(args[i])
            i += 1
    if kind not in ("issue", "pr"):
        print("--kind は issue か pr です", file=sys.stderr)
        return 2
    if len(files) > 1:
        print("ファイルは1つだけ指定してください", file=sys.stderr)
        return 2
    if config_path is None:
        config_path = os.environ.get("TEXT_CHECKS_CONFIG") or None
    try:
        config = load_config(config_path)
        if files:
            text = Path(files[0]).read_text(encoding="utf-8")
        else:
            text = sys.stdin.read()
        problems = check(text, kind, config)
    except ConfigError as exc:
        print(str(exc), file=sys.stderr)
        if as_json:
            print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        return 2
    except OSError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    if as_json:
        print(json.dumps({"ok": not problems, "kind": kind, "problems": problems}, ensure_ascii=False))
    elif problems:
        print(f"足りない: {len(problems)} 件（{kind}）")
        print("\n".join("  - " + p for p in problems))
    else:
        print(f"OK: 書き方がそろっています（{kind}）")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
