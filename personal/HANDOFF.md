> Naming migration completed October 28, 2026. Custom Zen and Crest use the
> plain Applications names; vendor apps use the Official suffix. Bundle IDs,
> profile paths and Zen's default-browser association are preserved. Custom Zen
> is signed, re-notarized, stapled and Gatekeeper accepted. Finder names and
> custom Zen launch passed; Crest's eight Spaces and two connected 1Password
> accounts passed. Zen's 13 active user extensions remain. The app-control
> resolver still caches Zen's prior vendor identity, so Zen's window/1Password
> popup was not retested after renaming. See the private manifest for evidence.

# Application names — October 28, 2026

The user's custom daily app is **Zen** at `/Applications/Zen.app`
(`com.kimkhoi.zen`). The vendor app is **Zen (Official)** at
`/Applications/Zen (Official).app` (`app.zen-browser.zen`). **Zen (Dev)** stays
unchanged. Older sections use the former names and paths.

Production still forces `~/Library/Application Support/Zen Personal/Production`;
Dev still forces its separate Dev profile. Never rename or merge those profiles
or bundle IDs. Build only from the verified vendor `/Applications/Zen (Official).app`,
never the custom `/Applications/Zen.app`. Packaging defaults now use the new names.
This naming update does not publish a release or change the personal.11 features.

Private rollback, notarization and installation evidence:
`~/Library/Application Support/Browser Naming/2026-10-28 Primary Names`.
Read `Application Names.md` for the installed-name mapping and continuation.

# Installed Actions update — personal.13

Custom Zen at /Applications/Zen.app is locally installed from runtime 49b67431.
Its native Actions provider now includes Space/folder destinations. Read
[Actions Mode.md](Actions%20Mode.md) for behavior and exact native test limits.
87 Node and 11 Python checks pass. The app is signed, notarized and stapled;
13,455 profile fingerprints matched before launch and 13 user extensions remain.
Automatic PiP stays off; no stopped PiP candidate is included. Nothing was
published. Installed Zen (Dev) remains personal.11; the temporary personal.13
Dev candidate is closed and disabled, and the original Dev profile restored.
The parent handoff records the private rollback and daily keyboard test limit.

# Continuing the personal Zen fork

This is the portable handoff for the personal browser code. The local workspace
is `~/Documents/Zen Browser`, with `Development` on `personal/dev` and `Production`
on `personal/production`. Read the parent workspace's AGENTS.md/HANDOFF.md for
machine-specific paths and the verified state after relocation.

## Current public release

Installed custom Zen and Zen (Dev) are personal.11. Prod is Developer-ID signed,
Apple-notarized and stapled; Dev is signed but not notarized. Prod's native Find
bar is above page content and Copy URL is restored to the vendor position. The
responsive extension grid and corrected 1Password engine identity remain. See
[Find Bar.md](Find%20Bar.md), [Production.md](Production.md) and the parent handoff.

The 2026-10-28 installation preserved all 17,951 closed-profile fingerprints and
13 user extensions. Native Prod HTML Find and toolbar placement pass. Further
interaction stopped when another task/user changed the active tab; PDF and
next/previous retests are only claimed for Dev. All 88 focused checks passed for
this runtime. Intel hardware and docked DevTools remain untested. Production is
promoted locally; public remains personal.6. No GitHub push/tag/release was made.
Do not install superseded personal.9/10 candidates or publish without instruction.

Read [1Password Integration.md](1Password%20Integration.md) for the accepted
personal.8 signing fix and the user's prior Touch ID confirmation. This CSS update
retains its app/engine signing requirement and does not change browser trust.
The stable upstream base remains 1.23.4b (last checked 2026-10-27); custom updates
remain manual. Official Zen and each custom profile stay separate.

## Goal and implementation

