/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

// Alternate names reuse the existing action, result row, and keyboard shortcut.
export const ARC_ACTION_ALIASES = {
  "zen-action-reload-tab": ["Refresh the Page", "Refresh Page", "Reload Page"],
  "zen-action-reload-tab-without-cache": [
    "Force Refresh the Page",
    "Force Refresh",
    "Hard Reload",
  ],
  "zen-action-reopen-closed-tab": ["Restore Last Closed Tab", "Reopen Tab"],
  "zen-action-duplicate-tab": ["Duplicate Tab"],
  "zen-action-copy-current-url": ["Copy URL", "Copy Link"],
  "zen-action-new-split-view": ["Add Split View", "Split View"],
  "zen-action-unsplit-view": ["Close Split View", "Expand Current Split"],
  "zen-action-open-private-window": [
    "New Incognito Window",
    "New Private Window",
  ],
  "zen-action-open-new-window": ["New Window"],
  "zen-action-new-blank-window": ["Blank Window"],
  "zen-action-capture-screenshot": ["Capture", "Capture Page", "Screenshot"],
  "zen-action-settings": ["Preferences", "Open Settings"],
  "zen-action-find-in-page": ["Find on Page"],
};

export function actionSearchTerms(action) {
  return [
    action.extraPayload?.prettyName || action.label,
    ...(action.aliases || []),
  ].filter(Boolean);
}

export function isExactActionQuery(action, query) {
  const normalize = text => text.trim().replace(/\s+/gu, " ").toLowerCase();
  return (
    !!query.trim() &&
    actionSearchTerms(action).some(term => normalize(term) === normalize(query))
  );
}

// A complete command, or a prefix identifying just one command, can be the
// default result. Ambiguous words such as "zoom" retain the normal search row.
export function preferredActionForQuery(actions, query) {
  const exact = actions.filter(action => isExactActionQuery(action, query));
  if (exact.length) {
    return exact.length === 1 ? exact[0] : null;
  }
  const prefix = query.trim().replace(/\s+/gu, " ").toLowerCase();
  if (prefix.length < 3) {
    return null;
  }
  const matches = actions.filter(action =>
    actionSearchTerms(action).some(term =>
      term.toLowerCase().startsWith(prefix)
    )
  );
  return matches.length === 1 ? matches[0] : null;
}

function hasPage(window) {
  return (
    !!window.gBrowser?.selectedTab &&
    !window.gBrowser.selectedTab.hasAttribute("zen-empty-tab")
  );
}

function nativeAction(name, command, icon, aliases = [], requiresPage = true) {
  return {
    l10nId: `zen-action-personal-${name}`,
    command,
    aliases,
    icon: `chrome://browser/skin/zen-icons/${icon}.svg`,
    isAvailable(window) {
      const element = window.document.getElementById(command);
      return (
        !!element &&
        element.getAttribute("disabled") !== "true" &&
        (!requiresPage || hasPage(window))
      );
    },
  };
}

// Use Zen's native compact-mode methods, preserving the other chrome area's
// actual visibility. In particular, showing the toolbar must not show a hidden sidebar.
function setChromeVisible(window, services, part, visible) {
  const manager = window.gZenCompactModeManager;
  const otherHidden =
    manager.preference &&
    (part === "toolbar" ? manager.canHideSidebar : manager.canHideToolbar);
  if (part === "toolbar") {
    services.prefs.setBoolPref("zen.view.sidebar-expanded", true);
    services.prefs.setBoolPref("zen.view.use-single-toolbar", false);
  }
  if (!visible && otherHidden) {
    manager.hideBoth();
  } else if (!visible) {
    manager[part === "toolbar" ? "hideToolbar" : "hideSidebar"]();
  } else if (otherHidden) {
    manager[part === "toolbar" ? "hideSidebar" : "hideToolbar"]();
  }
  manager.preference = !visible || otherHidden;
}

