"""Build only the local native URL-opening test fixture; never launches it."""
from pathlib import Path
import plistlib
import subprocess

root = Path(__file__).resolve().parents[1]
app = root / 'dist/external-link-harness/External Link Harness.app'
macos = app / 'Contents/MacOS'
macos.mkdir(parents=True, exist_ok=False)
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleName': 'External Link Harness', 'CFBundleIdentifier': 'com.kimkhoi.zen.linkharness',
    'CFBundleExecutable': 'link-harness', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
    'NSHighResolutionCapable': True,
}))
subprocess.run(['clang', '-fobjc-arc', '-framework', 'Cocoa',
                str(root / 'Generation Scripts/External Link Harness.m'),
                '-o', str(macos / 'link-harness')], check=True)
subprocess.run(['codesign', '--sign', '-', str(app)], check=True)
print(app)
