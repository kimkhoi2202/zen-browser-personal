# Local public releases

All builds run on the maintainer's Mac. GitHub Actions must be disabled on
kimkhoi2202/zen-browser-personal before pushing or publishing. Do not enable the
inherited upstream scheduled/release workflows. GitHub Releases hosts the final
binary; no GitHub runner is needed.

The packager combines the official released native engine with this fork's UI
overlays. It does not compile the native engine. Both launcher architectures are
compiled to match the official universal engine. Original app names, identifiers,
Dev/Production profile separation and extension validation are retained.

## Source and base

Verify the latest stable upstream release through the GitHub release API. A fork's
behind count compares with upstream dev; it does not identify a stable update.
Update the upstream tag/SourceStamp in channels.json only after reviewing source
conflicts and matching overlays against the new official base. Unreleased keyboard
rewrites must not be silently mixed into a stable-engine artifact.

Commit all reviewed source changes before packaging. The local builder refuses a
dirty tree, a stale stable pin, the wrong vendor app, or existing output directories.
Use a new personal.N revision and a matching personal-UPSTREAM.N tag. Never move a
published release tag. Tag the exact source commit captured by Build.json.

## Credentials

Reuse the owner's local Developer ID signing identity. The public certificate is
not a secret; its private key must stay in Keychain. Apple notarization uses a local
notarytool Keychain profile, default Zen Notary. The account owner creates and enters
an app-specific password privately with notarytool store-credentials. No password,
private signing key, browser profile or authentication file belongs in this repo.

## Commands

Run from the release source checkout. Substitute an existing Developer ID identity
and a new ignored output directory. The output path is absolute in the examples
only for clarity; the CLI resolves relative paths too.

    python3 scripts/personal/release_macos.py prepare --base '/Applications/Zen.app' --identity 'Developer ID Application: Your Name (TEAMID)' --output dist/public-personal.N
    python3 scripts/personal/release_macos.py notarize --identity 'Developer ID Application: Your Name (TEAMID)' --keychain-profile 'Zen Notary' --output dist/public-personal.N

Preparation runs the focused tests, packages only the clean app, audits private-data
filenames/symlinks, and stages an Applications shortcut, license and source notice.
The private builder manifest is kept outside the disk-image staging folder. Public
Build.json contains no absolute machine paths. Check the generated Source.md links.

Notarization submits the app ZIP to Apple, records the submission ID and waits for
acceptance. It staples and validates the app ticket, creates/signs a DMG, notarizes
and staples that DMG, verifies its contents and checks Gatekeeper assessments. The
submission reports are private candidate metadata. Preserve failed reports/logs;
never bypass Gatekeeper or publish an unaccepted candidate.

## Native verification and publication

Test the exact packaged production app with app-scoped CUA, including a fresh
profile and the existing daily profile with a verified closed-profile backup.
Never launch two apps against the same profile. Preserve originals and rollback
copies outside Git. Record the actual test platform; a universal binary is not
proof of Intel hardware testing. Never imply Windows/Linux packages exist.

After the native checks, push the exact source commit and its matching tag to origin,
then run:

    python3 scripts/personal/release_macos.py publish --native-tested --output dist/public-personal.N

This creates a draft release with four explicitly selected assets: DMG, SHA256SUMS.txt,
Build.json and Source.md. It downloads the draft DMG, verifies the uploaded hash, then
publishes. The native-tested flag is a human verification gate, not an automated UI
test. Nothing under the private manifests, Stage or browser profiles is uploaded.

Users receive manual updates from this fork's Releases page. No custom updater has
been implemented. Keep upstream security updates current. Preserve MPL notices and
link the exact fork source and complete upstream engine source in every release.