export function personalCommandActions(services) {
  const actions = [
    nativeAction("zoom-in", "cmd_fullZoomEnlarge", "search-page"),
    nativeAction("zoom-out", "cmd_fullZoomReduce", "search-page"),
    nativeAction("actual-size", "cmd_fullZoomReset", "search-page", [
      "Actual Size",
      "Reset Zoom",
      "Zoom Reset",
      "Zoom 100%",
    ]),
    nativeAction("copy-markdown", "cmd_zenCopyCurrentURLMarkdown", "link", [
      "Copy URL as Markdown",
    ]),
    nativeAction("save-page", "Browser:SavePage", "downloads", ["Save Page"]),
    nativeAction("view-source", "View:PageSource", "selectable/code", [
      "Page Source",
    ]),
    nativeAction(
      "downloads",
      "Tools:Downloads",
      "downloads",
      ["Downloads"],
      false
    ),
    nativeAction(
      "history",
      "Browser:ShowAllHistory",
      "history",
      ["History"],
      false
    ),
    nativeAction(
      "fullscreen",
      "View:FullScreen",
      "arrows-expand",
      ["Enter Full Screen", "Exit Full Screen", "Fullscreen"],
      false
    ),
    nativeAction("reader", "View:ReaderView", "search-page", [
      "Reader Mode",
      "Reader View",
    ]),
    {
      l10nId: "zen-action-personal-clear-cache",
      aliases: ["Clear Cache", "Empty Cache and Refresh"],
      icon: "chrome://browser/skin/zen-icons/reload.svg",
      isAvailable: hasPage,
      command(window) {
        // Network cache only. Never remove cookies, storage, passwords or history.
        services.cache2.clear();
        window.BrowserCommands.reloadSkipCache();
      },
    },
    {
      l10nId: "zen-action-personal-sidebar-urlbar",
      aliases: ["Use Sidebar Address Bar", "Single Toolbar"],
      icon: "chrome://browser/skin/zen-icons/sidebar.svg",
      isAvailable: () =>
        !services.prefs.getBoolPref("zen.view.use-single-toolbar"),
      command() {
        services.prefs.setBoolPref("zen.view.sidebar-expanded", true);
        services.prefs.setBoolPref("zen.view.use-single-toolbar", true);
      },
    },
  ];
  for (const [name, toolId, aliases] of [
    ["developer-tools", null, ["DevTools"]],
    ["inspector", "inspector", ["Inspect Element", "Inspector"]],
    ["console", "webconsole", ["JavaScript Console", "Web Console"]],
    ["network", "netmonitor", ["Network Monitor"]],
  ]) {
    actions.push({
      l10nId: `zen-action-personal-${name}`,
      aliases,
      icon: "chrome://browser/skin/zen-icons/selectable/code.svg",
      isAvailable: window =>
        hasPage(window) &&
        !services.prefs.getBoolPref("devtools.policy.disabled", false),
      command(window) {
        const { DevToolsShim } = ChromeUtils.importESModule(
          "chrome://devtools-startup/content/DevToolsShim.sys.mjs"
        );
        DevToolsShim.showToolboxForTab(
          window.gBrowser.selectedTab,
          toolId ? { toolId } : {}
        );
      },
    });
  }
  for (const part of ["toolbar", "sidebar"]) {
    for (const visible of [true, false]) {
      actions.push({
        l10nId: `zen-action-personal-${visible ? "show" : "hide"}-${part}`,
        aliases:
          part === "toolbar" && visible
            ? ["Use Top Toolbar", "Top Address Bar", "Multiple Toolbars"]
            : [],
        icon: "chrome://browser/skin/zen-icons/sidebar.svg",
        isAvailable(window) {
          const manager = window.gZenCompactModeManager;
          if (!manager?.shouldBeCompact) {
            return false;
          }
          const single = services.prefs.getBoolPref(
            "zen.view.use-single-toolbar"
          );
          if (part === "toolbar" && single) {
            return visible;
          }
          const hidden =
            manager.preference &&
            (part === "toolbar"
              ? manager.canHideToolbar
              : manager.canHideSidebar);
          return visible === hidden;
        },
        command: window => setChromeVisible(window, services, part, visible),
      });
    }
  }
  return actions;
}
