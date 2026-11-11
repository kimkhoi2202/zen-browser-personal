# Sidebar width reset — personal.24

Double-clicking the sidebar's edge puts the sidebar back to its default width
(230 px on macOS). In Zen 1.23.4b that only half worked:

- on the pinned sidebar the double-click changed the width you see, but not
  the width the floating sidebar (compact mode, shown on hover) uses, so the
  two had different widths until the next restart;
- on the floating sidebar the double-click changed nothing you could see, and
  the pinned sidebar then came back at the default width while the floating
  one kept the old one.

The sidebar keeps its width in three places on `#navigator-toolbox`: the
inline `width`, the `--zen-sidebar-width` variable and the saved `width`
attribute. Dragging the edge writes all three. The double-click handler in
`src/zen/common/sys/ZenCustomizableUI.sys.mjs` wrote only the first and the
last; the floating sidebar is sized by the variable (`#titlebar` in
`src/zen/compact-mode/sidebar.inc.css`).

## Fix

Upstream fixed this after 1.23.4b: `bd2d6198`, "gh-16016: Update the sidebar
layout after resetting its width (gh-16075)". The fork carries that commit
unchanged as a cherry-pick (`419317b7`), so it disappears into upstream at the
next rebase onto a newer Zen release.

The module is JavaScript only. `build_macos.py` overlays it onto the packaged
engine (`ADDITIONAL_UI`), the same way as `ZenSpaceManager.mjs`, so no engine
rebuild is needed: personal.24 is the personal.23 engine (`0ce926d8`, round 10
of the Yab-style PiP) with this one module replaced.

## Verification — personal.24 (candidate, not installed yet)

- Source checks: 112 Node and 16 Python fork tests pass
  (`source_built_test.py` covers the new overlay path).
- Browser checks, headless on the Dev candidates' throwaway profile, with
  real pointer input through Marionette (move, press, release; the
  double-click is two presses on the edge): the independent PiP project's
  `Release Build Scripts/sidebar_width_tests.py`. On personal.23 4 of 10
  pass: after a reset the pinned sidebar is 230 px while
  `--zen-sidebar-width`, and so the floating sidebar, keeps the dragged
  width; a double-click on the floating sidebar's edge changes nothing
  visible. On personal.24 10 of 10 pass, twice: the reset writes all three
  widths in both states, the floating sidebar is as wide as the pinned one
  and the other way round, and a width dragged while floating carries over
  to the pinned sidebar. Screenshots show both at the same width.
- Known behavior, same as upstream: when the floating sidebar is wider than
  the default, the reset shrinks it away from the pointer, so it slides out
  after the usual 150 ms; hovering again shows it at the default width.
- Not checked: a sidebar on the right side (the handler does not depend on
  the side), and the Picture-in-Picture suite on personal.24 (its files are
  the personal.23 ones, see below).
- Frontend comparison: against the personal.23 candidate only
  `modules/ZenCustomizableUI.sys.mjs` differs (13,525 other entries in
  browser/omni.ja and all 8,731 in the toolkit omni.ja are identical), and
  both were packaged from the same engine (build ID 20261109212236). Against
  the installed personal.22 the candidate differs in that module, the two
  Picture-in-Picture modules of round 10 and the engine's build metadata.
- Production candidate `dist/yab-pip-personal.24-production` (kept as
  `Zen.app.disabled`, unregistered from Launch Services): packaged from
  `e7a4b95b`, signed by fingerprint with the installed app's certificate and
  satisfying its designated requirement; notarization
  a8d87d12-59bc-4b4c-b197-940dc627a2a1 Accepted (no issues), stapled,
  Gatekeeper accepted. Only `/Applications/Zen.app` holds `com.kimkhoi.zen`;
  http and https still open in it.
- Not installed: it needs the owner's approval with Zen closed
  (`Private/Yab Style PiP/Install Ready.py` with the candidate and
  `e7a4b95bb4fdc69332d9069ab67ad1f8392719a7`). It replaces the personal.23
  candidate, which was never installed.
