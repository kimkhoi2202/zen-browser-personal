#!/usr/bin/env python3
"""Complete the personal.14 candidate after Apple's transient timestamp failure.

The builder's nested signing was rerun successfully with --timestamp. Verify the
archived UI against the clean source before finishing engine/outer identities.
This script never opens a profile, installs an app, or publishes anything.
"""
import json
from pathlib import Path
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts/personal'))
from build_macos import (ADDITIONAL_UI, CONTROLLER, INPUT_BASE, VIEW, HELPER,
                        ZEN_CONTROLLER, sha, source_metadata, verify_engine_identity)
from ui_patch import patch_controller, patch_input, patch_view, patch_providers_manager

BASE = Path('/Applications/Zen (Official).app')
OUT = ROOT / 'dist/command-palette-production-14-ready'
APP = OUT / 'Zen.app'
IDENTITY = 'C30023C18D0E672B1335F817756776C59554A78D'

if subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT).strip():
    raise SystemExit('Commit the reviewed source first')
if (OUT / 'Build Manifest.json').exists():
    raise SystemExit('Manifest already exists; do not overwrite a verified build')

def vendor_entry(archive, entry):
    # Apple's unzip understands Mozilla's optimized archive layout.
    result = subprocess.run(['unzip', '-p', str(archive), entry], capture_output=True)
    if not result.stdout:
        raise RuntimeError('Missing official entry: ' + entry)
    return result.stdout.decode()

with zipfile.ZipFile(APP / 'Contents/Resources/browser/omni.ja') as archive:
    for target, source in {**ADDITIONAL_UI,
                          HELPER: 'src/zen/urlbar/PersonalSiteSearch.mjs',
                          ZEN_CONTROLLER: 'src/zen/urlbar/ZenUrlbarController.mjs'}.items():
        assert archive.read(target) == (ROOT / source).read_bytes(), target
    for entry, patch in [(CONTROLLER, patch_controller), (INPUT_BASE, patch_input), (VIEW, patch_view)]:
        assert archive.read(entry).decode() == patch(vendor_entry(BASE / 'Contents/Resources/browser/omni.ja', entry)), entry

manager = 'moz-src/browser/components/urlbar/UrlbarProvidersManager.sys.mjs'
with zipfile.ZipFile(APP / 'Contents/Resources/omni.ja') as archive:
    assert archive.read(manager).decode() == patch_providers_manager(vendor_entry(BASE / 'Contents/Resources/omni.ja', manager))

subprocess.run(['codesign', '--verify', '--deep', '--strict', str(APP)], check=True)
common = ['--force', '--sign', IDENTITY, '--options', 'runtime', '--timestamp',
          '--entitlements', str(ROOT / 'personal/entitlements.plist')]
subprocess.run(['codesign', *common, '--identifier', 'com.kimkhoi.zen',
                str(APP / 'Contents/MacOS/zen-engine')], check=True)
subprocess.run(['codesign', *common, str(APP)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(APP)], check=True)
verify_engine_identity(APP)

# Keep the verified builder report schema; all base/channel fields are identical.
report = json.loads((ROOT / 'dist/command-palette-production-14c/Build Manifest.json').read_text())
assert report['bundle_id'] == 'com.kimkhoi.zen'
assert report['upstream']['commit'] == '541ee55196395ee8082862b83c84c90ab41d9f6d'
assert report['base_archive_sha256'] == sha(BASE / 'Contents/Resources/browser/omni.ja')
assert report['base_platform_archive_sha256'] == sha(BASE / 'Contents/Resources/omni.ja')
report.update(app=str(APP), source=source_metadata(),
              modified_archive_sha256=sha(APP / 'Contents/Resources/browser/omni.ja'),
              modified_platform_archive_sha256=sha(APP / 'Contents/Resources/omni.ja'),
              signing_recovery='Nested signing retried with Apple timestamps; archived UI verified against source')
(OUT / 'Build Manifest.json').write_text(json.dumps(report, indent=2) + '\n')
print('Verified source archives and completed signed personal.14 candidate')
