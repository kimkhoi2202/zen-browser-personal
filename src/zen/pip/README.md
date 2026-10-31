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
| `ZenPipNativeChrome.{h,mm}` | Pure AppKit (ARC, no Gecko headers): the overlay view with `NSGlassEffectView` controls in an `NSGlassEffectContainerView` (Clear variant over a dimming layer, see below), SF Symbols, native `NSSlider` timeline, hover/keyboard reveal, VoiceOver labels, reduced motion/transparency and increased contrast handling, drag/flick/carry/pinch/resize, display containment and dragging onto other displays, minimize-to-edge pill. |
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
  and numeric time/duration/live alongside the formatted timestamp; applies the
  system caption style and places captions just above the native timeline.
- `toolkit/themes/shared/pictureinpicture/texttracks-css.patch` – caption box
  styled from the system caption style (only when it has been applied).
- `toolkit/themes/.../player-css.patch` – hides the HTML controls in native mode.
- `widget/cocoa/nsCocoaWindow-mm.patch` – `mainChildView` finds Gecko's
  `ChildView` instead of assuming it is the last content subview (the overlay
  sits above it).

## Glass

Over video the controls use the **Clear** glass variant above a dimming layer
(the video is dimmed 20% while the controls show, 32-35% behind the top row and
the timeline), with a 6% black tint — Apple's guidance for glass over media
(WWDC25 "Meet Liquid Glass"). That keeps white symbols at >= 3:1 contrast even
over very bright frames (measured in `Evidence/Experiments` of the preview
project). Increase Contrast and Reduce Transparency switch to the frosted
**Regular** variant with a 45% / 32% tint; the minimized pill sits over the
desktop, not video, so it is always Regular. The system Liquid Glass setting
(System Settings > Appearance) applies on top, as for any system glass.

Layout: window controls on the left — close, back to tab, minimize — and
playback options on the right — speed, captions, sound. Creation order (which
VoiceOver follows) and the Tab order match that reading order.

## Captions

Captions use the system caption style (System Settings > Accessibility >
Captions), read through the public MediaAccessibility API, the same
preferences Apple's own players and Safari follow: font (SF Pro by default),
text color and opacity, the caption box color, opacity and corner radius,
text edge style and relative size. The chrome sends it as CSS-ready values
when the player opens and whenever the setting changes; the player page
renders WebVTT and site captions (YouTube etc.) with it and keeps them just
above the timeline while the controls show. Apple's per-line text
background is drawn as the caption box when the box itself is transparent.

## Displays

The player lives on its *home* display: by default the display of the source
browser window (it follows that window to another display), always fully
inside its usable area with a 10 pt gap. Dragging it past the edge of its
display holds it at that edge, so it can be put exactly into a corner or edge
shared with another display. It crosses only when the drag keeps pushing:
the pointer at least 16 pt onto the other display and the drag at least a
quarter of the player's size past the edge (48-160 pt), sustained for
0.22 s (a one-shot timer covers a pointer held still). Then it hops onto that
display (no flight across, so it is never split between displays) and keeps
moving 1:1 with the pointer. Throws and quick pushes into a shared corner
therefore stay on the current display. The new display becomes its home: it
stays there while the source window moves, until it is dragged back (then it
follows the source window again). If the home display disconnects it falls
back to the source window's display, and returns when the display comes
back.

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
