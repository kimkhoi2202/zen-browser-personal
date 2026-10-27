#!/usr/bin/env python3
"""Copy only site searches/shortcuts into a closed Dev profile, never credentials."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess

parser=argparse.ArgumentParser()
parser.add_argument('--source',type=Path,required=True)
args=parser.parse_args()
target=Path.home()/'Library/Application Support/Zen Personal/Dev'
if subprocess.run(['pgrep','-f',r'^.*/Zen(?: Dev| \(Dev\))\.app/Contents/MacOS/zen-engine'],capture_output=True).returncode==0:
    raise SystemExit('Quit Zen (Dev) normally before seeding its profile')
if (target/'.parentlock').exists() and subprocess.run(['lsof','-t',str(target/'.parentlock')],capture_output=True).stdout.strip():
    raise SystemExit('Dev profile is still open; quit its browser normally first')
source=args.source.expanduser().resolve()
if source==target.resolve():raise SystemExit('Source must differ from Dev')
source_prefs=(source/'prefs.js').read_text()
match=re.search(r'user_pref\("zen.keyboard.shortcuts.version", (\d+)\);',source_prefs)
if not match:raise SystemExit('Missing source keyboard migration version; inspect before copying')
version=int(match[1])
json.loads((source/'zen-keyboard-shortcuts.json').read_text())
assert (source/'search.json.mozlz4').read_bytes().startswith(b'mozLz40\0')
target.mkdir(mode=0o700,parents=True,exist_ok=True)
for name in ('search.json.mozlz4','zen-keyboard-shortcuts.json'):
    shutil.copy2(source/name,target/name);(target/name).chmod(0o600)
p=target/'prefs.js';prefs=p.read_text() if p.exists() else ''
prefs=re.sub(r'^user_pref\("zen.keyboard.shortcuts.version", \d+\);\n?', '',prefs,flags=re.M)
prefs+=f'\nuser_pref("zen.keyboard.shortcuts.version", {version});\n'
p.write_text(prefs);p.chmod(0o600)
print(json.dumps({'status':'dev-seeded','files':['search.json.mozlz4','zen-keyboard-shortcuts.json'],'keyboard_migration_version':version,'credentials_copied':False}))
