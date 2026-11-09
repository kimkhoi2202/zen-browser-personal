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
  routes keys, disables emulated fullscreen in native mode, and closes a
  player window that never got set up.
- `toolkit/.../PictureInPicture-sys-mjs.patch` – initial frame on the source
  window's display, numeric timeline, source-window tracking, the native
  player's entrance and exit, and fixes: no player for a tab that closed or
  moved while the player opened (it stayed black with dead controls and
  couldn't be closed), a player closes when its video's page goes away
  without asking, auto-PiP drops requests the user already came back from
  and keeps one automatic player at a time, and Back to tab waits for a Space
  switch already under way.
- `toolkit/actors/PictureInPictureChild-sys-mjs.patch` – seek amount parameter
  and numeric time/duration/live alongside the formatted timestamp; live
  streams' seekable window, its timeline updates and Go to live (see Live
  streams); the video's place on screen and its buffering, ended and loaded
  state; applies the system caption style and places captions just above
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
The stash tab sits over arbitrary desktop content, not video, so it uses
the untinted **Regular** variant. The Liquid Glass look setting (System
Settings > Appearance) changes Regular glass such as the tab; Clear glass has
no adaptive behaviors and looks the same at any setting. The player's corner
radius follows the controls in its corners (their radius plus their inset),
so they are concentric with it.

Layout: playback options on the left — speed, captions, sound — and window
controls on the right — back to tab, minimize, close (in the corner);
right-to-left languages mirror that row, while the timeline and the transport
row keep their direction. Creation order (which VoiceOver follows) and the
Tab order match the reading order.
Tab moves through that list itself (`-keyboardOrder`): since macOS 26 AppKit
inserts the controls' own subviews (button images, the slider's hosted
SwiftUI view) into the key-view loop, so `nextKeyView` alone no longer
reaches every control. A live stream's Live badge sits at the bottom left
(see Live streams).

The speed button shows the speed itself ("1×", "1.5×"), a circle that grows
into a capsule for longer numbers. It drops down a native menu headed
"Playback speed" with 0.5× to 2× and the current speed checked, including a
speed the site chose itself (such as 1.1×). VoiceOver reads the speed as the
button's value. The play button shows a spinner once the video has waited
for data for 0.4 s, and a replay symbol at the end; the sound button's waves
fill with the volume. The timeline is a thin track, white up to the position
and lighter up to what has loaded, with its knob only while the pointer is on
it, it is dragged or it has keyboard focus.

Input: a local event monitor takes every left press in the player outside the
buttons and the slider before AppKit sees it, together with its drags and its
release. Presses on the 9 pt bands along the edges and the 18 pt squares at
the corners (also just outside the window) resize, keeping a docked corner or
edge and the aspect ratio, however many clicks came before them; the rest
drag or throw. AppKit would make the player the key window on every press
(so a drag from another app would take the keyboard), resize from its own
areas with its own anchoring, and grow the window toward the screen corner
whenever two presses land on a corner within the double-click interval. Only
a click, a press released without moving, takes the keyboard (not with
Command held). A double-click on the video toggles playback. Controls drawn
on the border (small players bring the top row and timeline within it) still
get their presses; the empty corners of their squares resize.

Keys: Space, ←/→ ±15 s, ↑/↓ volume, M, C, < >, Return (back to the tab), Esc
(close; Shift-Esc keeps playing), ⌘W, ⌘⌥⇧P, and ⌘M stashes the player. Other
Command shortcuts (⌘Q, ⌘H, ⌘,) run the menu bar's items, as in any Zen
window. The player stays on screen when Zen is hidden.

## Motion

The controls appear in 150 ms (ease-out) and leave in 150 ms when the pointer
leaves (ease-in), 250 ms after a while without activity. A new player grows
out of the video in its page (a fade for automatic Picture-in-Picture);
back to the tab it shrinks into the video again, and closing it fades it out.
A drag that reaches the edge of the display gives a trackpad tick.

Minimize stashes the player into the nearer side of its display, the way
macOS stashes its own Picture-in-Picture: it slides off the screen and leaves
a glass tab at the edge. Pushing the player far past a side while dragging
(40% of its width) and letting go stashes it too, with a second tick when it
gets that far. A click on the tab, Space or Return once the tab has keyboard
focus (window cycling reaches it) or VoiceOver brings it back; dragging the
tab moves it along the edge. It never stashes into a side with another display
beyond it, and Reduce Motion turns the slides into fades.

Several players keep out of each other's way: a throw avoids corners another
player takes, a new player opened over another moves to a free corner, and
stash tabs stack along the edge.

## Live streams

A live stream shows a glass **Live** badge with a dot at the bottom left,
following YouTube's own live indicator: a filled red dot at the live edge and
a grey ring behind it, so the two differ by shape as well as color. Speeds
above 1× are off at the live edge.

- A stream that can't be scrubbed (no DVR window) shows only the badge: a
  red dot, no timeline, no skip or speed buttons, and ←/→ do nothing.
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
back. When the usable area changes (the Dock or menu bar shown, hidden or
moved), the player goes back to the edges it rests against; window managers
and the Zoom command can't move it out of its area.

## Preferences

`zen.pip.native-controls.enabled` (off = stock HTML controls), `zen.pip.edge-gap`,
`zen.pip.motion.two-finger-carry`, `zen.pip.controls.idle-hide-ms`,
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
