import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import {
  personalCommandActions,
  actionSearchTerms,
  isExactActionQuery,
  preferredActionForQuery,
  ARC_ACTION_ALIASES,
} from "../../src/zen/urlbar/PersonalCommandActions.mjs";

function fixture({
  compact = false,
  toolbar = false,
  sidebar = true,
  single = false,
  empty = false,
} = {}) {
  const prefs = new Map([
    ["zen.view.use-single-toolbar", single],
    ["zen.view.compact.hide-toolbar", toolbar],
    ["zen.view.compact.hide-tabbar", sidebar],
  ]);
  const calls = [];
  const services = {
    prefs: {
      getBoolPref: (name, fallback) => prefs.get(name) ?? fallback,
      setBoolPref: (name, value) => prefs.set(name, value),
    },
    cache2: { clear: () => calls.push("clear-network-cache") },
  };
  const manager = {
    preference: compact,
    shouldBeCompact: true,
    get canHideToolbar() {
      return prefs.get("zen.view.compact.hide-toolbar");
    },
    get canHideSidebar() {
      return (
        prefs.get("zen.view.compact.hide-tabbar") ||
        prefs.get("zen.view.use-single-toolbar")
      );
    },
    hideBoth() {
      prefs.set("zen.view.compact.hide-tabbar", true);
      prefs.set("zen.view.compact.hide-toolbar", true);
    },
    hideToolbar() {
      prefs.set("zen.view.compact.hide-tabbar", false);
      prefs.set("zen.view.compact.hide-toolbar", true);
    },
    hideSidebar() {
      prefs.set("zen.view.compact.hide-tabbar", true);
      prefs.set("zen.view.compact.hide-toolbar", false);
    },
  };
  const window = {
    gZenCompactModeManager: manager,
    gBrowser: { selectedTab: { hasAttribute: () => empty } },
    document: { getElementById: () => ({ getAttribute: () => null }) },
    BrowserCommands: {
      reloadSkipCache: () => calls.push("reload-without-cache"),
    },
  };
  const actions = personalCommandActions(services);
  return {
    prefs,
    services,
    calls,
    window,
    manager,
    actions,
    action: suffix =>
      actions.find(a => a.l10nId === "zen-action-personal-" + suffix),
  };
}

test("Arc aliases match the same action without becoming ordinary-query matches", () => {
  const action = {
    label: "Reload Tab",
    aliases: ARC_ACTION_ALIASES["zen-action-reload-tab"],
  };
  assert.ok(isExactActionQuery(action, "  REFRESH   THE PAGE "));
  for (const query of [
    "",
    " ",
    "refresh",
    "how to refresh the page",
    "Refresh the Page on YouTube",
  ]) {
    assert.equal(isExactActionQuery(action, query), false, query);
  }
  assert.ok(actionSearchTerms(action).includes("Refresh the Page"));
});

test("matching respects a workspace/extension pretty name", () => {
  const action = { label: "Focus on", extraPayload: { prettyName: "School" } };
  assert.deepEqual(actionSearchTerms(action), ["School"]);
  assert.equal(isExactActionQuery(action, "focus on"), false);
});

test("only a unique literal command prefix becomes the default result", () => {
  const zoom = [
    { label: "Zoom In" },
    { label: "Zoom Out" },
    { label: "Zoom to Actual Size" },
  ];
  assert.equal(preferredActionForQuery(zoom, "zoom"), null);
  assert.equal(preferredActionForQuery(zoom, "zoom to"), zoom[2]);
  assert.equal(preferredActionForQuery(zoom, "Zoom In"), zoom[0]);
  assert.equal(preferredActionForQuery(zoom, "how to zoom in"), null);
  assert.equal(preferredActionForQuery(zoom, "zo"), null);
  assert.equal(
    preferredActionForQuery([{ label: "Open" }, { label: "Open" }], "Open"),
    null
  );
});

