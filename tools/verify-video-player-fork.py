#!/usr/bin/env python3
"""PiP用の最小forkが、許可した3ファイル以外のupstreamを変えていないか確認する。"""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
plugin = root / 'native_plugins/video_player_avfoundation'
manifest = json.loads((plugin / 'upstream-files.json').read_text())
allowed = {
    'darwin/video_player_avfoundation/Sources/video_player_avfoundation/VideoPlayerPlugin.swift',
    'darwin/video_player_avfoundation/Sources/video_player_avfoundation_objc/FVPTextureBasedVideoPlayer.m',
    'darwin/video_player_avfoundation/Sources/video_player_avfoundation_objc/include/video_player_avfoundation_objc/FVPTextureBasedVideoPlayer.h',
}
changed = {
    name for name, expected in manifest['files'].items()
    if hashlib.sha256((plugin / name).read_bytes()).hexdigest() != expected
}
assert changed == allowed, f'Unexpected upstream changes: {sorted(changed ^ allowed)}'
assert len(manifest['files']) == 42
assert manifest['version'] == '2.12.1'
print(json.dumps({
    'package': manifest['package'], 'version': manifest['version'],
    'upstream_files': len(manifest['files']), 'unchanged': len(manifest['files']) - len(changed),
    'changed': sorted(changed), 'status': 'PASS',
}, indent=2))
