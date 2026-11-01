# External-link startup hotfix

The daily personal.15 engine has native PiP. Another chat is actively compiling
later PiP changes in the shared native build tree. This hotfix changes only
`ZenSpaceManager.mjs`; it must not import an unfinished native engine.

Source: `src/zen/spaces/ZenSpaceManager.mjs`. Firefox supplies an array of URLs
when launched by an external application; startup selection previously recognized
only a string. The first real startup URL must remain selected through workspace
restoration, including when continuing a saved session.

The daily profile also restores nine windows. Selecting the requested page in
the first window is insufficient: a later empty restored window can cover it.
After all windows and their workspaces finish restoring, activate the requested
window only if its requested tab is still selected and neither has closed.
Do not await that activation inside workspace initialization itself.

Scripts:

- `scripts/personal/startup_navigation.test.mjs` exercises the actual startup
  method. External-array cases failed before the fix; string/homepage, ordinary
  startup and saved-session cases protect existing behavior.
- `scripts/personal/frontend_hotfix.py` copies an attested signed personal.15
  release, replaces exactly one archive entry, and re-signs its outer bundle.
  It verifies both archive hashes against the original build manifest, verifies
  the installed module against the recorded engine source, verifies signatures,
  and checks that native runtime files stay unchanged. It never edits its input.
  This is a narrow frontend update, not a full-packager run on a custom base.
- `scripts/personal/frontend_hotfix_test.py` verifies replacement isolation and
  rejection of unexpected input. The normal `build_macos.py` also installs the
  source module so future packages retain the fix without a native rebuild.

Run from this worktree, after committing reviewed source:

    node --test scripts/personal/*.test.mjs
    python3 -m unittest discover -s scripts/personal -p '*_test.py'
    python3 scripts/personal/frontend_hotfix.py --base /Applications/Zen.app --baseline-manifest '/path/to/personal.15/Build Manifest.json' --output dist/startup-test --test
    python3 scripts/personal/frontend_hotfix.py --base /Applications/Zen.app --baseline-manifest '/path/to/personal.15/Build Manifest.json' --output dist/startup-production

Test mode creates **Zen (Dev - Links)** (`com.kimkhoi.zen.dev.links`) with the
isolated `Zen Personal/External Link Test` profile. Never use the occupied normal
Dev profile. Production preserves the existing engine executable byte for byte,
its Developer ID identity, disabled updater and Production profile path. Before
installing: notarize/staple, verify Gatekeeper, quit daily Zen, take a verified
closed-profile snapshot, and preserve the prior app for rollback.

Native cases: links when closed and running, several URLs, normal launch,
restored Spaces/tabs, and restoring HTTP/HTTPS default handling to installed Zen.
Do not claim native success until the requested URL is actually displayed.
Keep browser profiles and notarization records private. No GitHub publication
or Actions are part of this local hotfix.

`Generation Scripts/Build Link Harness.py` builds the small local AppKit fixture
from `External Link Harness.m`. Its buttons send real HTTPS requests through
NSWorkspace to the isolated candidate or installed daily Zen. Control those
buttons through CUA; the fixture never changes the system default browser.
File-open tests alone did not expose the multi-window HTTPS focus issue.
