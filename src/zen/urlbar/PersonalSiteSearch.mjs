/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

export function shouldHandleSearchTab(input, event) {
  return input.sapName == "urlbar" && event.key == "Tab" &&
    !event.shiftKey && !event.ctrlKey && !event.altKey && !event.metaKey &&
    !event.isComposing;
}

/** A typed alias wins even after navigating suggestions with the arrow keys. */
export function getKeywordTabEngine(input, event) {
  if (!shouldHandleSearchTab(input, event) || input.searchMode ||
      !input.controller.engineStore.initialized) {
    return null;
  }
  const keyword = input.userTypedValue ?? input.value ?? "";
  if (!/^\S+$/u.test(keyword)) {
    return null;
  }
  const matches = input.controller.engineStore.getEngines().filter(engine =>
    engine.aliases?.some(alias => alias.toLowerCase() == keyword.toLowerCase())
  );
  return matches.length == 1 ? matches[0] : null;
}

export function getProviderLabel(engineName, aliases = []) {
  const suffix = engineName?.match(/^(.*?)\s+\(([^()]+)\)$/u);
  return suffix && aliases.some(alias => alias.toLowerCase() == suffix[2].toLowerCase())
    ? suffix[1].trimEnd()
    : engineName;
}

export const PROVIDER_THEMES = [
  ["youtube", /youtube/i, "#a91b1b"],
  ["maps", /google maps/i, "#176b3a"],
  ["drive", /google drive/i, "#164da1"],
  ["crunchyroll", /crunchyroll/i, "#9c3b00"],
  ["chordify", /chordify/i, "#08714f"],
  ["instagram", /instagram/i, "#8b2459"],
  ["x", /^(x|twitter)(?:\s|$|\.)/i, "#252525"],
  ["gmail", /gmail/i, "#a22127"],
  ["calendar", /google calendar/i, "#185abc"],
  ["docs", /google docs/i, "#185abc"],
  ["dropbox", /dropbox/i, "#1257a0"],
  ["amazon", /amazon/i, "#654000"],
  ["github", /github/i, "#30363d"],
  ["figma", /figma/i, "#7336a4"],
  ["wikipedia", /wikipedia/i, "#3c4148"],
  ["reddit", /reddit/i, "#a43800"],
  ["soundcloud", /soundcloud/i, "#9e3f00"],
  ["asana", /asana/i, "#9c2a50"],
  ["linkedin", /linkedin/i, "#0a66c2"],
  ["apple-music", /apple music/i, "#9c2245"],
  ["spotify", /spotify/i, "#176b3a"],
];

export function getProviderTheme(engineName) {
  const found = PROVIDER_THEMES.find(([, pattern]) => pattern.test(engineName || ""));
  return found ? { provider: found[0], background: found[2], foreground: "#ffffff" } : null;
}

export function applyProviderBadge(input, searchMode) {
  const theme = getProviderTheme(searchMode?.engineName);
  if (!theme) {
    input.removeAttribute("data-personal-search-provider");
    input.style.removeProperty("--personal-search-background");
    input.style.removeProperty("--personal-search-foreground");
    return;
  }
  input.setAttribute("data-personal-search-provider", theme.provider);
  input.style.setProperty("--personal-search-background", theme.background);
  input.style.setProperty("--personal-search-foreground", theme.foreground);
}

export function installProviderBadgeStyles(document) {
  if (document.getElementById("personal-search-badge-styles")) {
    return;
  }
  const style = document.createElementNS("http://www.w3.org/1999/xhtml", "style");
  style.id = "personal-search-badge-styles";
  style.textContent = `
    #urlbar[data-personal-search-provider] #urlbar-search-mode-indicator {
      background: var(--personal-search-background) !important;
      color: var(--personal-search-foreground) !important;
      border-radius: 999px !important;
      border: 1px solid color-mix(in srgb, white 20%, transparent) !important;
      padding-inline: 10px !important;
    }
    #urlbar[data-personal-search-provider] #urlbar-search-mode-indicator-title {
      color: inherit !important;
      font-weight: 600;
    }
  `;
  document.documentElement.appendChild(style);
}
