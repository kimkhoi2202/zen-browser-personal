# Yab-style Picture-in-Picture

The user asked for a Yab/Arc-style PiP for Zen and accepted the independent
implementation developed in `~/Documents/Zen Browser - Independent PiP`
(isolated "Zen (PiP Preview)" app, 2026-10-30/31). On 2026-10-31 they lifted
that project's isolation rule and asked for it in the daily Zen and this fork.
Its `feature/yab-style-pip` (13 commits on upstream 1.23.4b) is merged here
unchanged; the older PiP prototypes in `Native PiP`, `PiP Motion` and
`PiP Placement` are not part of it.

## What it does

- Native macOS player chrome (`src/zen/pip`): Liquid Glass controls
  (`NSGlassEffectView`, SF Symbols, `NSSlider`) with Apple's published values
  for glass over media — Clear, untinted, over a 35% dark dimming layer — and
  the system's own Reduce Transparency / Increase Contrast handling. Speed,
  captions and sound on the left; back to tab, minimize and close on the
  right, close in the corner (sides swapped in personal.18, that order in
  personal.19, both at the owner's request); ±15 s and play/pause centered;
  glass timeline. Tab, Shift-Tab and VoiceOver follow the same order.
- The speed button is a glass gauge whose needle shows the speed (up at 1×,
  leaning left when slower, right when faster); it drops down a native
  "Playback speed" menu with the current speed checked (personal.19; it
  showed "1×" as text before).
- Double-clicking a corner of the player does nothing: AppKit would grow the
  window toward the screen corner, so the chrome drops the second press on
  the resize border. A double-click on the video toggles playback
  (personal.19).
- Physical motion: drag, flick with momentum into corners, rubber-band edges,
  two-finger carry, corner-anchored resize, always inside the usable area of
  the source window's display and following that window. Holding it at an
  edge shared with another display for about 0.2 s moves it there.
- Minimize tucks the player into a glass pill at the screen edge.
- Captions use System Settings > Accessibility > Captions.
- Live streams show a glass Live badge at the bottom left (known glitch: for
  2–3 s after Go to live, while YouTube buffers and reports no window end,
  the bar collapses to the status bubble). A stream that
  can't be scrubbed shows only the badge (red dot, no timeline, not a
  button). A stream with a DVR window keeps the timeline, spanning the
  window, and the badge becomes a Go to live button: red at the live edge,
  grey behind it, like YouTube's (built as personal.16 and .17; first
  installed in personal.18, which also carries the personal.15.3
  external-link startup fix).
- Arc-style automatic PiP: a playing, audible video pops out when its tab or
  Space is left and returns inline when it is selected again
  (`media.videocontrols.picture-in-picture.enable-when-switching-tabs.enabled`
  now defaults to true). Tunables are the `zen.pip.*` prefs in
  `prefs/zen/pip.yaml`; `zen.pip.native-controls.enabled=false` restores the
  stock player.

Maintainer notes: `src/zen/pip/README.md`. The development record, research,
tests and evidence are in the Independent PiP project's README and Evidence
folder.

## Packaging

The chrome is native code compiled into the engine, so a package that
includes it is built with `scripts/personal/build_engine.sh` and
`build_macos.py --source-built` ([Native Engine Builds](Native%20Engine%20Builds.md));
the released-engine artifact path cannot carry it. Frontend-only personal
changes still package the same way on top of that engine.

## Verification and installation — personal.19

personal.19 = a new full-source engine from `ecbcde23` (gauge speed button
with its Playback speed menu; back to tab, minimize, close; corner
double-click fix; built by `build_engine.sh` prepare/optimized/locales/
package, reusing the October 31 PGO profile: optimized stage 16 min),
packaged from the same commit. The installed personal.15.3 external-link
fix carries over unchanged.

- Source checks: 112 Node and 16 Python fork tests; the PiP's 386 geometry
  checks; native harness layout 156 (every size and timeline kind, top-row
  order), keys (Tab / Shift-Tab), clicks 12 (queued double-clicks on all
  corners and the video, the speed menu), motion 39.
