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
  and numeric time/duration/live alongside the formatted timestamp; live
  streams' seekable window, its timeline updates and Go to live (see Live
  streams); applies the system caption style and places captions just above
  the native timeline.
- `browser/extensions/pictureinpicture/video-wrappers/youtube-js.patch` –
  YouTube's live window and live edge from its own player.
- `toolkit/themes/shared/pictureinpicture/texttracks-css.patch` – caption box
  styled from the system caption style (only when it has been applied).
- `toolkit/themes/.../player-css.patch` – hides the HTML controls in native mode.
- `widget/cocoa/nsCocoaWindow-mm.patch` – `mainChildView` finds Gecko's
  `ChildView` instead of assuming it is the last content subview (the overlay
  sits above it).

## Glass

The glass follows Apple's published guidance for controls over media (HIG
"Materials"; WWDC25 "Meet Liquid Glass"): the **Clear** variant, untinted (tint
is reserved for emphasizing a primary action), above a uniform **35% dark
dimming layer** that fades in with the controls, carrying bold white SF
Symbols. The system applies Reduce Transparency (frostier) and Increase
Contrast (black/white with a border) to the material itself, so the chrome
does not switch variants; only the symbol weight follows Increase Contrast.
The minimized pill sits over arbitrary desktop content, not video, so it uses
the untinted **Regular** variant. The Liquid Glass look setting (System
Settings > Appearance) changes Regular glass such as the pill; Clear glass has
no adaptive behaviors and looks the same at any setting (measured in
`Evidence/Experiments` of the preview project).

Layout: playback options on the left — speed, captions, sound — and window
controls on the right — back to tab, minimize, close (in the corner). Creation
order (which VoiceOver follows) and the Tab order match that reading order.
Tab moves through that list itself (`-keyboardOrder`): since macOS 26 AppKit
inserts the controls' own subviews (button images, the slider's hosted
SwiftUI view) into the key-view loop, so `nextKeyView` alone no longer
reaches every control. A live stream's Live badge sits at the bottom left
(see Live streams).

The speed button is a round glass button like the others: an SF Symbols
gauge whose needle shows the speed (up at 1×, leaning left when slower and
right when faster; a plain `speedometer` before macOS 13). It drops down a
native menu headed "Playback speed" with 0.5× to 2× and the current speed
checked, including a speed the site chose itself (such as 1.1×). VoiceOver
reads the speed as the button's value.

Resizing: the chrome resizes the player from its whole border itself, the
9 pt bands along the edges and the 18 pt squares at the corners (also just
outside the window), keeping a docked corner or edge and the aspect ratio. A
local event monitor takes every press there before AppKit sees it, together
with its drags and its release, so a press resizes the same way however many
clicks came before it: double-click and drag resizes like a single press, a
double-click alone changes nothing. AppKit would resize from its own areas
(about 7 pt in near the corners, 13 pt along a corner's diagonal, 3 pt at the
middle of an edge on macOS 27) with its own anchoring, and grows the window
toward the screen corner whenever two presses land on a corner within the
double-click interval: it times them itself and ignores the click count.
Controls drawn on the border (small players bring the top row and timeline
within it) still get their presses; the empty corners of their squares
resize. In the active app a border press makes the player the key window,
as a press on the video does; a Command-press, or one from another app,
leaves the key window alone. A double-click on the video toggles playback.

## Live streams

A live stream shows a glass **Live** badge with a dot at the bottom left,
following YouTube's own live indicator.

- A stream that can't be scrubbed (no DVR window, such as Claude FM on
  YouTube) shows only the badge: a red dot, no timeline and no skip buttons.
  The badge is status, not a control: it ignores clicks, takes no keyboard
  focus, has non-interactive glass and reads as static text "Live" in
  VoiceOver.
- A stream with a DVR window (most news channels) keeps the timeline beside
  the badge. The timeline spans the seekable window, so it can go to any
  point the site allows, and ±15 s works. The badge becomes a **Go to live**
  button; its dot is red at the live edge and grey behind it, and a click
  returns to the edge.

The window comes from the site wrapper's `getLiveWindow()` and the edge jump
from `goToLiveEdge()`. YouTube reports a placeholder `video.seekable` for live
streams, so its wrapper reads the player's own progress state
(`allowSeeking`, `seekableStart/End` minus `offset`, `isAtLiveHead`) and uses
`seekToLiveHead()`. Elsewhere the fallback trusts `video.seekable` for windows
of one minute to two days, treats the last 20 s as the live edge and jumps to
3 s before the end. Live streams have no formatted timestamp, so the child
sends `PictureInPicture:ZenLiveTimeline` on `timeupdate` and once a second
while paused (a paused stream falls behind the edge without events).

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
  the attached displays (`build.sh`, then `ZenPipChromeHarness <video> motion`;
  `layout` checks every size with an on-demand, live and live DVR timeline and
  the top-row order; `keys` checks the Tab and Shift-Tab cycle; `clicks`
  queues real presses, double-clicks, triple-clicks and drags on every corner
  and edge (inside AppKit's areas, inside the chrome's band, just outside),
  on a free and a docked player, a control on the border and the video, and
  checks the speed menu).
