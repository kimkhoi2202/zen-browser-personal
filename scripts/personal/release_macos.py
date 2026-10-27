#!/usr/bin/env python3
"""Local-only public release: prepare, notarize, then publish verified assets.

Never reads or copies a browser profile. Authentication stays in the Keychain.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

from build_macos import CONFIG, ROOT, build

REPO = CONFIG['fork']
TAG = 'personal-' + CONFIG['upstream']['tag'] + '.' + CONFIG['revision'].split('.')[-1]
STEM = 'Zen-Prod-' + CONFIG['upstream']['tag'] + '-' + CONFIG['revision'] + '-macOS-universal'
FORBIDDEN = {'cookies.sqlite', 'places.sqlite', 'logins.json', 'key4.db', 'cert9.db',
             'sessionstore.jsonlz4', 'search.json.mozlz4', 'extensions.json'}


def run(*args, capture=False):
    result = subprocess.run([str(x) for x in args], cwd=ROOT, check=True,
                            text=True, capture_output=capture)
    return result.stdout.strip() if capture else None


def gh_json(*args):
    return json.loads(run('gh', *args, capture=True))


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def audit_app(app):
    """Reject accidental profile/key payloads and links outside the bundle."""
    root = app.resolve()
    for path in app.rglob('*'):
        if path.name in FORBIDDEN or path.suffix.lower() in {'.p8', '.p12', '.keychain-db'}:
            raise RuntimeError('Private-data filename in application: ' + str(path.relative_to(app)))
        if path.is_symlink() and not path.resolve().is_relative_to(root):
            raise RuntimeError('Application symlink escapes bundle: ' + str(path.relative_to(app)))


def check_actions_disabled():
    if gh_json('api', 'repos/' + REPO + '/actions/permissions')['enabled']:
        raise RuntimeError('Disable GitHub Actions in this fork before the local release')


def prepare(output, base, identity):
    if output.exists():
        raise RuntimeError('Choose a new output directory; existing candidates are preserved')
    if run('git', 'status', '--porcelain', capture=True):
        raise RuntimeError('Commit the reviewed release source before packaging')
    latest = gh_json('api', 'repos/zen-browser/desktop/releases/latest')
    if latest['tag_name'] != CONFIG['upstream']['tag']:
        raise RuntimeError('A newer stable upstream release exists; update the pin and overlays first')
    check_actions_disabled()
    run('node', '--test', *sorted((ROOT / 'scripts/personal').glob('*.test.mjs')))
    run(sys.executable, '-m', 'unittest', 'discover', '-s', 'scripts/personal', '-p', '*_test.py')
    stage = output / 'Stage'
    build(base, 'production', identity, stage)
    app = stage / (CONFIG['channels']['production']['appName'] + '.app')
    audit_app(app)
    # The builder's local manifest contains machine paths; never ship that file.
    local = json.loads((stage / 'Build Manifest.json').read_text())
    (stage / 'Build Manifest.json').rename(output / 'Private Build Manifest.json')
    if set(local['architectures']) != {'arm64', 'x86_64'}:
        raise RuntimeError('Public universal release requires both engine architectures')
    (stage / 'Applications').symlink_to('/Applications', target_is_directory=True)
    shutil.copy2(ROOT / 'LICENSE', stage / 'LICENSE.txt')
    shutil.copy2(ROOT / 'personal/Public Release.md', stage / 'Read Me.txt')
    source = ('# Source and licenses\n\nUnofficial Zen fork; not a Zen team release.\n\n'
              'Custom source: https://github.com/' + REPO + '/tree/' + TAG + '\n'
              'Exact source commit: ' + local['source']['commit'] + '\n'
              'Upstream source commit: ' + CONFIG['upstream']['commit'] + '\n'
              'Complete upstream engine source: https://github.com/zen-browser/desktop/releases/download/'
              + CONFIG['upstream']['tag'] + '/zen.source.tar.zst\n\n'
              'MPL-2.0 notices and the upstream about:license notices are retained.\n')
    (stage / 'Source.md').write_text(source)
    (output / 'Source.md').write_text(source)
    public = {'tag': TAG, 'source_commit': local['source']['commit'], 'upstream': CONFIG['upstream'],
              'revision': CONFIG['revision'], 'architectures': local['architectures'],
              'bundle_id': local['bundle_id'], 'profile_data_included': False,
              'automatic_updates': False, 'notarized': False, 'native_tested': False}
    (output / 'Build.json').write_text(json.dumps(public, indent=2) + '\n')
    shutil.copy2(ROOT / 'personal/Release Notes.md', output / 'Release Notes.md')
    print('Prepared clean candidate: ' + str(app))


def notarize(output, identity, profile):
    app = output / 'Stage' / (CONFIG['channels']['production']['appName'] + '.app')
    audit_app(app)
    payload = output / 'Notarization.zip'
    if payload.exists():
        payload.unlink()
    run('ditto', '-c', '-k', '--keepParent', app, payload)
    submit_notarization(payload, profile, output / 'App Notarization.json')
    run('xcrun', 'stapler', 'staple', app)
    run('xcrun', 'stapler', 'validate', app)
    run('codesign', '--verify', '--deep', '--strict', app)
    run('spctl', '--assess', '--type', 'execute', '--verbose=2', app)
    dmg = output / (STEM + '.dmg')
    if dmg.exists():
        raise RuntimeError('Preserve the existing DMG before retrying')
    run('hdiutil', 'create', '-volname', 'Zen (Prod)', '-srcfolder', output / 'Stage',
        '-format', 'UDZO', '-ov', dmg)
    run('codesign', '--sign', identity, '--timestamp', dmg)
    submit_notarization(dmg, profile, output / 'DMG Notarization.json')
    run('xcrun', 'stapler', 'staple', dmg)
    run('xcrun', 'stapler', 'validate', dmg)
    run('hdiutil', 'verify', dmg)
    run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=2', dmg)
    report = json.loads((output / 'Build.json').read_text())
    report.update(notarized=True, app_notarization='Accepted', dmg_notarization='Accepted',
                  download=dmg.name, download_sha256=sha(dmg))
    (output / 'Build.json').write_text(json.dumps(report, indent=2) + '\n')
    (output / 'SHA256SUMS.txt').write_text(report['download_sha256'] + '  ' + dmg.name + '\n')
    print('Notarized, stapled and Gatekeeper-verified: ' + str(dmg))


def submit_notarization(path, profile, report_path):
    digest = sha(path)
    if report_path.exists():
        submission = json.loads(report_path.read_text())
        if submission.get('sha256') != digest:
            raise RuntimeError('Notarization input changed; preserve old report and use a new candidate')
    else:
        submission = json.loads(run('xcrun', 'notarytool', 'submit', path, '--keychain-profile', profile,
                                    '--output-format', 'json', capture=True))
        submission['sha256'] = digest
        report_path.write_text(json.dumps(submission, indent=2) + '\n')
    print('Apple notarization submission: ' + submission['id'], flush=True)
    result = json.loads(run('xcrun', 'notarytool', 'wait', submission['id'], '--keychain-profile', profile,
                            '--timeout', '20m', '--output-format', 'json', capture=True))
    result['sha256'] = digest
    report_path.write_text(json.dumps(result, indent=2) + '\n')
    if result.get('status') != 'Accepted':
        raise RuntimeError('Notarization not accepted; inspect submission ' + str(result.get('id')))
    return result


def publish(output, native_tested):
    check_actions_disabled()
    report = json.loads((output / 'Build.json').read_text())
    if not native_tested or not report['notarized']:
        raise RuntimeError('Native testing and accepted notarization are required before publishing')
    commit = run('git', 'rev-parse', TAG + '^{commit}', capture=True)
    remote = run('git', 'ls-remote', 'origin', 'refs/tags/' + TAG, 'refs/tags/' + TAG + '^{}', capture=True)
    if commit != report['source_commit'] or commit not in remote:
        raise RuntimeError('Push the exact packaged source tag to origin first')
    dmg = output / report['download']
    if sha(dmg) != report['download_sha256']:
        raise RuntimeError('DMG changed after verification')
    report['native_tested'] = True
    (output / 'Build.json').write_text(json.dumps(report, indent=2) + '\n')
    run('gh', 'release', 'create', TAG, dmg, output / 'SHA256SUMS.txt', output / 'Build.json',
        output / 'Source.md', '--repo', REPO, '--verify-tag', '--draft',
        '--title', 'Zen (Prod) ' + CONFIG['upstream']['tag'] + ' / ' + CONFIG['revision'],
        '--notes-file', output / 'Release Notes.md')
    download = output / 'Downloaded Release'
    run('gh', 'release', 'download', TAG, '--repo', REPO, '--pattern', dmg.name, '--dir', download)
    if sha(download / dmg.name) != sha(dmg):
        raise RuntimeError('Uploaded asset hash mismatch; release remains a draft')
    run('gh', 'release', 'edit', TAG, '--repo', REPO, '--draft=false', '--latest')
    print('Published: https://github.com/' + REPO + '/releases/tag/' + TAG)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['prepare', 'notarize', 'publish'])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--base', type=Path, default=Path('/Applications/Zen.app'))
    parser.add_argument('--identity')
    parser.add_argument('--keychain-profile', default='Zen Notary')
    parser.add_argument('--native-tested', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve()
    if args.phase in {'prepare', 'notarize'} and not args.identity:
        parser.error('--identity is required for signing')
    if args.phase == 'prepare':
        prepare(output, args.base, args.identity)
    elif args.phase == 'notarize':
        notarize(output, args.identity, args.keychain_profile)
    else:
        publish(output, args.native_tested)
