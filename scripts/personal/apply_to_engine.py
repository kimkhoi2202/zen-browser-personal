#!/usr/bin/env python3
"""Run after npm run import, before full-source npm run build."""
from pathlib import Path
from ui_patch import patch_controller

root=Path(__file__).resolve().parents[2]
p=root/'engine/browser/components/urlbar/content/UrlbarChildController.mjs'
if not p.is_file():raise SystemExit('Initialize/import the engine first')
p.write_text(patch_controller(p.read_text()))
print('Applied exact-keyword Tab change to initialized engine')
