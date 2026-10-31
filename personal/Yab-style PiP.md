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
