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
- Main `/Applications/Zen.app` now contains the clean personal.3 production
  package. It launched with a canonical ini path and the isolated Production
  profile. Local startup state confirms 6 bundled components plus 13 installed
  extensions; no old-profile addon paths remain.
- Before replacement, the closed current Production profile was copied and
  fingerprint-verified again, and the prior personal.2 app was retained.
- The original vendor profile remains byte-identical to its promotion snapshot.
- Both branch checks passed for the prior handoff revision:
  [Dev](https://github.com/kimkhoi2202/zen-browser-personal/actions/runs/40404456893)
  and [Production](https://github.com/kimkhoi2202/zen-browser-personal/actions/runs/40404457974).
- The UI tool still cannot attach to the new main identity: its cached path
  resolves to the vendor bundle. Re-registering the installed app in LaunchServices
  establishes the correct system registration but does not refresh the tool's
  catalogue. Do not alter bundle IDs or use OS scripting to bypass this issue.

The app is installed and running. Full production UI/1Password verification is
pending the tool catalogue refresh. macOS's current http/https defaults still
reference the old vendor bundle. System Settings shows only a duplicate-name
Zen choice, so no ambiguous default change was made. Use the custom browser's
own General > Make Default action, then verify the new handler is com.kimkhoi.zen
and resolves to /Applications/Zen.app. Restarting the host/tool session may be
needed to expose its new app identity.

Check the actual 1Password popup, requesting action-time approval if this
signing identity needs trusted-browser access. Passkeys, DRM and all-site sign-in
parity have not been demonstrated. The copied profile preserves data; it does
not guarantee that a server will keep every session valid.

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
