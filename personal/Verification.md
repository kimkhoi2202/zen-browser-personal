# Initial verification — 2026-10-25

For the updated `personal.2` command/toolbar build and its 50-test suite, see
[Arc Commands.md](Arc%20Commands.md). The initial build record below is historical.

Base: upstream Zen 1.23.4b, commit `541ee55196395ee8082862b83c84c90ab41d9f6d`.
Artifacts reuse the official native engine with modified frontend modules;
no full Firefox/C++ compilation was performed.

## Observed in the native macOS app

- Zen Dev launches with bundle ID `com.kimkhoi.zen.dev` and its forced Dev
  profile. The running engine arguments confirm the separate profile path.
- `y` then Tab enters native YouTube search; the badge is red. Entering
  `guitar` then Return loads YouTube's results for that query.
- Tab activates the configured aliases `maps`, `crunchyroll`, `crunch`,
  `chordify`, `chord`, `x`, `instagram`, `insta`, and `drive`.
- The Drive badge is blue. Up/Down still move through suggestions. Empty Tab
  still enters native Actions, including Toggle Compact Mode and Open Library.
- After installing and restarting Dev, YouTube Tab search and its red badge
  still work. Native Space-to-search remains available.
- After correcting the first-run keyboard migration version, Command-Shift-,
  hides and restores the sidebar; Command-S opens Library; Command-Shift-2 opens
  the screenshot tool. The screenshot was cancelled without saving.
- Both Dev and production candidate bundles pass deep, strict macOS signature
  verification. The installed Dev copy also passes.

## Automated verification

36 module/channel tests pass. They cover exact aliases, autocomplete, modifiers,
IME, ambiguous/unknown aliases, selected suggestions, existing search mode,
provider styling/cleanup, color contrast, and channel separation. JavaScript and
Python syntax checks and patch-anchor checks pass.

## Release status and remaining checks

Dev is installed and ready for user testing. It contains copied search aliases
and keyboard configuration only; no passwords, cookies, history, or extensions
were imported. Its browsing history contains only its own smoke-test navigation.

The signed production candidate has not been launched, installed, promoted, or
set as the default. `personal/production` remains the upstream baseline until
the user accepts Dev. The current official Zen app is preserved.

Before daily production use, verify the user's real sites, extension installs,
1Password trusted-browser integration, passkeys, native messaging, DRM playback,
profile migration, and external link handling. Local Developer ID signing is
verified; Apple notarization has not been performed. Upstream automatic binary
updates are disabled only in custom apps, so new security releases require a
prompt rebuild, test, and promotion through this workflow.
