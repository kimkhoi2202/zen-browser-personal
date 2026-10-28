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

Zen (Prod) personal.11 was installed on 2026-10-28 after the user's closed-Prod
reply. The notarized candidate is in dist/findbar-personal.11-prod; the private
Ready staging app was moved into /Applications/Zen (Prod).app. The app includes
the original Copy URL revert, responsive grid and corrected 1Password identity.
All signature, engine identity, staple and Gatekeeper checks pass. Before launch,
all 17,951 daily-profile file fingerprints matched the fresh snapshot, and 13
active user extensions remained active afterward. Native Prod HTML Find showed
2 of 53 matches with the bar above content; original Copy URL placement was
visually verified. Other activity changed the active tab, so Prod PDF and match
navigation were not retested; those had passed in Dev for this runtime.

Private rollback is under Zen Personal/Backups/Top Findbar Production 2026-10-27
personal.11 (Previous Zen (Prod).app, Production Profile Before Install, private
fingerprints and Installation.json). Personal.9/10 are superseded and must not be
installed. Public stays personal.6; no push/tag/release is authorized. Intel and
docked DevTools have not been exercised natively; existing grid areas are retained.
