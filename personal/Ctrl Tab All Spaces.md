# Ctrl+Tab across all Spaces

The owner asked (2026-11-14) for Ctrl+Tab to show the most recently used tabs
of the whole browser window, not only those of the Space they are in.

## Before

With "Ctrl+Tab cycles through tabs in recently used order" on
(`browser.ctrlTab.sortByRecentlyUsed`), Firefox's switcher
(`browser-ctrlTab.js`) builds its list from `gBrowser.tabs`. Zen narrows
`gBrowser.tabs` to the active Space (its pinned and normal tabs plus the
current Essentials), and `ZenSpaceManager` rebuilds the list on every Space
switch (`#fixCtrlTabBehavior`), so only the current Space's tabs appeared.

## Now

`src/browser/components/tabbrowser/content/browser-ctrlTab-js.patch`:

- The list is built from `gZenWorkspaces.allStoredTabs`: every Space's pinned
  and normal tabs (and tabs in folders/groups) in this window, sorted by when
  they were last used. Essentials are included only from the current
  container's Essentials, as before: selecting an Essential doesn't switch
  Spaces.
- Picking a tab from another Space switches to that Space and selects it
  (Zen's own `onBeforeTabSelect`).
- With exactly two tabs in the window, Ctrl+Tab flips between them, and the
  panel opens from three tabs, now counted across Spaces (it used to count the
  Space's visible tabs).
- Unchanged: unloaded tabs stay hidden unless `zen.ctrlTab.show-pending-tabs`
  is true; with recently-used order off, Ctrl+Tab behaves as before (it
  steps through the tab strip, not this list); private windows and windows
  without Spaces keep the stock behavior.

Pref: `zen.ctrlTab.all-spaces` (default true). False restores the per-Space
list (applies from the next Space switch or window).

The change is in a Firefox patch, so it needs an engine build
(`scripts/personal/build_engine.sh`), not only `build_macos.py`.
