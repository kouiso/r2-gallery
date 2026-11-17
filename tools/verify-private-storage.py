#!/usr/bin/env python3
"""SDKを使わず保存・backup・公開providerの宣言を点検する。native実行検証は別途必要。"""
import json
import plistlib
from pathlib import Path
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
android = '{http://schemas.android.com/apk/res/android}'
manifest = ET.parse(root / 'flutter/android/app/src/main/AndroidManifest.xml').getroot()
app = manifest.find('application')
assert app.get(android + 'allowBackup') == 'false'
assert app.get(android + 'fullBackupContent') == '@xml/backup_rules'
assert app.get(android + 'dataExtractionRules') == '@xml/data_extraction_rules'
permissions = {p.get(android + 'name') for p in manifest.findall('uses-permission')}
assert 'android.permission.WRITE_EXTERNAL_STORAGE' not in permissions
assert not manifest.findall('.//provider')
domains = {'root', 'file', 'database', 'sharedpref', 'external',
           'device_root', 'device_file', 'device_database', 'device_sharedpref'}
resources = root / 'flutter/android/app/src/main/res/xml'
legacy = ET.parse(resources / 'backup_rules.xml').getroot()
modern = ET.parse(resources / 'data_extraction_rules.xml').getroot()
for node in [legacy, modern.find('cloud-backup'), modern.find('device-transfer')]:
    assert {p.get('domain') for p in node.findall('exclude')} == domains
    assert all(p.tag == 'exclude' and p.get('path') == '.' for p in node)

plugins = json.loads((root / 'flutter/.flutter-plugins-dependencies').read_text())
inspected = []
for plugin in plugins['plugins']['android']:
    path = Path(plugin['path']) / 'android/src/main/AndroidManifest.xml'
    if not path.exists():
        continue
    inspected.append(plugin['name'])
    assert not ET.parse(path).getroot().findall('.//provider'), plugin['name']

info = plistlib.loads((root / 'flutter/ios/Runner/Info.plist').read_bytes())
assert info['UIFileSharingEnabled'] is False
assert info['LSSupportsOpeningDocumentsInPlace'] is False
pbx = (root / 'flutter/ios/Runner.xcodeproj/project.pbxproj').read_text()
assert pbx.count('A26E0B120000000000000003') == 3
assert pbx.count('A26E0B120000000000000004') == 2
print(json.dumps({
    'status': 'PASS',
    'scope': 'Static declarations only; NOT merged manifest, native build or device runtime',
    'android': {'allowBackup': False, 'excluded_domains': sorted(domains),
                'modes': ['legacy backup', 'cloud-backup', 'device-transfer'],
                'write_external_permission': False, 'app_providers': [],
                'dependency_manifests_inspected': inspected, 'dependency_providers': []},
    'ios': {'fileSharing': False, 'documentsInPlace': False, 'bridge_in_xcode_sources': True},
    'native_build': 'NOT RUN: explicitly held pending SDK license response; no Mac used',
    'device_runtime': 'NOT RUN',
}, ensure_ascii=False, indent=2))
