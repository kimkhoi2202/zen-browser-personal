import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import {
  destinationActions,
  actionSearchTerms,
  preferredActionForQuery,
} from "../../src/zen/urlbar/PersonalCommandActions.mjs";

const labelFor = id => ({
  "zen-action-personal-move-to": "Move to",
  "zen-action-personal-pin-to": "Pin to",
  "zen-action-focus-on": "Focus on",
}[id]);

function fixture() {
  const calls = [];
  const attributes = new Map([["zen-workspace-id", "home"]]);
  const tab = {
    pinned: false, isConnected: true, group: null,
    hasAttribute: key => attributes.has(key),
    getAttribute: key => attributes.get(key),
  };
  const spaces = [
    { uuid: "home", name: "Home", icon: "🏡" },
    { uuid: "school", name: "Stanford", icon: "🌲" },
  ];
  const window = {
    gBrowser: {
      selectedTab: tab, tabGroups: [],
      pinTab(item) { calls.push(["pin", item]); item.pinned = true; },
      ungroupTab(item) { calls.push(["ungroup", item]); item.group = item.group.group; },
      selectedBrowser: { focus() {} },
    },
    gZenWorkspaces: {
      activeWorkspace: "home", privateWindowOrDisabled: false,
      lastSelectedWorkspaceTabs: {},
      getWorkspaces: () => spaces,
      workspaceElement: () => ({ style: { getPropertyValue: () => "green" } }),
      moveTabToWorkspace(item, id) { calls.push(["move", item, id]); attributes.set("zen-workspace-id", id); },
      async changeWorkspaceWithID(id) { calls.push(["follow", id]); },
    },
    gZenKeyboardShortcutsManager: { getShortcutDisplayFromCommand: () => "" },
  };
  function folder(id, label, space = "school", parent = null) {
    const group = {
      id, label, isZenFolder: true, isLiveFolder: false,
      isConnected: true, collapsed: true, group: parent,
      hasAttribute: () => false,
      getAttribute: () => space,
      addTabs(items) { calls.push(["folder", id, ...items]); },
    };
    window.gBrowser.tabGroups.push(group);
    return group;
  }
  return { window, tab, attributes, spaces, calls, folder,
    actions: () => destinationActions(window, labelFor) };
}

test("Move to targets Spaces with their names, icons and native move operation", async () => {
  const f = fixture();
  const action = f.actions().find(a => a.commandId === "zen:move-to-space-school");
  assert.equal(action.extraPayload.prettyName, "Stanford");
  assert.ok(actionSearchTerms(action).includes("Move to Stanford"));
  f.tab.pinned = true;
  await action.command(f.window);
  assert.deepEqual(f.calls, [["move", f.tab, "school"], ["follow", "school"]]);
  assert.equal(f.tab.pinned, true, "Move preserves pinning, like Zen's context menu");
  assert.equal(f.window.gZenWorkspaces.lastSelectedWorkspaceTabs.school, f.tab);
});

test("Pin to Space pins and moves the current tab; Pin to current Space leaves nested folders", async () => {
  const f = fixture();
  const outer = f.folder("outer", "Courses", "home");
  f.tab.group = f.folder("inner", "Fall", "home", outer);
  const action = f.actions().find(a => a.commandId === "zen:pin-to-space-home");
  f.tab.pinned = true;
  await action.command(f.window);
  assert.deepEqual(f.calls.map(c => c[0]), ["ungroup", "ungroup", "pin", "move", "follow"]);
  assert.equal(f.tab.group, null);
});

test("folder rows distinguish nested paths and move into the existing folder", async () => {
  const f = fixture();
  const parent = f.folder("courses", "Courses");
  const folder = f.folder("fall", "Fall", "school", parent);
  const action = f.actions().find(a => a.commandId === "zen:pin-to-folder-fall");
  assert.equal(action.extraPayload.prettyName, "Stanford / Courses / Fall");
  assert.ok(actionSearchTerms(action).includes("Move to Courses / Fall"));
  assert.equal(preferredActionForQuery(f.actions(), "Pin to Stanford / Courses / Fall").commandId, action.commandId);
  await action.command(f.window);
  assert.deepEqual(f.calls.map(c => c[0]), ["pin", "move", "folder", "follow"]);
  assert.equal(folder.collapsed, false);
});

test("ambiguous folder names never choose an arbitrary destination", () => {
  const f = fixture();
  f.folder("one", "Courses", "home");
  f.folder("two", "Courses", "school");
  assert.equal(preferredActionForQuery(f.actions(), "Pin to Courses"), null);
  assert.equal(preferredActionForQuery(f.actions(), "Pin to Home / Courses").commandId, "zen:pin-to-folder-one");
});

test("private, empty, Essential and closing tabs cannot be moved through stale rows", async () => {
  for (const key of ["zen-empty-tab", "zen-essential", "private", "closing"]) {
    const f = fixture();
    const action = f.actions()[0];
    if (key === "private") f.window.gZenWorkspaces.privateWindowOrDisabled = true;
    else if (key === "closing") f.tab.closing = true;
    else f.attributes.set(key, "true");
    assert.deepEqual(f.actions(), []);
    await action.command(f.window);
    assert.deepEqual(f.calls, []);
  }
});

