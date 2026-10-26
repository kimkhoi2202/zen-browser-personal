# Personal Zen

For another agent continuing this project, start with [HANDOFF.md](HANDOFF.md).
The local source workspace is now `~/Documents/Zen Browser`, with `Development`
and `Production` as separate Git worktrees.

Two channels from the same reviewed source:

| Channel | App | Bundle ID | Profile |
|---|---|---|---|
| Dev | Zen Dev | com.kimkhoi.zen.dev | ~/Library/Application Support/Zen Personal/Dev |
| Production | Zen | com.kimkhoi.zen | ~/Library/Application Support/Zen Personal/Production |

The existing vendor app is a fallback until development testing and promotion.
No script in this repository overwrites it or imports credentials automatically.
Browser profiles, cookies, vaults, signing keys and local auth never belong in Git.

## First build: released engine plus custom UI

The initial personal build reuses the correctly signed official 1.23.4b engine
and repackages source-controlled frontend modules. It is not a full Firefox
compile. This retains the vendor's native engine and avoids its large build
footprint. The resulting apps are locally signed with the owner's Developer ID;
no certificate private key is uploaded to GitHub. The original app stays intact.

The internal Gecko application ID remains the upstream compatibility ID.
The bundle ID, remoting identity, app name and forced profile distinguish the
channels, while retaining Firefox extension/blocklist compatibility assumptions.

`scripts/personal/build_macos.py` validates the base's signature and pinned
SourceStamp, normalizes the browser resource archive, installs the reviewed
modules, gives each app its own application/remoting/bundle identity, compiles
a native launcher, and verifies the final code signature. The launcher forces
the isolated channel profile and supports the native `-app` application-data
mechanism documented in the vendor's application.ini. Test that mechanism in
the actual app before declaring profile isolation verified.

`seed_dev_profile.py --source /path/to/current/profile` copies only native search
aliases and shortcuts while Dev is closed. It copies the keyboard migration
version too: otherwise Zen's first-run migration resets the imported shortcuts.
It does not copy browsing history, cookies, logins, vault state or extensions.

Run Node tests, then build with an existing local signing identity:

    node --test scripts/personal/site_search.test.mjs
    python3 scripts/personal/build_macos.py --channel dev --identity 'Developer ID Application: Your Name (TEAMID)'
    python3 scripts/personal/build_macos.py --channel production --identity 'Developer ID Application: Your Name (TEAMID)'

Artifacts and machine manifests are under ignored `dist/`. They start as
packaged candidates, not tested production releases. The current archive format
is accepted by Gecko; invalid base revisions/patch anchors fail rather than
silently producing an unmodified app.

The manifest records the source commit, whether the tree was dirty, source-file
hashes, and the modified resource archive hash. Keep it with the candidate.
See [the initial native verification record](Verification.md) for completed
checks and the integration work still needed before daily use.

The first Dev app is installed at `/Applications/Zen Dev.app`. The production
candidate stays in `dist/production-candidate/Zen.app`; it has not replaced
`/Applications/Zen.app`. Dev is signed out and has no migrated extensions.
Both channels can run alongside the vendor browser, using their own profiles.

## Changes

Bare Tab on an exact configured search alias enters that engine's native search
mode. User-typed text wins over autocomplete. Unknown aliases, an already
selected lower suggestion, modifier combinations, existing search mode and
ordinary webpage Tab preserve native handling. Empty Tab still opens commands;
Space and Up/Down remain available.

The search badge uses provider-specific, white-on-dark colors for the approved
sites, including red YouTube, green Maps/Chordify and orange Crunchyroll. Unknown
providers retain the user's theme. The styling updates with reduced motion on
or off and clears when leaving search mode.

## Updating and promotion

Keep personal changes on `personal/dev`; `personal/production` identifies the
reviewed production source and stays at the upstream base until user acceptance.
Fetch upstream release tags and merge the selected
release into a temporary update branch. Review source/patch conflicts, change
the pin in channels.json, rebuild both artifacts and repeat the native checks.
Never copy binaries from an upstream update over the custom app: its updater is
disabled by enterprise policy. Upstream security releases must be rebuilt and
promoted promptly. No scheduled monitor or unattended upgrade is installed.

Typical update preparation, substituting an actual upstream release tag:

```sh
git fetch upstream --tags
git switch -c update/zen-VERSION personal/dev
git merge VERSION
```

Resolve conflicts without discarding the personal module or native Tab overlay.
Update `personal/channels.json` to the selected tag and its verified commit.
Obtain the matching official macOS release as the new `--base`; the builder
rejects a different SourceStamp. Run the checks, rebuild Dev, test it, then merge
the reviewed update into `personal/dev`. Avoid rebasing already-shared release
branches. `upstream` has a disabled push URL; only `origin` receives personal work.

The fork uses its own lightweight `Personal Zen checks` workflow. Upstream release
and synchronization workflows stay disabled in the fork; they are not our update
service. Build apps locally so the signing key stays in the macOS keychain.

After testing Dev, promote that exact source revision into production. Keep
the two compiled identities/profiles distinct. Promotion must back up and copy
the current migrated Zen profile while it is closed; preserve its source and
verify bookmarks, spaces, shortcuts, extensions and sign-ins before making the
custom production app the default. Do not point Dev at the daily profile.

Promote the tested source with a fast-forward of `personal/production` to the
accepted `personal/dev` commit, and tag that revision before the production
rebuild. Keep the previous signed production app and its closed-profile backup
for rollback. A rollback must restore the matching profile backup too if the
newer engine upgraded its data. Never downgrade the live profile in place.

1Password desktop integration needs separate trusted-browser authorization.
The initial local signing entitlements do not claim the vendor's restricted
passkey entitlement/provisioning identity; passkeys, DRM and native messaging
are explicit integration checks before daily use. Developer-ID signing alone
is not a claim of Apple notarization.

## Full-source build path

The fork includes Zen's original build machinery. `npm run init` imports the
tracked Zen source and patches, including PersonalSiteSearch.mjs and the
ZenUrlbarController theme hook. Then run `python3 scripts/personal/apply_to_engine.py`
and `npm run build`. This separate exact-anchor overlay patches Tab dispatch.
Brand/profile/bundle/update identities must be configured for a full native
compile too; the artifact builder's identity changes are not magically applied
to a full-source build. See Zen's official contribution/build documentation.

The first task is to establish the lightweight tested artifact workflow, not
to claim a successfully compiled native engine that has not been compiled.
