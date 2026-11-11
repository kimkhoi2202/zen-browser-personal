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