test("page commands require a real selected page and an enabled native command", () => {
  const f = fixture();
  assert.equal(f.action("zoom-in").isAvailable(f.window), true);
  f.window.document.getElementById = () => null;
  assert.equal(f.action("zoom-in").isAvailable(f.window), false);
  f.window.document.getElementById = () => ({ getAttribute: () => "true" });
  assert.equal(f.action("zoom-out").isAvailable(f.window), false);
  const empty = fixture({ empty: true });
  assert.equal(empty.action("actual-size").isAvailable(empty.window), false);
  assert.equal(empty.action("downloads").isAvailable(empty.window), true);
  assert.equal(empty.action("clear-cache").isAvailable(empty.window), false);
});

test("clear cache uses the native network cache service before bypass-cache reload", () => {
  const f = fixture();
  f.action("clear-cache").command(f.window);
  assert.deepEqual(f.calls, ["clear-network-cache", "reload-without-cache"]);
});

for (const part of ["toolbar", "sidebar"]) {
  const other = part === "toolbar" ? "Sidebar" : "Toolbar";
  test(`show ${part} preserves a hidden ${other.toLowerCase()}`, () => {
    const f = fixture({ compact: true, toolbar: true, sidebar: true });
    f.action(`show-${part}`).command(f.window);
    assert.equal(f.manager.preference, true);
    assert.equal(f.manager[`canHide${other}`], true);
    assert.equal(
      f.manager[part === "toolbar" ? "canHideToolbar" : "canHideSidebar"],
      false
    );
  });
  test(`show ${part} exits compact mode when nothing else is hidden`, () => {
    const f = fixture({
      compact: true,
      toolbar: part === "toolbar",
      sidebar: part === "sidebar",
    });
    f.action(`show-${part}`).command(f.window);
    assert.equal(f.manager.preference, false);
  });
  test(`hide ${part} preserves a visible ${other.toLowerCase()}`, () => {
    const f = fixture();
    f.action(`hide-${part}`).command(f.window);
    assert.equal(f.manager.preference, true);
    assert.equal(f.manager[`canHide${other}`], false);
  });
}

test("show toolbar switches to Zen's top layout, and sidebar layout stays reversible", () => {
  const f = fixture({ single: true });
  assert.equal(f.action("show-toolbar").isAvailable(f.window), true);
  assert.equal(f.action("hide-toolbar").isAvailable(f.window), false);
  f.action("show-toolbar").command(f.window);
  assert.equal(f.prefs.get("zen.view.use-single-toolbar"), false);
  assert.equal(f.prefs.get("zen.view.sidebar-expanded"), true);
  f.action("sidebar-urlbar").command(f.window);
  assert.equal(f.prefs.get("zen.view.use-single-toolbar"), true);
});

test("developer commands respect native policy and dispatch through DevToolsShim", () => {
  const f = fixture();
  f.prefs.set("devtools.policy.disabled", true);
  assert.equal(f.action("inspector").isAvailable(f.window), false);
  f.prefs.set("devtools.policy.disabled", false);
  const original = globalThis.ChromeUtils;
  let called;
  globalThis.ChromeUtils = {
    importESModule: path => {
      assert.equal(
        path,
        "chrome://devtools-startup/content/DevToolsShim.sys.mjs"
      );
      return {
        DevToolsShim: {
          showToolboxForTab: (tab, options) => {
            called = { tab, options };
          },
        },
      };
    },
  };
  try {
    f.action("inspector").command(f.window);
    assert.equal(called.tab, f.window.gBrowser.selectedTab);
    assert.deepEqual(called.options, { toolId: "inspector" });
  } finally {
    globalThis.ChromeUtils = original;
  }
});

test("all added actions have a localized label, unique identity and existing native icon", async () => {
  const f = fixture();
  const l10n = await readFile(
    new URL(
      "../../locales/en-US/browser/browser/zen-command-palette.ftl",
      import.meta.url
    ),
    "utf8"
  );
  assert.equal(new Set(f.actions.map(a => a.l10nId)).size, f.actions.length);
  // The on-disk icons are checked directly; packaging/native verification checks their URLs.
  for (const a of f.actions) {
    assert.ok(l10n.includes(a.l10nId + " = "), a.l10nId);
    const icon = a.icon.replace("chrome://browser/skin/zen-icons/", "");
    const directory = icon.startsWith("selectable/") ? "common/" : "nucleo/";
    await readFile(
      new URL(
        "../../src/browser/themes/shared/zen-icons/" + directory + icon,
        import.meta.url
      )
    );
  }
});