test("changing selection or removing the destination invalidates a captured row", async () => {
  for (const change of ["selection", "space", "disconnected", "owner"]) {
    const f = fixture();
    const action = f.actions().find(a => a.commandId === "zen:move-to-space-school");
    if (change === "selection") f.window.gBrowser.selectedTab = {};
    if (change === "space") f.spaces.pop();
    if (change === "disconnected") f.tab.isConnected = false;
    await action.command(change === "owner" ? {} : f.window);
    assert.deepEqual(f.calls, [], change);
  }
});

test("live, deleted, moved and current folders are excluded or invalidated", async () => {
  for (const change of ["live", "deleted", "moved", "disconnected", "current"]) {
    const f = fixture();
    const folder = f.folder("test", "Courses");
    const action = f.actions().find(a => a.commandId === "zen:pin-to-folder-test");
    if (change === "live") folder.isLiveFolder = true;
    if (change === "deleted") f.window.gBrowser.tabGroups = [];
    if (change === "moved") folder.getAttribute = () => "other-space";
    if (change === "disconnected") folder.isConnected = false;
    if (change === "current") f.tab.group = folder;
    assert.ok(!f.actions().some(a => a.commandId === action.commandId), change);
    if (change !== "current") {
      await action.command(f.window);
      assert.deepEqual(f.calls, [], change);
    }
  }
});

test("split tabs only expose native whole-split Space moves, never individual pinning", () => {
  const f = fixture();
  f.tab.group = { hasAttribute: name => name === "split-view-group" };
  f.folder("folder", "Courses");
  assert.deepEqual(f.actions().map(a => a.commandId), ["zen:move-to-space-school"]);
});

async function providerFixture() {
  const f = fixture();
  f.folder("courses", "Stanford Courses");
  const constants = { ZEN_ACTIONS: 10, WORKSPACES: 11 };
  const learner = {
    shouldPrioritize: () => true,
    getDeprioritizeIndex: () => 1,
    // Deliberately put a fuzzy match first, as existing learned history can do.
    sortCommandsByPriority: results => results.reverse(),
  };
  const shared = {
    RESULT_SOURCE: constants, RESULT_TYPE: { DYNAMIC: 1 },
    PROVIDER_TYPE: { HEURISTIC: 1 }, MAX_TEXT_LENGTH: 1000,
    getTokenMatches: () => [],
  };
  const dependencies = {
    BrowserWindowTracker: { getTopWindow: () => f.window },
    AddonManager: { getAddonsByTypes: async () => [] },
    UrlUtils: { REGEXP_LIKE_PROTOCOL: /^https?:/ },
    UrlbarResult: class { constructor(data) { Object.assign(this, data); } },
  };
  const source = (await readFile(new URL("../../src/zen/urlbar/ZenUBActionsProvider.sys.mjs", import.meta.url), "utf8"))
    .replace(/^import[\s\S]*?from "[^"]+";\n/gm, "")
    .replace("export class ZenUrlbarProviderGlobalActions", "class ZenUrlbarProviderGlobalActions");
  const context = vm.createContext({
    console, UrlbarProvider: class {}, UrlbarShared: shared,
    globalActions: [], labelFor, destinationActions, actionSearchTerms,
    preferredActionForQuery, zenUrlbarResultsLearner: learner,
    XPCOMUtils: { defineLazyPreferenceGetter: (target, key, pref, fallback) => { target[key] = fallback; } },
    ChromeUtils: { defineESModuleGetters: (target, getters) => {
      for (const key of Object.keys(getters)) target[key] = dependencies[key];
    } },
  });
  const Provider = vm.runInContext(source + "\nZenUrlbarProviderGlobalActions;", context);
  const provider = new Provider();
  return { ...f, provider, constants,
    query: (text, source = constants.ZEN_ACTIONS) => ({
      searchString: text, trimmedLowerCaseSearchString: text.toLowerCase(),
      searchMode: source === null ? null : { source },
    }) };
}

test("actual provider returns only action results in Actions mode and prioritizes the exact destination over history", async () => {
  const f = await providerFixture();
  const results = [];
  const query = f.query("Move to Stanford");
  assert.equal(await f.provider.isActive(query), true);
  await f.provider.startQuery(query, (provider, result) => results.push(result));
  assert.equal(results[0].commandId, "zen:move-to-space-school");
  assert.equal(results[0].heuristic, true);
  assert.ok(results.every(r => r.source === f.constants.ZEN_ACTIONS));
  assert.equal(results[0].payload.prettyName, "Stanford");
  f.provider.onEngagement(query, null, {
    result: results[0], element: { documentGlobal: f.window },
  });
  await new Promise(setImmediate);
  assert.deepEqual(f.calls.map(c => c[0]), ["move", "follow"]);
});

test("site search stays scoped; workspace-only mode stays focus-only", async () => {
  const f = await providerFixture();
  assert.equal(await f.provider.isActive(f.query("Move to Stanford", 99)), false);
  const results = [];
  await f.provider.startQuery(f.query("Stanford", f.constants.WORKSPACES),
    (provider, result) => results.push(result));
  assert.deepEqual(results.map(r => r.commandId), ["zen:workspace-school"]);
});
