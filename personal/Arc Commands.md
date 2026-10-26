# Arc-style commands — personal.2

Arc was inspected through its app-scoped command bar and native View, Tabs, and
File menus on 2026-10-26. The inspection used a disposable example.com tab, which
was closed afterwards. No user tab was refreshed, archived, or cleared.

Zen's existing global-action registry/provider, localized labels, native result
rows, shortcut display and browser commands are reused. There is no second
command palette or new visual framework. Normal search and configured site-search
modes remain available. A complete command or a literal prefix identifying just
one command can be the default result; ambiguous prefixes keep normal search.

## Added commands

| Command | Native implementation |
|---|---|
| Zoom In / Zoom Out / Zoom to Actual Size | Existing full-page zoom commands |
| Clear Cache and Refresh | Clear this profile's network cache, then native bypass-cache reload |
| Show Toolbar / Hide Toolbar | Zen's existing layout preferences and compact-mode methods |
| Show Sidebar / Hide Sidebar | Zen's existing compact-mode methods, preserving toolbar visibility |
| Use Sidebar Address Bar | Existing single-toolbar preference; reverses the top layout |
| Copy URL as Markdown | Existing Zen URL-copy command |
| Save Page As | Native page-save command and dialog |
| View Source | Native page-source command |
| Open Downloads / Open History | Native browser commands |
| Toggle Full Screen | Native full-screen command |
| Toggle Reader View | Native Reader View command, only when available |
| Developer Tools / Inspect Elements / JavaScript Console / Network Inspector | Native DevToolsShim and its tools; respects DevTools policy |

These are 20 new registry entries. Existing actions also recognize Arc names:
Refresh the Page, Force Refresh the Page, Restore Last Closed Tab, Duplicate Tab,
Copy URL, Add Split View, Close Split View, Expand Current Split, New Incognito
Window, New Window, Blank Window, Capture Page, Preferences and Find on Page.
They dispatch the existing Zen action rather than duplicating its implementation.

The top layout defaults to Zen's native **Sidebar and Top Toolbar**. It remains
reversible in Settings → Look and Feel, or through the layout commands.
Showing one chrome area preserves the other area's current visibility.

## Meaning of cache refresh

Clear Cache and Refresh clears the browser's network cache for this isolated
profile, then reloads the current page without using cached resources. It does
not delete cookies, local storage, history or passwords. Force Refresh remains
an alias for the existing bypass-cache reload, without the explicit cache clear.

Arc's Clear Cookies and Refresh, Clear Today, Clear Archive, Notes, Easels,
Little Arc, and Cast were observed but are not mapped to a different behavior.
Existing Zen close/reopen, spaces, folders, pinning, split-view, appearance,
screenshots, print, settings and extension actions remain available.

## Verification

The focused suite has 50 tests covering command matching, ambiguous prefixes,
page/disabled-state availability, native DevTools dispatch/policy, visibility
combinations and the existing keyword/badge behaviors. Actual native smoke-test
results are recorded separately after testing the signed build.
