"""maestro hierarchy の JSON から、画面に出ている文字と読み上げラベルだけを抜き出して出す。"""
import json
import sys

KEYS = ("text", "accessibilityText", "hintText", "resource-id")


def walk(node, out):
    attrs = node.get("attributes", {})
    picked = [f"{k}={attrs[k]!r}" for k in KEYS if attrs.get(k)]
    if picked:
        out.append(" ".join(picked))
    for child in node.get("children", []):
        walk(child, out)


raw = sys.stdin.read()
start = raw.find("{")
if start < 0:
    print("hierarchy を取れませんでした:", raw.strip()[:500])
    sys.exit(0)
lines = []
walk(json.loads(raw[start:]), lines)
print("\n".join(lines))
