#!/usr/bin/env python3
"""Flutter 未実行でも、実フォントの収録文字・字形・出典を検証する。"""

import hashlib
import importlib.util
import json
import sys
from pathlib import Path

from fontTools.pens.recordingPen import RecordingPen
from fontTools.ttLib import TTCollection, TTFont

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("prepare_font", Path(__file__).with_name("prepare-japanese-font.py"))
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)
assets = Path("flutter/assets/fonts")
manifest = json.loads((assets / "manifest.json").read_text())
samples = "骨直令辺門葛辻道週返写真動画明音量保存ひらがなカタカナｶﾀｶﾅABCabc0123"


def outline(font, char):
    pen = RecordingPen()
    font.getGlyphSet()[font.getBestCmap()[ord(char)]].draw(pen)
    return pen.value


for entry in manifest:
    path = assets / entry["file"]
    actual_hash = hashlib.sha256(path.read_bytes()).hexdigest()
    assert actual_hash == entry["sha256"]
    source_path = Path(entry["source"])
    assert hashlib.sha256(source_path.read_bytes()).hexdigest() == entry["source_sha256"]
    source = TTCollection(source_path, lazy=True).fonts[0]
    font = TTFont(path)
    cmap = font.getBestCmap()
    expected = prepare.japanese_codepoints() & set(source.getBestCmap())
    assert expected <= set(cmap)
    assert all(ord(char) in cmap for char in samples)
    variation_count = 0
    source_variations = next(table for table in source["cmap"].tables if table.format == 14).uvsDict
    actual_variations = next(table for table in font["cmap"].tables if table.format == 14).uvsDict
    for selector, pairs in source_variations.items():
        if selector not in prepare.japanese_codepoints():
            continue
        actual_pairs = dict(actual_variations.get(selector, []))
        for base, glyph in pairs:
            if base in expected:
                assert base in actual_pairs and actual_pairs[base] == glyph
                variation_count += 1
    assert font["name"].getDebugName(1) == "R2 Gallery JP"
    weight = "Bold" if "Bold" in path.name else "Regular"
    assert font["name"].getDebugName(2) == weight
    assert font["OS/2"].usWeightClass == (700 if weight == "Bold" else 400)
    assert "SIL Open Font License" in font["name"].getDebugName(13)
    for tag in ("GSUB", "GPOS"):
        for script in font[tag].table.ScriptList.ScriptRecord:
            assert all(lang.LangSysTag.strip() == "JAN" for lang in script.Script.LangSysRecord)
    for char in samples:
        assert outline(font, char) == outline(source, char), f"Changed outline: {char}"
    print(f"PASS {path.name}: sha256={actual_hash}, bytes={path.stat().st_size}, mapped={len(cmap)}")
    print(f"PASS source Japanese face: {source['name'].getDebugName(1)} {source['name'].getDebugName(2)}")
    print(f"PASS requested coverage: {len(expected)} source-supported JIS/kana/punctuation/Latin codepoints")
    print(f"PASS original JP outlines preserved: {samples}")
    print(f"PASS family={font['name'].getDebugName(1)}, style={weight}, weight={font['OS/2'].usWeightClass}, OFL metadata")
    print(f"PASS Japanese/default shaping retained; Chinese/Korean LangSys removed; glyph_count={len(font.getGlyphOrder())}")
    print(f"PASS source-supported Japanese variation sequences retained: {variation_count}")
print("PASS font asset verification; Flutter rendering/screenshots/Android/Web runtime remain NOT RUN")
