import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';

// Exercise the real startup method without starting Gecko or touching a profile.
const source = fs.readFileSync(new URL('../../src/zen/spaces/ZenSpaceManager.mjs', import.meta.url), 'utf8');
const start = source.indexOf('  async selectStartPage() {');
const end = source.indexOf('\n  #hasSelectedStartPage', start);
assert.ok(start > 0 && end > start);
const method = source.slice(start, end)
  .replace('async selectStartPage()', 'async function selectStartPage()')
  .replaceAll('this.#hasSelectedStartPage', 'this.testHasSelectedStartPage')
  .replaceAll('this.#shouldShowTabInCurrentWorkspace', 'this.testShouldShowTab');

async function restore(startupURI, { continueSession = false } = {}) {
  const timers = [], removed = [], routed = [], events = [];
  let palettes = 0;
  function tab(empty = false) {
    return { hasAttribute: name => empty && name === 'zen-empty-tab',
      linkedBrowser: { focus() {} }, _markedForReplacement: true };
  }
  const initial = tab(), saved = tab(), empty = tab(true);
  const browser = {
    tabs: [initial, saved], selectedTab: initial,
    get selectedBrowser() { return this.selectedTab.linkedBrowser; },
    moveTabTo() {},
    removeTab(value) {
      removed.push(value);
      if (this.selectedTab === value) this.selectedTab = empty;
    },
  };
  const context = {
    delayedStartupPromise: Promise.resolve(),
    gBrowserInit: { uriToLoadPromise: Promise.resolve(startupURI) },
    gBrowser: browser,
    isInitialPage: uri => ['about:blank', 'about:newtab', 'about:home'].includes(uri),
    gZenUIManager: { testingEnabled: false },
    gZenSpaceRoutingManager: { async routeStartupTab(value) { routed.push(value); } },
    gZenGlanceManager: { getTabOrGlanceParent: value => value },
    gZenVerticalTabsManager: { _canReplaceNewTab: true },
    Services: { prefs: { getBoolPref: name => name === 'zen.urlbar.open-on-startup' || continueSession } },
    window: { docShell: {}, addEventListener() {}, dispatchEvent: value => events.push(value) },
    document: { documentElement: { hasAttribute: () => false } },
    BrowserCommands: { openTab() { palettes++; } },
    openLocation() { palettes++; },
    setTimeout(callback) { timers.push(callback); return timers.length; },
    clearTimeout() {},
    CustomEvent: class { constructor(type) { this.type = type; } },
  };
  const manager = {
    workspaceEnabled: true, activeWorkspace: 'home',
    _tabToRemoveForEmpty: initial, _emptyTab: empty, _sessionSelected: 2,
    testShouldShowTab: async () => true,
    selectEmptyTab() { browser.selectedTab = empty; },
    moveTabToWorkspace() {}, log() {},
  };
  const select = Function(...Object.keys(context), `return (${method});`)(...Object.values(context));
  await select.call(manager);
  timers.forEach(callback => callback());
  return { initial, saved, empty, selected: browser.selectedTab, removed, routed, palettes, events, manager, select };
}

for (const [name, uri] of [
  ['single external URL', ['https://example.com/one']],
  ['several external URLs', ['https://example.com/one', 'https://example.com/two']],
  ['single string URL', 'https://example.com/one'],
  ['multiple homepage string', 'https://example.com/one|https://example.com/two'],
]) {
  test(`${name} remains selected after workspace restore`, async () => {
    const result = await restore(uri);
    assert.equal(result.selected, result.initial, 'startup must select the requested page');
    assert.ok(!result.removed.includes(result.initial), 'startup must not remove the requested page');
    assert.equal(result.initial._markedForReplacement, undefined);
    assert.deepEqual(result.routed, [result.initial]);
    assert.equal(result.palettes, 0, 'the empty palette must not cover the requested page');
  });
}

test('external URL takes priority over the previous session selection', async () => {
  const result = await restore(['https://example.com/one'], { continueSession: true });
  assert.equal(result.selected, result.initial);
});

for (const uri of [null, '', [], ['about:blank'], 'about:newtab']) {
  test(`ordinary empty startup ${JSON.stringify(uri)} retains the new-tab view`, async () => {
    const result = await restore(uri);
    assert.equal(result.selected, result.empty);
    assert.equal(result.palettes, 1);
    assert.deepEqual(result.routed, []);
  });
}

test('ordinary launch can still continue the saved session', async () => {
  const result = await restore(null, { continueSession: true });
  assert.equal(result.selected, result.saved);
  assert.equal(result.palettes, 0);
});
