#!/usr/bin/env python3
"""同梱の日本語フォントを正規 Noto CJK コレクションから再生成する。"""

import argparse
import hashlib
import json
from pathlib import Path

from fontTools import subset
from fontTools.ttLib import TTCollection


def japanese_codepoints():
    # JIS X 0213 の両面を含め、画面の現行文言だけに限定しない。
    chars = set()
    for first in range(0xA1, 0xFF):
        for second in range(0xA1, 0xFF):
            for prefix in (b"", b"\x8f"):
                try:
                    chars.update((prefix + bytes((first, second))).decode("euc_jis_2004"))
                except UnicodeDecodeError:
                    pass
    points = {ord(char) for char in chars}
    for start, end in ((0x20, 0x024F), (0x2000, 0x206F), (0x3000, 0x30FF),
                       (0x31F0, 0x31FF), (0xFE00, 0xFE0F), (0xFF00, 0xFFEF),
                       (0xE0100, 0xE01EF)):
        points.update(range(start, end + 1))
    return points


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", type=Path, default=Path("/usr/share/fonts/opentype/noto"))
    parser.add_argument("--output-dir", type=Path, default=Path("flutter/assets/fonts"))
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    points = japanese_codepoints()
    result = []
    for weight in ("Regular", "Bold"):
        source = args.source_dir / f"NotoSansCJK-{weight}.ttc"
        font = TTCollection(source).fonts[0]
        if font["name"].getDebugName(1) != "Noto Sans CJK JP":
            raise ValueError("Expected the Japanese face at index 0")
        original_version = font["name"].getDebugName(5)
        options = subset.Options()
        options.name_IDs = [0, 1, 2, 3, 4, 5, 6, 8, 9, 11, 13, 14, 16, 17]
        options.name_legacy = True
        options.name_languages = ["*"]
        # 日本語と既定の shaping は残し、CJK 他地域への置換専用 glyph の連鎖を避ける。
        options.layout_scripts = ["DFLT"] + [
            f"{script}.{lang}" for script in ("cyrl", "grek", "hang", "hani", "kana", "latn")
            for lang in ("dflt", "JAN")
        ]
        sub = subset.Subsetter(options=options)
        sub.populate(unicodes=points)
        sub.subset(font)
        # 変更版は upstream の名前を名乗らず、著作権・ライセンス情報を保持する。
        names = {1: "R2 Gallery JP", 2: weight, 3: f"R2GalleryJP-{weight}-1.0",
                 4: f"R2 Gallery JP {weight}", 6: f"R2GalleryJP-{weight}",
                 16: "R2 Gallery JP", 17: weight}
        for record in font["name"].names:
            if record.nameID in names:
                record.string = names[record.nameID].encode(record.getEncoding())
        cff = font["CFF "].cff
        cff.fontNames = [f"R2GalleryJP-{weight}"]
        cff.topDictIndex[0].FamilyName = "R2 Gallery JP"
        cff.topDictIndex[0].FullName = f"R2 Gallery JP {weight}"
        font.recalcTimestamp = False
        output = args.output_dir / f"R2GalleryJP-{weight}.otf"
        font.save(output)
        result.append({"file": output.name, "bytes": output.stat().st_size,
                       "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
                       "source": str(source), "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                       "source_version": original_version, "unicode_count": len(font.getBestCmap()),
                       "glyph_count": len(font.getGlyphOrder())})
    (args.output_dir / "manifest.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
