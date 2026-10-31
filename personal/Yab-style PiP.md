# Yab-style Picture-in-Picture

The user asked for a Yab/Arc-style PiP for Zen and accepted the independent
implementation developed in `~/Documents/Zen Browser - Independent PiP`
(isolated "Zen (PiP Preview)" app, 2026-10-30/31). On 2026-10-31 they lifted
that project's isolation rule and asked for it in the daily Zen and this fork.
Its `feature/yab-style-pip` (9 commits on upstream 1.23.4b) is merged here
unchanged; the older PiP prototypes in `Native PiP`, `PiP Motion` and
`PiP Placement` are not part of it.

## What it does

- Native macOS player chrome (`src/zen/pip`): Liquid Glass controls
  (`NSGlassEffectView`, SF Symbols, `NSSlider`) with Apple's published values
  for glass over media — Clear, untinted, over a 35% dark dimming layer — and
  the system's own Reduce Transparency / Increase Contrast handling. Close,
  back to tab and minimize on the left; speed, captions and sound on the
  right; ±15 s and play/pause centered; glass timeline. Keyboard and VoiceOver
  follow the same order.
- Physical motion: drag, flick with momentum into corners, rubber-band edges,
  two-finger carry, corner-anchored resize, always inside the usable area of
  the source window's display and following that window. Holding it at an
  edge shared with another display for about 0.2 s moves it there.
- Minimize tucks the player into a glass pill at the screen edge.
- Captions use System Settings > Accessibility > Captions.
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
