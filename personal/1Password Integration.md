# 1Password connection investigation — 2026-10-27

The previous personal.6 Prod app showed “Firefox has an update available”
when its extension is locked. The earlier unlocked popup was not proof of a
working desktop connection or Touch ID unlock. Prod is already in 1Password's
additional trusted browsers; desktop integration and Touch ID are enabled.

## Evidence and packaging correction

1Password's BrowserSupport log verifies the running
`/Applications/Zen (Prod).app/Contents/MacOS/zen-engine` process. Our launcher
executes that binary. The app/launcher's designated signing requirement uses
`com.kimkhoi.zen`, but the separately signed engine used `zen-engine`.
Both signatures were individually valid and from the same Developer ID team,
yet the engine failed the app's complete designated requirement.

The installed extension's unmodified background code maps an invalid signature,
or an unknown browser that previously connected, to `NeedsUpdate`. That message
does not by itself establish that a Firefox/Zen update exists.

`scripts/personal/build_macos.py` now explicitly signs the running engine with
the channel's bundle identifier after the nested signing pass, then reseals the
outer app. The builder verifies that the engine satisfies the app's complete
designated requirement, preserving Apple/Developer ID/team checks. No 1Password
code, validation policy or vault data was changed.

Runtime source: bcc8499739687dcc15c6f83b2607edbddbab0854, personal.8.
Candidate: Development/dist/integration-personal.8-prod/Zen (Prod).app.
The signing regression check fails against installed personal.6 and passes
against personal.8. All 77 JavaScript and 11 Python checks pass. Private signing
evidence is in that candidate's Signature Verification.json.

## Installed and verified locally

Personal.8 is installed at /Applications/Zen (Prod).app. It is Developer-ID signed,
Apple-notarized, stapled and Gatekeeper accepted. Its executable/resources match
the verified candidate. The original Production profile remained in place; all
9,965 fingerprints matched before first launch. The previous app and verified
profile snapshots are privately preserved under Zen Personal/Backups/1Password
Integration 2026-10-27 personal.8. See that folder's Installation.json.

Native BrowserSupport now passes verification and connects to BrowserHelper.
Before the correction it stopped while waiting for partner-browser authorization.
After manually locking 1Password, the user confirmed that Touch ID unlocked the
Prod extension and that the update warning was gone. A normal Prod quit/relaunch
again created a successful BrowserHelper connection. No trust entry was removed
or re-added for personal.8; the existing authorized app identity now matches the
running engine. No authentication files were copied to Dev or changed by this fix.

The real Add-ons Manager shows three columns with all 13 installed extensions.
Its More Options menu and native details page work. Wappalyzer was disabled and
immediately re-enabled to verify the grid toggle; its enabled state was restored.
The prior Dev fixture tests cover narrower list widths. Native evidence and the
grid screenshot are in dist/integration-personal.8-prod/Native Verification.json
and Prod Extension Grid.jpg. Apple Silicon was tested; Intel hardware was not.

Official Zen and installed Dev personal.7 remain separate and unchanged. The
public release is still personal.6. No source push, tag or GitHub release was
made for this update; do not publish it without a new user instruction.

Official references:
- https://support.1password.com/1password-browser-connection-security/
- https://support.1password.com/additional-browsers/
- https://docs.zen-browser.app/guides/1password