- Browser checks on the Dev candidate (throwaway profile): 40/40, then the
  rest 59/61; the two misses were a race in the test itself (right after Go
  to live, YouTube reports no window end for about 2.5 s), fixed in the test
  and re-run 14/14. One run lost its test tab mid-run (the test window was in
  front of the owner's work at the time); the same steps re-ran 5/5.
- Frontend comparison with the installed personal.18: browser/omni.ja
  identical (13,526 entries); toolkit omni.ja differs only in build metadata
  (`buildconfig.html`, `AppConstants.sys.mjs`). The change is all native.
- Production candidate `dist/yab-pip-personal.19-production` (kept as
  `Zen.app.disabled` and unregistered from Launch Services): Developer ID
  signed with the installed app's designated requirement; notarization
  884e4537-a698-45cc-8c0e-b199e536533d Accepted, stapled, Gatekeeper
  accepted. Stapling and the Gatekeeper check register a bundle even under a
  `.app.disabled` name, and older disabled copies had been re-registered;
  all were unregistered so only `/Applications/Zen.app` holds `com.kimkhoi.zen`.
- Installed 2026-11-03 13:58 with the owner's approval while Zen was closed:
  20,340 profile fingerprints unchanged; installed bytes match the candidate;
  signature, staple and Gatekeeper verified in place; the installed XUL
  carries the new chrome. http/https still open `com.kimkhoi.zen`. Rollback:
  `Previous Zen.app.disabled` (personal.18) and the profile copy in
  `Backups/Yab Style PiP 2026-11-03 13-58-01`.

## Verification and installation — personal.18

personal.18 = the personal.17 engine (source `3aa3815b`: Live badge, swapped
top row, Tab fix; built by `build_engine.sh` with PGO and ThinLTO, 17 min)
packaged from `d4b6e697`, which adds the installed personal.15.3
external-link startup fix (a frontend overlay; no engine change).
personal.16 (Live only) and personal.17 were built and tested as candidates
but not installed.

- Source checks: 112 Node and 16 Python fork tests; the PiP's 386 geometry
  checks; native harness layout 141 (every size with on-demand, live and live
  DVR timelines), keys (Tab / Shift-Tab cycles), motion 39.
- Browser checks (independent project's `pip_integration_tests.py`):
  personal.17 Dev candidate 92/94; the two misses are YouTube resetting its
  own live video after a jump to the live edge (reproduced without PiP; Firefox
  then closes the player because the video was emptied). Live checks 14/14 on
  the personal.16 candidate; personal.18 Dev candidate smoke run 33/33.
- Frontend comparison with the installed personal.15.3: only the PiP files,
  en-US strings and build metadata differ (40 locale coverage lists name the
  two new untranslated strings).
- Developer ID signed with the installed app's designated requirement;
  notarization b54c424f-f14d-4781-8a15-41a1ba9dafbb Accepted, stapled,
  Gatekeeper accepted.
- Installed 2026-10-31 20:47 while Zen was closed; 7,326 profile fingerprints
  unchanged; installed bytes match the candidate. Rollback: `Previous
  Zen.app.disabled` (personal.15.3) and the profile copy in `Backups/Yab
  Style PiP 2026-10-31 20-47-54`.
- Building it showed that `npm run import` in an existing tree fails when a
  patch changed since the last import; `build_engine.sh prepare` now starts
  patched files from pristine Firefox.

## Verification and installation — personal.15

personal.15 is the installed personal.14 (command palette, source b6e28ada)
plus the PiP: engine source e6e37f23, packaging source b7d5372d.

- Source checks: 96 Node and 14 Python tests; the PiP's 386 geometry checks
  and native harness (layout 41, motion 39, on both displays).
- Engine: built by `build_engine.sh` (Zen release configuration with
  `MOZILLA_OFFICIAL`, `-O3`, ThinLTO, PGO from Zen's profile-server training,
  Mozilla's clang plugin, 40 UI languages), arm64. Times on an M5 Pro with 14
  jobs: instrumented build 16 min, training 16 min, optimized build 11–13 min,
  languages and packaging 1 min.
- Packaged Dev candidate on a throwaway profile: 78/78 PiP integration checks,
  including YouTube; the command palette, site search and Actions modules,
  palette stylesheet, single-toolbar default and 41 locales were present.
- Frontend comparison with the installed personal.14: every file identical
  except the PiP's, build metadata and the omitted updater modules.
- Production candidate: Developer ID signed (engine identity com.kimkhoi.zen,
  the installed app's designated requirement), Apple notarization
  51fd37a6-7f03-44d5-9270-d512e24853cc Accepted (the first submission was
  rejected for the unsigned ClearKey CDM, fixed in b7d5372d), stapled,
  Gatekeeper accepted.
- Installed 2026-10-31 16:04 with the user's approval while Zen was closed:
  13,764 profile fingerprints matched before launch; installed bytes match the
  candidate. The first launch recorded the new engine in compatibility.ini and
  all 12 user extensions stayed active. The Production user.js line forcing
  automatic PiP off (added 2026-10-29) was removed at the user's request.

Private rollback: `~/Library/Application Support/Zen Personal/Backups/Yab Style
PiP 2026-10-31 16-04-04` (Previous Zen.app.disabled = personal.14, Production
Profile Before Install, fingerprints, Installation.json). A rollback must
restore that profile copy too: the profile now records the newer engine.

Not verified natively in the daily app: the PiP itself (try a video), the
command palette after the engine change, passkeys, DRM, 1Password unlock.
Local engines carry no Zen API keys; the daily profile supplies the owner's
own Safe Browsing key (see Native Engine Builds.md).
