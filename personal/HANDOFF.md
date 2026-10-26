# Continuing the personal Zen fork

This is the portable handoff for the personal browser code. The local workspace
is `~/Documents/Zen Browser`, with `Development` on `personal/dev` and `Production`
on `personal/production`. Read the parent workspace's AGENTS.md/HANDOFF.md for
machine-specific paths and the verified state after relocation.

## Goal and implementation

Maintain two app identities: **Zen Dev** for testing and **Zen** for accepted
daily releases. Each forces a different browser profile. The first personal
feature makes an exact search alias followed by bare Tab enter native site
search, with provider-colored badges resembling Arc. Up/Down, native Space,
unknown aliases, modifiers, IME, and lower selected suggestions retain native
handling. Search aliases are profile data, not hard-coded into the module.

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
| `scripts/personal/ui_patch.py` | Exact-anchor native Tab-handler overlay shared by both build paths |
| `scripts/personal/build_macos.py` | Checks the official base, repackages UI, creates identities/launcher, signs, records manifest |
| `scripts/personal/apply_to_engine.py` | Applies the native Tab overlay after full engine import |
| `scripts/personal/seed_dev_profile.py` | Explicitly copies only search aliases and keyboard registry into closed Dev |
| `personal/launcher.c` | Forces per-channel app ini and isolated profile; runs the native engine |
| `personal/channels.json` | Upstream pin, personal revision, app names, bundle/remoting IDs and profiles |
| `personal/entitlements.plist` | Local signing entitlement baseline |
| `scripts/personal/*.test.mjs` | 50 focused command/module/channel tests |
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
  --base /Applications/Zen.app \
  --channel dev \
  --identity 'Developer ID Application: Your Name (TEAMID)' \
  --output dist/dev-next
codesign --verify --deep --strict 'dist/dev-next/Zen Dev.app'
```

Do not build from the custom app as the base. Its modified native entry point
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

## Updates, promotion, and remaining work

`personal.2` extends the command registry and defaults to the native top-toolbar
layout. See [Arc Commands.md](Arc%20Commands.md) for the inspected Arc inventory,
supported actions, cache semantics and native verification. Its runtime source is
`0f3231e7d9b50de74d112fa2deed8a6285ae20dd`; the tested candidate is
`dist/commands-candidate/Zen Dev.app`, now installed at `/Applications/Zen Dev.app`.
Older candidates below remain historical; consult each candidate's own manifest.

The runtime implementation commit is
`2ae841dda57eaef058632044b864d813d007f63a`. Installed apps have not been rebuilt
merely because later handoff/documentation commits exist.

`personal/production` remains upstream commit
`541ee55196395ee8082862b83c84c90ab41d9f6d`. This baseline contains neither the
personal implementation nor these packaging scripts yet. The existing signed
production candidate was generated from the development implementation commit,
not from the production branch. It has not been native tested or promoted.

After the user's Dev acceptance, fast-forward the Production worktree to the
accepted revision, tag it, and rebuild the production identity. Back up the
closed daily browser/profile, copy the profile to the separate Production
directory, and verify bookmarks, workspaces, tabs, extensions and sign-ins before
switching the daily app. Keep the original app and profile backup for rollback.
Never test or downgrade directly against the daily profile.

Before promotion, verify real sites, extensions, 1Password trusted-browser
integration, passkeys, DRM playback, native messaging and external link handling.
Local signature verification does not establish Apple notarization. Dev currently
has search aliases/shortcuts only and is otherwise signed out.

For upstream updates, fetch tags, merge the selected release into an update
branch based on `personal/dev`, review conflicts and overlay anchors, update the
pin, obtain the matching official base, rebuild, test, and promote. The custom
apps disable upstream automatic binary updates; no custom updater or scheduled
monitor exists. Security releases need prompt manual rebuild/promotion. Leave
the inherited upstream release workflows disabled in this fork.
