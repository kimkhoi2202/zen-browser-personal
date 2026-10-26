#!/usr/bin/env python3
"""Build two signed UI artifact variants; never modifies the input app/profile.

The engine remains the verified official release. Only source-controlled UI
modules, app identity/launcher, and per-channel update policy are customized.
"""
import argparse
import configparser
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile
from ui_patch import patch_controller

ROOT=Path(__file__).resolve().parents[2]
CONFIG=json.loads((ROOT/'personal/channels.json').read_text())
CONTROLLER='chrome/browser/content/browser/urlbar/UrlbarChildController.mjs'
ZEN_CONTROLLER='modules/zen/urlbar/ZenUrlbarController.mjs'
HELPER='modules/zen/urlbar/PersonalSiteSearch.mjs'
ADDITIONAL_UI={
    'modules/zen/urlbar/PersonalCommandActions.mjs':'src/zen/urlbar/PersonalCommandActions.mjs',
    'modules/ZenUBGlobalActions.sys.mjs':'src/zen/urlbar/ZenUBGlobalActions.sys.mjs',
    'modules/ZenUBActionsProvider.sys.mjs':'src/zen/urlbar/ZenUBActionsProvider.sys.mjs',
    'localization/en-US/browser/zen-command-palette.ftl':'locales/en-US/browser/browser/zen-command-palette.ftl',
}

def run(*cmd,**kwargs):return subprocess.run([str(x) for x in cmd],check=True,**kwargs)

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def source_metadata():
    revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    dirty=bool(subprocess.check_output(['git','status','--porcelain'],cwd=ROOT,text=True).strip())
    paths=['src/zen/urlbar/PersonalSiteSearch.mjs','src/zen/urlbar/ZenUrlbarController.mjs',
           'scripts/personal/ui_patch.py','personal/launcher.c','personal/channels.json',
           'personal/entitlements.plist','scripts/personal/build_macos.py','prefs/zen/view.yaml',
           *ADDITIONAL_UI.values()]
    return {'commit':revision,'dirty':dirty,'file_sha256':{p:sha(ROOT/p) for p in paths}}

def extract_archive(archive,directory):
    # Mozilla's optimized ZIP is understood by unzip, whose warning exit status
    # is not a failed extraction. Confirm every entry by CRC after normalization.
    result=subprocess.run(['unzip','-q',str(archive),'-d',str(directory)],capture_output=True)
    # Apple's unzip reports status 2 for the known optimized central directory,
    # even after extracting every entry. Validate the complete entry set, and
    # reject any CRC/data errors instead of treating all status-2 errors alike.
    diagnostics=result.stderr.decode()
    known_optimized=(result.returncode==2 and 'extra bytes at beginning or within zipfile' in diagnostics
                     and 'length of central directory' in diagnostics
                     and not any(s in diagnostics.lower() for s in ('bad crc','cannot','unsupported','invalid compressed','checkdir')))
    if result.returncode not in (0,1) and not known_optimized:raise RuntimeError(diagnostics)
    listing=subprocess.run(['unzip','-Z1',str(archive)],capture_output=True)
    expected={n for n in listing.stdout.decode().splitlines() if n and not n.endswith('/')}
    actual={p.relative_to(directory).as_posix() for p in directory.rglob('*') if p.is_file()}
    if not expected or expected!=actual:raise RuntimeError('Incomplete resource archive extraction')
    if not (directory/CONTROLLER).is_file():raise RuntimeError('Missing native controller after extraction')

