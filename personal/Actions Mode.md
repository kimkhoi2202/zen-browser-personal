# Actions mode and tab destinations

Arc was inspected using its actual command bar. Command-T followed by Tab on
empty input enters Actions mode. Typing Move to lists Space destinations and
matching folder pins. Typing a destination filters the results; Up/Down changes
the selected result. Backspace on an empty field leaves Actions mode. The
inspection did not move or pin any user tab.

Zen already has the native Actions chip and empty-Tab entry. This change adds
the missing Move to and Pin to destinations to that same provider and row UI.
It adds no second palette, polling loop, web-content injection or framework.

- Move to Space uses the same move and follow operations as Zen's tab context
  menu. It preserves the tab's pinned state. Arc calls its unpinned section
  Today; Zen keeps its own pinning semantics and does not silently unpin a tab.
- Pin to Space puts the current tab among that Space's top-level pins.
- Pin to Folder supports folders in other Spaces and nested folder paths.
  It pins the tab because Zen folders contain pinned tabs, expands the folder
  and follows the tab to its destination.
- Exact destination commands outrank learned fuzzy suggestions. Duplicate
  folder names retain separate full paths and are not silently disambiguated.
- Essential, empty, closing and private-window tabs have no destination actions.
  Split groups use only the native whole-split Space move. Pinning a single
  split child through these rows is not offered.
- Each row captures the original tab and revalidates it and the destination
  before execution. Switching tabs or deleting a destination invalidates stale
  rows. Site-search mode remains scoped to its search engine.

Implementation: PersonalCommandActions.mjs exports destinationActions and
composes searchable action/destination labels. ZenUBActionsProvider.sys.mjs
adds those rows and prioritizes exact matches over usage history. English labels
are in zen-command-palette.ftl; native localization fallback remains unchanged.

Source is isolated on feature/actions-destinations, based on personal.11,
with candidate revision personal.13. It deliberately excludes all stopped PiP
placement, native-player and motion branches. No PiP preference is changed.

Automated verification: 87 Node tests and 11 Python tests pass, including actual
provider loading with synthetic native services, query isolation, execution,
nested destinations and stale-result guards. Syntax and whitespace checks pass.
The signed Dev candidate passed native Actions entry/exit, Up/Down selection,
Tab retaining selection, Space moves, Space pinning, cross-Space folder pinning,
moving a folder pin to top-level pins, and y + Tab site search. Synthetic tabs
and a folder were created only in Dev. Its closed pre-test profile was backed
up and restored afterwards. Nested-folder execution and split groups have only
automated coverage. A Tab sent in the same tool call immediately after Command-T
was missed once; opening the bar before pressing Tab worked. No extra key handler
or timing workaround was added.

Production packaging is signed; Apple notarization and installation status are
recorded separately under the parent workspace's Private/Actions Command Bar.
The daily app has not yet been replaced. App controls timed out on its large
accessibility tree; do not confuse that with failed Dev verification.

Official reference: https://start.arc.net/command-bar-actions

Build locally with scripts/personal/build_macos.py using the unmodified vendor
Zen (Official).app and the existing Developer ID keychain identity. See
personal/HANDOFF.md and the parent workspace handoff for profile boundaries.
No GitHub push, release or publication was requested.
