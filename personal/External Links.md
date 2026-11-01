# Installed external-link startup fix — personal.15.3

Custom `/Applications/Zen.app` is installed locally from runtime source
`834cb52c0d880ec126df513bec8e9e467dbb004f`, revision `personal.15.3`.
It is Developer ID signed, Apple-notarized, stapled and Gatekeeper accepted.
No GitHub push, release or Actions run is part of this update.

Two problems caused links from other apps to appear as an empty startup view:

- macOS had registered old build copies under the daily app's bundle ID.
  Those registrations were removed and the installed app registered again.
- Firefox passes external startup URLs as an array. Workspace startup only
  recognized strings, and later restored windows could cover the requested page.
  `ZenSpaceManager.mjs` now recognizes the array, preserves its real startup tab,
  and activates that window after all workspace initialization and queued focus
  timers. Closed windows/tabs and deliberate tab changes cancel activation.

The restoration callback is nonblocking, so it does not deadlock workspace
initialization. Temporary debug tracing is absent from the final source.

## Verification

112 Node tests and 16 Python tests pass. Regression cases fail on the earlier
array-selection, window-focus and timer-order implementations. Native testing
used a separate `Zen (Dev - Links)` identity/profile and a full nine-window daily
session clone. Cold HTTPS, running-browser HTTPS and a repeated cold start with
two HTTPS URLs displayed the requested pages. Both requested tabs were retained.

After installation, a Finder `.webloc` opened the final requested HTTPS page
through the actual macOS default-browser route from fully closed daily Zen.
The requested page remained selected after all nine windows restored. A second
unique HTTPS request while Zen was running displayed correctly. Both temporary
daily test tabs were then closed. HTTP/HTTPS still default to `com.kimkhoi.zen`.

The native personal.15 PiP engine and all other archive payloads are unchanged.
The update preserved all 6,878 closed daily-profile file fingerprints before
launch, including 375 bookmarks, 80 folders and 12 active user extensions.
1Password, PiP behavior and Intel hardware were not retested by this hotfix.
The normal Dev app/profile and independent PiP build trees were left alone.

## Build and continuation

Read `Generation Scripts/External Links.md`. `frontend_hotfix.py` replaces only
`modules/zen/ZenSpaceManager.mjs` in an attested original personal.15 app and
re-signs the outer bundle. It rejects an already-hotfixed input. The original
personal.15 engine must be preserved; the vendor engine would drop native PiP.
The full `build_macos.py` now overlays the same module for future packages.
Merge this startup fix into future native/PiP work before promoting that work.

Private evidence, guarded installer and rollback copies are under
`~/Documents/Zen Browser/Private/External Link Routing 2026-10-31`.
`Installation.json`, `Native Verification.json` and `Current Status.md` record
the final state. `Profile Snapshot 3` is the byte-verified pre-install backup;
earlier snapshots/candidates are historical. The preceding personal.15.1 app
is retained under `Rollback.noindex` alongside the original personal.15 app.
Test/candidate bundles are disabled after verification to avoid stale macOS
registrations. Preserve those artifacts; do not publish private profile data.
