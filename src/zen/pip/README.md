# Native Picture-in-Picture chrome (macOS)

Yab-style Liquid Glass controls and Arc-style motion for Firefox's
Picture-in-Picture player, implemented with public AppKit APIs.

## What stays upstream

The video pipeline is Firefox's own: the player window shows a *visual clone*
of the page's `<video>` (`cloneElementVisually`), which shares the original
element's decoder, so there is no second decode and no frame copying. Playback
commands still travel through the stock `PictureInPictureParent/Child` actors
(and their site-specific video wrappers), so every control acts on the original
video. Automatic pop-out uses Firefox's tab-switch PiP
(`media.videocontrols.picture-in-picture.enable-when-switching-tabs.enabled`).

## What this module adds

| File | Role |
| --- | --- |
| `ZenPipGeometry.h` | Pure C++: allowed area (visible frame inset by the edge gap), clamping, display selection, momentum projection (WWDC18 "Designing Fluid Interfaces"), rubber band, release resolution (placement vs throw to a corner), anchored aspect-locked resize/pinch, analytic damped spring, release velocity. Unit tested. |
| `ZenPipNativeChrome.{h,mm}` | Pure AppKit (ARC, no Gecko headers): the overlay view with `NSGlassEffectView` controls in an `NSGlassEffectContainerView`, SF Symbols, native `NSSlider` timeline, hover/keyboard reveal, VoiceOver labels, reduced motion/transparency and increased contrast handling, drag/flick/carry/pinch/resize, display containment, minimize-to-edge pill. |
| `nsZenPipNativePlayer.{h,mm}` | XPCOM glue (`@mozilla.org/zen/pip-native-player;1`, macOS only): finds the player's `NSWindow`, owns the chrome, and defers every user intent into Gecko's event loop. |
| `nsIZenPipNativePlayer.idl` | The interface used by chrome JS. |
| `ZenPipNativeControls.sys.mjs` | Bridge used by `player.js`: maps native intents onto the stock player/actor paths, mirrors playback state into the chrome, localizes labels, persists the last placement, computes the initial frame on the source window's display. |

Patches to upstream files (in `src/`):

- `toolkit/.../content/player-js.patch` – attaches the session, mirrors state,
  routes keys, disables emulated fullscreen in native mode.
- `toolkit/.../PictureInPicture-sys-mjs.patch` – initial frame on the source
  window's display, numeric timeline, source-window tracking, and auto-PiP
  fixes (drop requests the user already came back from, close a player that
  finished opening after the user returned, one automatic player at a time).
- `toolkit/actors/PictureInPictureChild-sys-mjs.patch` – seek amount parameter
  and numeric time/duration/live alongside the formatted timestamp.
- `toolkit/themes/.../player-css.patch` – hides the HTML controls in native mode.
- `widget/cocoa/nsCocoaWindow-mm.patch` – `mainChildView` finds Gecko's
  `ChildView` instead of assuming it is the last content subview (the overlay
  sits above it).

## Preferences

`zen.pip.native-controls.enabled` (off = stock HTML controls), `zen.pip.edge-gap`,
`zen.pip.motion.*` (spring response/damping, throw deceleration, flick speed,
magnet distance, two-finger carry), `zen.pip.controls.idle-hide-ms`,
`zen.pip.last-placement`.

## Older macOS

`NSGlassEffectView` is macOS 26+. On macOS 11–25 the same controls are built on
`NSVisualEffectView` (HUD material) instead; `effectIsInteractive` is used only
on macOS 27+. Cursor shapes use the macOS 15 frame-resize cursors when present.
Off macOS the component is not registered and the stock player is unchanged.

## Tests

- `tests/geometry/ZenPipGeometryTests.cpp` – standalone unit tests (see header).
- `tests/harness/` – builds the chrome without Gecko over an AVPlayer video in a
  real floating panel, for screenshots and real-WindowServer motion checks on
  the attached displays (`build.sh`, then `ZenPipChromeHarness <video> motion`).
