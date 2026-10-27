#!/usr/bin/env python3
"""Run after npm run import, before full-source npm run build."""
from pathlib import Path
from ui_patch import patch_controller, patch_input, patch_addons_styles, ADDONS_CSS_SOURCE

root=Path(__file__).resolve().parents[2]
directory=root/'engine/browser/components/urlbar/content'
changes={}
for name,patch in [('UrlbarChildController.mjs',patch_controller),('UrlbarInputBase.mjs',patch_input)]:
    p=directory/name
    if not p.is_file():raise SystemExit('Initialize/import the engine first')
    changes[p]=patch(p.read_text())
p=root/'engine/toolkit/mozapps/extensions/content/aboutaddons.css'
if not p.is_file():raise SystemExit('Initialize/import the engine first')
changes[p]=patch_addons_styles(p.read_text(),(root/ADDONS_CSS_SOURCE).read_text())
for p,source in changes.items():
    p.write_text(source)
print('Applied site-search Tab, provider labels and responsive add-ons layout to initialized engine')
