# Native engine builds

Until personal.13 every change was frontend-only, so packages reused the
official released engine and `build_macos.py` swapped in the fork's modules.
The Yab-style PiP adds native code (`src/zen/pip`, a Cocoa widget patch), so a
package that includes it needs the engine compiled from this fork's source.
The released-engine path stays available for frontend-only changes.

## Build tree

Use a detached worktree outside iCloud-synced folders; Firefox source, two
object directories and the PGO data take about 45 GB:

    git -C Development worktree add --detach ~/Developer/Zen-Personal-PiP-Build.noindex/zen-desktop <commit>
    cd ~/Developer/Zen-Personal-PiP-Build.noindex/zen-desktop
    npm ci
    npm run download

`surfer download` needs GNU tar on macOS. Without it, unpack the pinned
`firefox-VERSION.source.tar.xz` with `tar -xf … --strip-components 1 -C engine`
and initialize `engine/` the way surfer does: `git init`,
`git checkout --orphan VERSION`, `git add -f .`, `git commit -m "Firefox VERSION"`,
`git checkout -b zen_browser`. Set the brand with `npx surfer set brand release`
(or copy `.surfer/dynamicConfig.brand.json` from another tree). Mozilla's
toolchains are bootstrapped into `MOZBUILD_STATE_PATH`.

## Engine

    scripts/personal/build_engine.sh all

or its stages `prepare`, `instrumented`, `profile`, `optimized`, `locales`,
`package`. `prepare` returns every file the patches touch to the pinned
Firefox source before `npm run import`: surfer re-applies a patch by undoing
the same version first, so a patch that changed since the last import would
otherwise fail to apply in an existing tree.
It uses Zen's own release configuration (`configs/common` and `configs/macos`
with `ZEN_RELEASE`: optimize, release, Rust SIMD, `MOZILLA_OFFICIAL`,
cross-language ThinLTO, `-mcpu=apple-m1`, the 26.5 SDK) and Zen's two-stage
PGO: an instrumented build, Zen's profile-server training (it opens an
instrumented Zen window for several minutes and downloads Mozilla's pinned
JetStream corpus), then the optimized build. The updater is not built. The
engine records the checkout's HEAD as its SourceStamp, and the fork URL as its
source repository. Packaging includes Zen's 40 UI languages the way Zen's CI
does (`mach package-multi-locale`, the pinned `mozilla-l10n/firefox-l10n`
commit plus Zen's own strings); the `locales` stage replaces Zen's
`download-language-packs.sh`, which changes global git settings and deletes
folders in the home directory, so don't run that script on a personal Mac.
The build is arm64 only and runs natively on Apple Silicon.

## Package

    python3 scripts/personal/build_macos.py --source-built \
      --base ~/Developer/Zen-Personal-PiP-Build.noindex/zen-desktop/engine/obj-aarch64-apple-darwin/dist/zen/Zen.app \
      --channel production --identity 'Developer ID Application: Your Name (TEAMID)' --output dist/NAME

`--identity` is passed to codesign as is: when the keychain holds more than
one certificate with that name (as after a certificate renewal), codesign
calls it ambiguous; pass the SHA-1 fingerprint of the one that signed the
installed app instead (`security find-identity -v -p codesigning`).

The builder applies the same frontend overlays, identity, launcher, update
policy and signing as for the official engine. It refuses a source-built
engine whose compiled sources differ from the packaging checkout: only
packaging inputs, documentation and tooling may change after the engine build
(`engine_affecting` in `build_macos.py`, covered by `source_built_test.py`).
The manifest records the engine's source commit and build ID. Notarize,
staple, test and install exactly as for other candidates.

## Known differences from official engines

- API keys: Zen's CI compiles in its Google Safe Browsing, Mozilla and Google
  location keys from `~/.zen-keys/*.dat`. A local build has none unless the
  owner adds their own keys there before building. Without a Safe Browsing key
  the browser cannot download Google's phishing, malware and download-
  reputation lists; Mozilla's tracking-protection lists and CoreLocation
  geolocation are unaffected. Without rebuilding, a key can be supplied per
  profile: set the seven `browser.safebrowsing.*` URL prefs that contain
  `%GOOGLE_SAFEBROWSING_API_KEY%` in `all.js` to the same URLs with the key,
  and `browser.safebrowsing.provider.{google,google4,google5}.excludeFromGoogleSafeBrowsingKeyCheck`
  to true (SafeBrowsing.sys.mjs otherwise disables Google providers when the
  compiled key is the placeholder). The daily Production profile does this in
  a marked user.js block with the owner's key restricted to the Safe Browsing
  API; keep keys out of this repository.
- arm64 only. `release_macos.py prepare` still requires a universal engine for
  public releases.
- Upstream updates: merge the new stable tag, update `channels.json`, rebuild
  the engine and repackage. Nothing self-updates.