Maintain two custom app identities: **Zen (Dev)** for testing and **Zen** for accepted
daily releases. Vendor **Zen (Official)** remains a third app at /Applications/Zen (Official).app.
Each custom app forces its existing separate browser profile. The first personal
feature makes an exact search alias followed by bare Tab enter native site
search, with provider-colored badges resembling Arc. Bare Tab never cycles
URL-bar suggestions; native Up/Down do. Typed aliases win even after arrow
navigation. Modifiers, IME, native Space and webpage Tab retain native handling.
Badge labels omit trailing configured aliases without changing engine identity. Search aliases are profile data, not hard-coded into the module.

The first candidates reuse the released Zen 1.23.4b native engine; the changed
JavaScript frontend is packaged and locally signed. A full Firefox/C++ compile
has not been performed. See [README.md](README.md) and [Verification.md](Verification.md).

## Files to edit

| File | Role |
|---|---|
| `src/zen/urlbar/PersonalSiteSearch.mjs` | Exact alias detection, provider colors, badge styles |
| `src/zen/urlbar/PersonalCommandActions.mjs` | Arc aliases, missing native actions, toolbar/sidebar visibility and command matching |
| `src/zen/urlbar/ZenUBGlobalActions.sys.mjs` | Adds the personal commands to Zen's existing registry |
| `src/zen/urlbar/ZenUBActionsProvider.sys.mjs` | Searches aliases and prioritizes unambiguous commands in native result rows |
| `src/zen/urlbar/ZenUrlbarController.mjs` | Installs styles; applies them when native search mode changes |
| `src/zen/urlbar/moz.build` | Registers the custom module for full source imports |
| `scripts/personal/ui_patch.py` | Exact-anchor native Tab and badge-label overlays shared by both build paths |
| `scripts/personal/build_macos.py` | Checks the official base, repackages UI, creates identities/launcher, signs, records manifest |
| `scripts/personal/apply_to_engine.py` | Applies the native Tab overlay after full engine import |
| `scripts/personal/clone_profile.py` | Back up and copy a closed daily profile into a new isolated production profile |
| `scripts/personal/jsonlz4.py` | Dependency-free Mozilla profile/session codec |
| `scripts/personal/*_test.py` | Synthetic profile-copy safety and native macOS launcher regression checks |
| `scripts/personal/seed_dev_profile.py` | Explicitly copies only search aliases and keyboard registry into closed Dev |
| `personal/launcher.c` | Forces per-channel app ini and isolated profile; runs the native engine |
| `personal/channels.json` | Upstream pin, personal revision, app names, bundle/remoting IDs and profiles |
| `personal/entitlements.plist` | Local signing entitlement baseline |
| `scripts/personal/*.test.mjs` | Focused command/module/channel and injected-controller tests |
| `.github/workflows/personal-checks.yml` | Lightweight tests/syntax/patch-anchor CI |
| `Generation Scripts/README.md` | Generation-script mapping and continuation context |

Keep overlays/patches in Git. Generated `engine/`, dependencies, `dist/`, profiles,
secrets and signed apps do not belong in source control.

## Checks from the selected development worktree

```sh
git status --short
git branch --show-current
git worktree list
node --test scripts/personal/*.test.mjs
python3 -m unittest discover -s scripts/personal -p '*_test.py'
node --check src/zen/urlbar/PersonalSiteSearch.mjs
node --check src/zen/urlbar/ZenUrlbarController.mjs
python3 -m py_compile scripts/personal/*.py
git diff --check
```

The focused tests use Node's built-in runner and do not require npm dependencies.
If original Zen tooling is needed, install the pinned lockfile dependencies with
`HUSKY=0 npm ci --ignore-scripts`. Existing Development dependencies were preserved
when moving the primary checkout; other worktrees need their own installation.

## Package another Dev candidate on macOS

Check that the official base application's SourceStamp matches
`personal/channels.json`. Use an existing local signing identity; its fingerprint
is public, its private key stays in the keychain. Pick a new output directory:

```sh
python3 scripts/personal/build_macos.py \
  --base "/path/to/preserved/official/Zen.app" \
  --channel dev \
  --identity 'Developer ID Application: Your Name (TEAMID)' \
  --output dist/dev-next
codesign --verify --deep --strict 'dist/dev-next/Zen (Dev).app'
```