def package_archive(directory,path):
    with zipfile.ZipFile(path,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for p in sorted(directory.rglob('*')):
            if p.is_file():z.write(p,p.relative_to(directory).as_posix())
    with zipfile.ZipFile(path) as z:
        if z.testzip():raise RuntimeError('Invalid generated archive')

def build(base,channel,identity,output):
    settings=CONFIG['channels'][channel]
    metadata=configparser.ConfigParser(interpolation=None)
    metadata.optionxform=str
    metadata.read(base/'Contents/Resources/application.ini')
    if metadata['App']['SourceStamp']!=CONFIG['upstream']['commit']:
        raise RuntimeError('Base app is not the pinned upstream release; update and test the source first')
    app=output/(settings['appName']+'.app')
    if app.exists():raise RuntimeError(f'Output already exists; preserve or relocate it first: {app}')
    output.mkdir(parents=True,exist_ok=True)
    run('ditto',base,app)
    # Finder metadata on downloaded/copied bundles is rejected by strict signing.
    # Remove only non-code FinderInfo/ResourceFork from the new build copy,
    # preserve quarantine and all other attributes, then verify vendor code.
    for attr in ('com.apple.FinderInfo','com.apple.ResourceFork'):
        subprocess.run(['xattr','-dr',attr,str(app)],capture_output=True)
    run('codesign','--verify','--deep','--strict',app,capture_output=True)
    archive=app/'Contents/Resources/browser/omni.ja'
    original_archive_sha=sha(archive)
    with tempfile.TemporaryDirectory(prefix='zen-personal-ui-') as temp:
        extracted=Path(temp)
        extract_archive(archive,extracted)
        original=(extracted/CONTROLLER).read_text()
        (extracted/CONTROLLER).write_text(patch_controller(original))
        (extracted/ZEN_CONTROLLER).write_bytes((ROOT/'src/zen/urlbar/ZenUrlbarController.mjs').read_bytes())
        (extracted/HELPER).write_bytes((ROOT/'src/zen/urlbar/PersonalSiteSearch.mjs').read_bytes())
        for destination,source in ADDITIONAL_UI.items():
            (extracted/destination).write_bytes((ROOT/source).read_bytes())
        defaults=extracted/'defaults/preferences/firefox.js'
        prefs=defaults.read_text();anchor='pref("zen.view.use-single-toolbar", true);'
        if prefs.count(anchor)!=1:raise RuntimeError('Review upstream toolbar default before packaging')
        defaults.write_text(prefs.replace(anchor,'pref("zen.view.use-single-toolbar", false);'))
        package_archive(extracted,archive)
    plist_path=app/'Contents/Info.plist'
    plist=plistlib.loads(plist_path.read_bytes())
    plist.update(CFBundleIdentifier=settings['bundleId'],CFBundleName=settings['appName'],
                 CFBundleDisplayName=settings['appName'],CFBundleExecutable='zen-personal')
    plist['CFBundleShortVersionString']=metadata['App']['Version']
    plist['CFBundleGetInfoString']=f"Personal {channel}; upstream {CONFIG['upstream']['tag']}; {CONFIG['revision']}"
    plist_path.write_bytes(plistlib.dumps(plist))
    # Nested helpers receive distinct identifiers too; URL handlers remain native.
    for helper_plist in (app/'Contents/MacOS').rglob('Info.plist'):
        d=plistlib.loads(helper_plist.read_bytes())
        old=d.get('CFBundleIdentifier')
        if old:d['CFBundleIdentifier']=settings['bundleId']+'.helper.'+hashlib.sha256(old.encode()).hexdigest()[:12]
        helper_plist.write_bytes(plistlib.dumps(d))
    metadata['App'].update(Name=settings['appName'],Vendor='Personal',Profile='zen-personal-'+channel,
                           RemotingName=settings['remotingName'],
                           BuildID=datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S'),
                           SourceRepository='https://github.com/'+CONFIG['fork'])
    if metadata.has_section('AppUpdate'):metadata.remove_section('AppUpdate')
    ini=app/'Contents/Resources/browser/personal-application.ini'
    with ini.open('w') as f:metadata.write(f,space_around_delimiters=False)
    distribution=app/'Contents/Resources/distribution';distribution.mkdir(exist_ok=True)
    policy={'policies':{'DisableAppUpdate':True}}
    existing=distribution/'policies.json'
    if existing.exists():
        policy=json.loads(existing.read_text());policy.setdefault('policies',{})['DisableAppUpdate']=True
    existing.write_text(json.dumps(policy,indent=2)+'\n')
    macos=app/'Contents/MacOS'
    (macos/'zen').rename(macos/'zen-engine')
    run('clang','-O2','-Wall','-Wextra','-Werror',f'-DPERSONAL_CHANNEL="{settings["profileDirectory"]}"',
        ROOT/'personal/launcher.c','-o',macos/'zen-personal')
    run('codesign','--force','--deep','--sign',identity,'--options','runtime','--entitlements',ROOT/'personal/entitlements.plist',app,capture_output=True)
    run('codesign','--verify','--deep','--strict',app,capture_output=True)
    report={'status':'packaged-and-signature-verified','channel':channel,'app':str(app),
            'bundle_id':settings['bundleId'],'profile_directory':'~/Library/Application Support/Zen Personal/'+settings['profileDirectory'],
            'upstream':CONFIG['upstream'],'source':source_metadata(),
            'engine':'official released engine; frontend modules customized',
            'base_archive_sha256':original_archive_sha,'modified_archive_sha256':sha(archive),
            'native_tested':False,'promoted':False,'auto_updates':'disabled for custom channel; rebuild from new upstream release',
            'signing':'local keychain identity; no private key exported','identity_fingerprint':identity}
    (output/'Build Manifest.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--base',type=Path,default=Path('/Applications/Zen.app'))
    parser.add_argument('--channel',choices=CONFIG['channels'],required=True)
    parser.add_argument('--identity',required=True)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    build(args.base,args.channel,args.identity,args.output or ROOT/'dist'/args.channel)
