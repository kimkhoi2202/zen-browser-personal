# Native Find bar above the page — personal.11

The installed upstream 1.23.4b preferences have no Find bar position toggle. The
user requested moving Command-F below the browser toolbar and above the page,
retaining the existing native controls and appearance.

`scripts/personal/ui_patch.py` provides `patch_findbar_position`. It adds one
auto-sized `personal-findbar` row before `browserstack` in the native
`browser/themes/shared/tabbrowser/content-area.css` grid and assigns only the
native `findbar` element to that row. The original bottom `findbar` area remains
available to Zen's Zap bar. Notification, responsive-design and docked DevTools
areas are preserved. Hidden/absent Find bars take no extra space. No Find bar
JavaScript, controls, preferences or PDF document data were changed.

The artifact builder patches
`chrome/browser/skin/classic/browser/tabbrowser/content-area.css` inside browser's
omni.ja. `apply_to_engine.py` patches the same source after a full engine import.
Both use exact native anchors and reject changed or already-patched inputs.

Runtime source: 4ffb74b3, containing the original Copy URL revert from 3dcdc7a7.
All 77 JavaScript and 11 Python checks pass; native-base and repeat-patch guards
were exercised against the official stylesheet.

## Native verification and installation

Signed Zen (Dev) personal.11 is installed and tested on Apple Silicon. Command-F
opens above HTML and PDF content; searching, result counting, next/previous match
navigation and Escape closure work. The Dev test used the existing local review
PDF read-only. Its contents can change independently; match counts are observations
of the file at testing time, not expected fixed values. Native evidence is in
dist/findbar-personal.11-dev: PDF Findbar.jpg, HTML Findbar.jpg and Findbar
Verification.json. The Dev app is signed but not notarized; its prior app and
verified closed-profile copy are privately under Zen Personal/Backups/Top Findbar
Final 2026-10-27 personal.11.

Prod candidate: dist/findbar-personal.11-prod/Zen (Prod).app. It is signed,
Apple-notarized, stapled and Gatekeeper accepted. A verified staging copy is under
Zen Personal/Backups/Top Findbar Production 2026-10-27 personal.11. This supersedes
the personal.9 and personal.10 candidates. It includes the Copy URL revert,
responsive extension grid and corrected engine signing identity for 1Password.

Installed Prod remains personal.8. The user explicitly deferred restart until
they tell us it is closed. Do not quit/replace Prod until that reply. Then take a
fresh verified closed-profile backup, preserve its app, install the personal.11
candidate and verify its toolbar and Find bar natively. No GitHub publication or
source push is authorized. Production worktree stays at accepted personal.8 until
that promotion is complete. Intel hardware and docked-DevTools behavior have not
been exercised natively; their existing grid areas are retained in the patch.
