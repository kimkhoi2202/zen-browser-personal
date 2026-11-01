"""Apply the startup module hotfix to a verified signed release copy.

This deliberately does not rerun the full packager on a custom app or use an
in-progress native build. The input must match the saved build manifest and
the old module in its recorded engine source. Outputs are always new copies.
"""
import argparse
import configparser
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import zipfile

from build_macos import CONFIG, ROOT, is_macho, run, sha, source_metadata, verify_engine_identity

MODULE = 'modules/zen/ZenSpaceManager.mjs'
SOURCE = 'src/zen/spaces/ZenSpaceManager.mjs'


def replace_module(archive, expected, replacement):
    temporary = archive.with_suffix('.hotfix')
    with zipfile.ZipFile(archive) as original:
        if original.read(MODULE) != expected:
            raise RuntimeError('The installed startup module differs from its recorded source')
        before = {entry.filename: hashlib.sha256(original.read(entry)).hexdigest()
                  for entry in original.infolist()}
        with zipfile.ZipFile(temporary, 'w') as updated:
            for entry in original.infolist():
                updated.writestr(entry, replacement if entry.filename == MODULE else original.read(entry))
    with zipfile.ZipFile(temporary) as updated:
        if updated.testzip():
            raise RuntimeError('Hotfix archive failed its CRC check')
        after = {entry.filename: hashlib.sha256(updated.read(entry)).hexdigest()
                 for entry in updated.infolist()}
    changed = [name for name in before.keys() | after.keys() if before.get(name) != after.get(name)]
    if changed != [MODULE]:
        raise RuntimeError('Hotfix changed unexpected archive entries: ' + repr(changed))
    temporary.replace(archive)
    return changed


def update(base, baseline_manifest, output, test=False):
    baseline = json.loads(baseline_manifest.read_text())
    identity = baseline['identity_fingerprint']
    if baseline['bundle_id'] != 'com.kimkhoi.zen' or baseline['source']['dirty']:
        raise RuntimeError('A clean production build manifest is required')
    if not baseline['engine'].startswith('source-built'):
        raise RuntimeError('Preserve the compiled PiP engine; use its source-built manifest')
    source = source_metadata()
    if source['dirty']:
        raise RuntimeError('Commit the reviewed hotfix source before packaging')
    info = plistlib.loads((base / 'Contents/Info.plist').read_bytes())
    if info['CFBundleIdentifier'] != baseline['bundle_id'] or info['CFBundleExecutable'] != 'zen-personal':
        raise RuntimeError('Input app does not match its production manifest')
    archive = base / 'Contents/Resources/browser/omni.ja'
    platform = base / 'Contents/Resources/omni.ja'
    if sha(archive) != baseline['modified_archive_sha256'] or sha(platform) != baseline['modified_platform_archive_sha256']:
        raise RuntimeError('Input app archives do not match the attested build')
    native_metadata = configparser.ConfigParser(interpolation=None)
    native_metadata.read(base / 'Contents/Resources/application.ini')
    if native_metadata['App']['SourceStamp'] != baseline['engine_source_commit']:
        raise RuntimeError('Input native engine differs from its manifest')
    run('codesign', '--verify', '--deep', '--strict', base, capture_output=True)
    verify_engine_identity(base)
    old_module = subprocess.check_output(['git', 'show', baseline['engine_source_commit'] + ':' + SOURCE], cwd=ROOT)
    settings = ({'appName': 'Zen (Dev - Links)', 'bundleId': 'com.kimkhoi.zen.dev.links',
                 'profileDirectory': 'External Link Test', 'remotingName': 'zen-personal-dev-links'}
                if test else CONFIG['channels']['production'])
    app = output / (settings['appName'] + '.app')
    if app.exists():
        raise RuntimeError('Preserve the existing candidate before reusing this output')
    output.mkdir(parents=True, exist_ok=True)
    run('ditto', base, app)
    native_before = {str(p.relative_to(app)): sha(p) for p in app.rglob('*')
                     if p.is_file() and not p.is_symlink() and is_macho(p)}
    changed = replace_module(app / 'Contents/Resources/browser/omni.ja', old_module, (ROOT / SOURCE).read_bytes())
    info['CFBundleGetInfoString'] = f"Personal {'test' if test else 'production'}; upstream {CONFIG['upstream']['tag']}; {CONFIG['revision']}"
    if test:
        info.update(CFBundleName=settings['appName'], CFBundleDisplayName=settings['appName'],
                    CFBundleIdentifier=settings['bundleId'])
        ini_path = app / 'Contents/Resources/browser/personal-application.ini'
        metadata = configparser.ConfigParser(interpolation=None)
        metadata.optionxform = str
        metadata.read(ini_path)
        metadata['App'].update(Name=settings['appName'], Profile='zen-personal-link-test',
                               RemotingName=settings['remotingName'])
        with ini_path.open('w') as stream:
            metadata.write(stream, space_around_delimiters=False)
        architectures = subprocess.check_output(['lipo', '-archs', str(app / 'Contents/MacOS/zen-engine')], text=True).split()
        flags = [flag for arch in architectures for flag in ('-arch', arch)]
        run('clang', *flags, '-O2', '-Wall', '-Wextra', '-Werror',
            f'-DPERSONAL_CHANNEL="{settings["profileDirectory"]}"', ROOT / 'personal/launcher.c',
            '-o', app / 'Contents/MacOS/zen-personal')
        run('codesign', '--force', '--sign', identity, '--identifier', settings['bundleId'],
            '--options', 'runtime', '--timestamp', '--entitlements', ROOT / 'personal/entitlements.plist',
            app / 'Contents/MacOS/zen-engine', capture_output=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    # Nested native code is unchanged and already Developer-ID signed. Re-seal
    # only the modified outer bundle so daily engine identity stays byte exact.
    run('codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp',
        '--entitlements', ROOT / 'personal/entitlements.plist', app, capture_output=True)
    run('codesign', '--verify', '--deep', '--strict', app, capture_output=True)
    verify_engine_identity(app)
    expected_native_changes = {'Contents/MacOS/zen-personal'} | ({'Contents/MacOS/zen-engine'} if test else set())
    changed_native = [name for name, digest in native_before.items() if sha(app / name) != digest]
    if set(changed_native) - expected_native_changes:
        raise RuntimeError('Unexpected native runtime changes: ' + repr(changed_native))
    report = dict(baseline, status='frontend-hotfix-and-signature-verified', source=source,
                  revision=CONFIG['revision'], channel='link-test' if test else 'production',
                  app=str(app), bundle_id=settings['bundleId'], native_tested=False, promoted=False,
                  profile_directory='~/Library/Application Support/Zen Personal/' + settings['profileDirectory'],
                  created=datetime.now(timezone.utc).isoformat(),
                  hotfix={'baseline_manifest_sha256': sha(baseline_manifest),
                          'baseline_source': baseline['source']['commit'],
                          'changed_archive_entries': changed, 'changed_native_signatures': changed_native,
                          'engine_executable_unchanged': not test},
                  base_archive_sha256=baseline['modified_archive_sha256'],
                  modified_archive_sha256=sha(app / 'Contents/Resources/browser/omni.ja'))
    (output / 'Build Manifest.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'app': str(app), 'revision': CONFIG['revision'], 'test': test,
                      'changed_archive_entries': changed, 'changed_native_signatures': changed_native}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=Path, required=True)
    parser.add_argument('--baseline-manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--test', action='store_true')
    args = parser.parse_args()
    update(args.base.resolve(), args.baseline_manifest.resolve(), args.output.resolve(), args.test)
