#!/usr/bin/env python3
"""Run after npm run import, before full-source npm run build."""
from pathlib import Path
from ui_patch import patch_controller, patch_input

root=Path(__file__).resolve().parents[2]
directory=root/'engine/browser/components/urlbar/content'
changes={}
for name,patch in [('UrlbarChildController.mjs',patch_controller),('UrlbarInputBase.mjs',patch_input)]:
    p=directory/name
    if not p.is_file():raise SystemExit('Initialize/import the engine first')
    changes[p]=patch(p.read_text())
for p,source in changes.items():
    p.write_text(source)
print('Applied site-search Tab and provider-label changes to initialized engine')
