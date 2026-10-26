# Production promotion — 2026-10-26

The user accepted the personal browser features for daily use. These packages
are our custom production channel, not an official Zen-team release.

## Source and package

- Accepted command/search/layout revision: `224f853559e5952d02c15ffd340cb81cf5674909`.
- Launcher fix and current packaged source: `5ff99997dc1be5546231d7eccf83d40f52f9c05a`.
- Current release tag: `personal-1.23.4b.3`.
- Upstream native engine: Zen `1.23.4b`, SourceStamp
  `541ee55196395ee8082862b83c84c90ab41d9f6d`.
- Production package: `Production/dist/releases/personal.3/Zen.app` relative to
  the parent workspace; the sidecar Build Manifest records source/archive hashes.
- Developer-ID signed and deep/strict signature verified. No native engine/C++
  compile or Apple notarization is claimed.

The launcher now resolves application.ini before invoking Gecko. A path with
parent segments caused the six built-in browser addons to disappear from startup
state, although their assets remained present. Resolving the path restores all
six; changing ZIP compression did not fix it and was reverted. The correction
preserves the original assets, signature requirements and addon validation.

## Profile copy and preservation

The main vendor browser was quit normally. Its profile was backed up and copied
into the new forced Production profile. The original and backup fingerprints
were verified byte for byte. Only addon path metadata, NSS path metadata and
explicit startup/layout preferences were changed in the clone. Credentials
were neither decrypted nor exported. Cookies and extension storage were copied
as existing encrypted/profile data; live sign-in success remains a separate check.

Verified snapshot counts:

| Data | Count |
|---|---:|
| Bookmarks | 375 |
| Bookmark folders | 80 |
| History visits | 32,306 |
| Cookies | 6,509 |
| Installed active third-party extensions | 13 |
| Bundled browser components | 6 |
| Encrypted browser-saved login records | 1 |
| Session windows / tabs | 1 / 398 |

The first report counted 19 active extension records together; that is 13
installed extensions plus 6 bundled components, not 19 third-party extensions.
The updated copy tool records these categories separately.

Full profiles, encrypted credentials, cookie values, URLs and file-hash inventories
remain outside this public repository. Machine-local paths and rollback steps
are in the parent workspace's HANDOFF.md and the private backup reports.

## Current installation and native evidence

- Zen Dev personal.3 is installed at `/Applications/Zen Dev.app` and launched
  against only the Dev profile. All six bundled components are present.
- The clean personal.3 Dev package passes startup, top-toolbar and keyword-Tab
  verification. The red YouTube badge and native search scope were observed.
- All 50 JavaScript tests and 5 macOS Python safety/launcher tests pass locally.
  Linux CI skips only the native macOS compilation test.
- The main `/Applications/Zen.app` currently contains the initial personal.2
  production package and runs the copied Production profile. Its signature,
  profile isolation and 13 installed extensions were verified from local state.
- The signed personal.3 production fix is ready but **must replace personal.2
  only after main Zen exits**. The user has been asked to quit main Zen normally.
- The UI tool's app catalogue still resolves `/Applications/Zen.app` to the old
  vendor bundle, and rejects `com.kimkhoi.zen` as invalid even though the new
  process appears in inventory. Broad Computer permission and LaunchServices
  registration did not refresh that catalogue. Do not change the app identity or
  use OS scripting to work around the UI tool. Refresh/restart the host tool
  session if necessary.

Production is not yet declared ready for daily use. After installing personal.3,
verify its canonical launch arguments, 6 bundled plus 13 installed components,
restored workspaces/tabs, keyword-Tab, native commands and the actual 1Password
popup. Check OS default-browser routing. Request action-time approval if adding
the new signing identity to 1Password's trusted browsers is necessary. Passkey,
DRM and all-site sign-in parity have not been demonstrated.

## Continuing updates

Make feature changes in Development, test them in Zen Dev, then promote the
accepted source with a fast-forward of personal/production and a release tag.
Build from the matching preserved/downloaded official app, not our customized
main app. Back up the closed live Production profile before each engine update.
Retain the app and matching profile backup for rollback. Restore into a separate
profile first when testing a downgrade; never downgrade a live profile in place.

Automatic vendor binary updates are disabled in both custom channels. No custom
updater exists, so upstream security releases need prompt manual rebuilding and
promotion. Dev and production never share the same profile directory.
