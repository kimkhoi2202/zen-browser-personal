# Responsive extension-list preview — personal.7

Installed Zen (Dev) is a signed personal.7 preview, packaged from
678aca010a17e64abaae2ceb9ecd2fde65cfadbc. The layout is now installed locally in
Zen (Prod) personal.8, together with the 1Password signing correction. Runtime
source is bcc8499739687dcc15c6f83b2607edbddbab0854. Public release remains personal.6;
the user explicitly excluded GitHub publication for this update.

`src/zen/common/styles/zen-addons-grid.css` widens only extension-list views and
uses named container queries for one, two or three columns. The thresholds are
49rem and 74rem of actual list space, so window/sidebar size and zoom can reduce
the column count. Native card styles and DOM order are retained. Section headings
and messages span all columns; open menus get their own stacking order. Details,
plugins and themes retain the upstream layout.

The CSS is appended to toolkit's aboutaddons.css in the platform omni.ja by the
artifact builder, and to the same engine stylesheet by apply_to_engine.py. Both
use the shared anchor checks in ui_patch.py; already-patched or changed upstream
stylesheets are rejected. No extension-management JavaScript or permission checks
were modified. Future full engine builds must run apply_to_engine.py as documented.

## Verification

- 77 JavaScript and 11 Python checks passed, including clean-base/layout-drift guards.
- Signed Dev app passed strict/deep code-signature verification. It is not notarized.
- The candidate's actual packaged stylesheet was rendered in Zen (Dev) with sample
  cards at 1500/1000/700/320 px of list space: 3/2/1/1 columns, no horizontal overflow.
- The fixture is a local layout check, not installed extension data. Dev's isolated
  profile has no user extensions. After local Prod installation, its real manager
  displayed three columns with 13 extensions. More Options and native details
  worked; Wappalyzer was disabled/re-enabled successfully and restored to enabled.
- The Dev app/profile rollback is outside Git under Zen Personal/Backups/Add-ons
  Grid 2026-10-27 personal.7. Prod's separate rollback is under Backups/1Password
  Integration 2026-10-27 personal.8, with verified profile snapshots and prior app.

Candidate: Development/dist/addons-personal.7-dev. Generate the local preview with
scripts/personal/addons_fixture.py using --app and --output; see Generation
Scripts/README.md. The ignored dist/addons-layout-preview.html is open in Dev.
Native screenshot: dist/addons-personal.7-dev/Layout Preview.png.
Prod candidate, notarization and native evidence: dist/integration-personal.8-prod.
