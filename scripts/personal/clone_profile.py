#!/usr/bin/env python3
"""Back up and clone a closed Zen profile. Never moves/deletes the source.

The report and backup contain private profile metadata; store them outside Git.
This does not change the installed app, default browser or 1Password trust.
"""
import argparse
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
from urllib.parse import quote
import jsonlz4


def fingerprint(root):
    result = {}
    for p in sorted(root.rglob('*')):
        if p.is_symlink():
            result[str(p.relative_to(root))] = 'symlink:' + os.readlink(p)
        elif p.is_file():
            result[str(p.relative_to(root))] = hashlib.sha256(p.read_bytes()).hexdigest()
    return result


def inventory(root):
    report = {}
    queries = {
        'places.sqlite': {'bookmarks': 'SELECT count(*) FROM moz_bookmarks WHERE type=1',
                          'bookmark_folders': 'SELECT count(*) FROM moz_bookmarks WHERE type=2',
                          'history_visits': 'SELECT count(*) FROM moz_historyvisits'},
        'cookies.sqlite': {'cookies': 'SELECT count(*) FROM moz_cookies'},
    }
    for filename, statements in queries.items():
        if not (root / filename).exists():
            continue
        wal = root / (filename + '-wal')
        if wal.exists() and wal.stat().st_size:
            raise RuntimeError('Database still has an uncheckpointed WAL: ' + filename)
        # These databases are closed and checkpointed. Immutable inspection avoids
        # creating -shm files in the preserved source or backup.
        with closing(sqlite3.connect((root / filename).as_uri() + '?mode=ro&immutable=1', uri=True)) as db:
            assert db.execute('PRAGMA quick_check').fetchone()[0] == 'ok', filename
            report.update({key: db.execute(sql).fetchone()[0] for key, sql in statements.items()})
    if (root / 'extensions.json').exists():
        addons = json.loads((root / 'extensions.json').read_text()).get('addons', [])
        active = [a for a in addons if a.get('active') and a.get('type') == 'extension']
        report['active_installed_extensions'] = sum(not a.get('isSystem') and not a.get('location', '').startswith('app-builtin') for a in active)
        report['active_builtin_extensions'] = sum(a.get('location', '').startswith('app-builtin') for a in active)
    if (root / 'logins.json').exists():
        report['encrypted_logins'] = len(json.loads((root / 'logins.json').read_text()).get('logins', []))
    session = root / 'sessionstore.jsonlz4'
    if session.exists():
        windows = jsonlz4.loads(session.read_bytes()).get('windows', [])
        report['session_windows'] = len(windows)
        report['session_tabs'] = sum(len(w.get('tabs', [])) for w in windows)
    return report


def clone_profile(source, destination, backup, resume_verified_backup=False):
    os.umask(0o077)
    source_alias = source.expanduser().absolute()
    source, destination, backup = (p.expanduser().resolve() for p in (source, destination, backup))
    if destination.exists() or (backup.exists() and not resume_verified_backup):
        raise RuntimeError('Destination and backup must be new; never overwrite profiles')
    if source == destination or source in destination.parents or source in backup.parents:
        raise RuntimeError('Profile paths must be separate')
    if not (source / 'prefs.js').is_file():
        raise RuntimeError('Source is not a browser profile')
    processes = subprocess.check_output(['ps', '-axo', 'command='], text=True)
    if any(line.startswith('/Applications/Zen.app/Contents/MacOS/') for line in processes.splitlines()):
        raise RuntimeError('Quit main Zen normally before cloning its profile')
    for filename in ('.parentlock', 'places.sqlite', 'cookies.sqlite'):
        p = source / filename
        if p.exists() and subprocess.run(['lsof', '-t', str(p)], capture_output=True).stdout.strip():
            raise RuntimeError('Source is still open: ' + filename)
    before = fingerprint(source)
    baseline = inventory(source)
    snapshot = backup / 'Original Profile'
    if backup.exists():
        if not snapshot.is_dir() or set(backup.iterdir()) != {snapshot}:
            raise RuntimeError('Resume requires only an untouched Original Profile snapshot')
    else:
        backup.mkdir(mode=0o700, parents=True)
        shutil.copytree(source, snapshot, symlinks=True)
    assert fingerprint(snapshot) == before, 'Backup does not match source'
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    shutil.copytree(snapshot, destination, symlinks=True)
    destination.chmod(0o700)
    assert fingerprint(destination) == before, 'Clone differs before rebasing'

    replacements = []
    for old_path in sorted({str(source), str(source_alias)}, key=len, reverse=True):
        replacements.append((old_path, str(destination)))
        for safe in ('/', '/()'):
            replacements.append((quote(old_path, safe=safe), quote(str(destination), safe=safe)))

    def rebase(value):
        if isinstance(value, str):
            for old, new in replacements:
                value = value.replace(old, new)
            return value
        if isinstance(value, dict):
            return {rebase(k): rebase(v) for k, v in value.items()}
        if isinstance(value, list):
            return [rebase(v) for v in value]
        return value

    changed = []
    for filename in ('extensions.json', 'addonStartup.json.lz4'):
        p = destination / filename
        if p.exists():
            compressed = filename.endswith('.lz4')
            old = jsonlz4.loads(p.read_bytes()) if compressed else json.loads(p.read_text())
            new = rebase(old)
            if old != new:
                p.write_bytes(jsonlz4.dumps(new) if compressed else (json.dumps(new, ensure_ascii=False) + '\n').encode())
                changed.append(filename)
    for filename in ('pkcs11.txt', 'prefs.js'):
        p = destination / filename
        if p.exists():
            old = p.read_text()
            new = rebase(old)
            if filename == 'prefs.js':
                for name, value in [('zen.view.use-single-toolbar', 'false'), ('browser.startup.page', '3')]:
                    new = re.sub(r'^user_pref\("' + re.escape(name) + r'", .*\);\n?', '', new, flags=re.M)
                    new += f'\nuser_pref("{name}", {value});\n'
            if old != new:
                p.write_text(new)
                changed.append(filename)
    after = fingerprint(destination)
    assert set(after) == set(before), 'Unexpected file set change'
    assert {name for name in before if before[name] != after[name]} == set(changed), 'Unexpected clone change'
    assert inventory(destination) == baseline, 'Profile inventory changed'
    assert fingerprint(source) == before, 'Source changed during clone'
    report = {'source': str(source), 'production_profile': str(destination), 'backup': str(backup),
              'status': 'backed-up-and-cloned-verified', 'original_files': len(before),
              'source_unchanged': True, 'inventory': baseline, 'rebased_files': changed,
              'profile_files_sha256': before, 'copy_credential_material_decrypted': False}
    (backup / 'Profile Verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'profile_files_sha256'}))
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--backup', type=Path, required=True)
    parser.add_argument('--resume-verified-backup', action='store_true',
                        help='Reuse only a byte-identical backup left by an interrupted pre-clone check')
    args = parser.parse_args()
    clone_profile(args.source, args.destination, args.backup, args.resume_verified_backup)
