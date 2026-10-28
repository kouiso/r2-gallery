"""JUnit の結果から、段ごとの合否だけを GitHub の Step Summary 用の表にする。"""
import sys
import xml.etree.ElementTree as ET

LABELS = {
    "01-first-launch": "初回起動（埋め込みの接続先で写真タブまで）",
    "02-list": "一覧",
    "03-play": "動画の再生",
    "04-upload": "アップロード",
    "05-trash": "ゴミ箱へ送って復元",
}

path, ref = sys.argv[1], sys.argv[2]
print(f"## r2-gallery Maestro（{ref}）\n")
print("| 段 | 結果 |\n| --- | --- |")
try:
    cases = {c.get("name"): c for c in ET.parse(path).getroot().iter("testcase")}
except (OSError, ET.ParseError) as e:
    print(f"| 結果ファイル | 読めません（{type(e).__name__}）。Maestro まで進んでいません |")
    sys.exit(0)
for key, label in LABELS.items():
    case = cases.get(key)
    if case is None:
        result = "未実行"
    elif case.find("failure") is not None or case.find("error") is not None:
        result = "失敗"
    else:
        result = "成功"
    print(f"| {label} | {result} |")