Do not build from either custom app as the base. Its modified native entry point
and resource archive are already patched. Do not overwrite an existing candidate
or replace an installed app while it is running. Test the newly built signed app
with app-scoped controls before installing it, preserving the previous build.

The internal Gecko application ID stays at the upstream Firefox compatibility
ID. Native bundle IDs, remoting IDs and forced profiles separate the channels.
This preserves extension/blocklist assumptions; it does not establish trust for
1Password, passkeys or every native integration automatically.

## Full engine compilation is a separate path

Zen's original `npm run init` imports the engine and tracked Zen source. Then run
`python3 scripts/personal/apply_to_engine.py` before `npm run build`. The native
brand/profile/bundle/update identities must also be configured for this path;
the artifact packager's identity changes do not automatically apply to a full
engine compile. Do not launch a raw build against the daily profile. Check disk
and current official build prerequisites before initialization.

## Branches and additional worktrees

Development is the primary checkout; its `.git` stores the shared objects.
Production is a linked checkout. Do not move/remove Development independently.
Create a descriptive sibling worktree for a new feature, substituting the name:

```sh
git worktree add -b feature/NAME '../Feature - NAME' personal/dev
```

Use the explicit desired base branch; keep feature changes focused. Commit and
push to `origin`, the personal fork. Upstream's push URL is disabled. Never commit
an unrelated branch's work or force-push shared release history.

## Accepted production source and updates

The previous local release was **personal.4**, packaged from
`29706e913739653b36facb03c67a62c8b531216e` and tagged `personal-1.23.4b.4`.
The installed apps are official Zen, Zen (Prod) and Zen (Dev). The two custom
apps retain their existing separate profiles. Bare Tab is for site search;
Up/Down navigate suggestions. Redundant alias suffixes are hidden in the badge
and accessibility label. All 77 JS tests and 5 Python safety/launcher tests pass.
Native production testing confirms the behavior. See Production.md for current
package paths and verified evidence. The personal.3 startup-fix history follows.


The user accepted personal.2 on 2026-10-26. Production now contains the accepted
commands/search/layout code. A startup check found that the launcher must resolve
its application.ini path before passing it to Gecko: parent segments caused
URLPreloader to miss the built-in-addon manifest. personal.3 fixes that path;
all six bundled components reappear in Dev's startup registry. No builtin assets
or security checks were removed or overridden. The native macOS launcher test
executes the real C launcher against a synthetic engine and checks canonical
paths, profile isolation and rejected profile overrides.

The personal.3 packaged runtime source is
`5ff99997dc1be5546231d7eccf83d40f52f9c05a`, tagged `personal-1.23.4b.3`.
See [Production.md](Production.md) for promotion evidence and remaining checks,
and [Arc Commands.md](Arc%20Commands.md) for the 50-test command implementation
and previous Dev smoke tests. Later tooling/documentation commits do not imply
that installed apps have been rebuilt.

The installed custom production app is distinct from the official vendor app.
The official app and original profile stay separate from both custom profiles;
full rollback copies remain outside Git. Dev remains isolated and signed out. Build future candidates from
a verified official base app, never from the customized `/Applications/Zen (Prod).app`.
The parent workspace handoff contains the local official-base/backup paths.

For upstream updates, fetch tags, merge the selected release into an update
branch based on personal/dev, review conflicts and overlay anchors, update the
pin, obtain the matching official base, rebuild, test Dev, then promote that
source to personal/production. Preserve the previous app and closed-profile
snapshot for rollback. Never downgrade a live profile in place.

The custom apps disable upstream automatic binary updates; no custom updater or
scheduled monitor exists. Security releases need prompt manual rebuilding and
promotion. Leave inherited upstream release workflows disabled in this fork.

1Password needs its actual browser integration checked for the production
signing identity. Passkeys, DRM playback, native messaging and OS link routing
remain separate integration checks; a copied cookie database or valid signature
does not prove them. The historical local candidates were not Apple-notarized; public personal.5 is signed, notarized and stapled.
