#!/usr/bin/env python3
"""Run after npm run import, before full-source npm run build."""
from pathlib import Path
from ui_patch import patch_controller, patch_input, patch_view, patch_addons_styles, patch_findbar_position, ADDONS_CSS_SOURCE

root=Path(__file__).resolve().parents[2]
directory=root/'engine/browser/components/urlbar/content'
changes={}
for name,patch in [('UrlbarChildController.mjs',patch_controller),('UrlbarInputBase.mjs',patch_input),('UrlbarView.mjs',patch_view)]:
    p=directory/name
    if not p.is_file():raise SystemExit('Initialize/import the engine first')
    changes[p]=patch(p.read_text())
p=root/'engine/toolkit/mozapps/extensions/content/aboutaddons.css'
if not p.is_file():raise SystemExit('Initialize/import the engine first')
changes[p]=patch_addons_styles(p.read_text(),(root/ADDONS_CSS_SOURCE).read_text())
p=root/'engine/browser/themes/shared/tabbrowser/content-area.css'
if not p.is_file():raise SystemExit('Initialize/import the engine first')
changes[p]=patch_findbar_position(p.read_text())
for p,source in changes.items():
    p.write_text(source)
print('Applied site-search Tab, provider labels, responsive add-ons layout and top findbar to initialized engine')
