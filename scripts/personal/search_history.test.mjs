import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import {
  getSearchTemplate,
  searchTermFromURL,
  recentSearchTerms,
} from "../../src/zen/urlbar/PersonalSiteSearch.mjs";

const template = getSearchTemplate(
  "https://www.youtube.com/results?search_query=zen_search_terms_marker",
);
test("search URLs decode Unicode and space-separated terms, never another host or path", () => {
  assert.equal(
    searchTermFromURL(
      "https://www.youtube.com/results?search_query=guitar+ch%E1%BB%9D",
      template,
    ),
    "guitar chờ",
  );
  for (const url of [
    "https://evil.test/results?search_query=foo",
    "https://www.youtube.com/watch?search_query=foo",
    "not a url",
  ])
    assert.equal(searchTermFromURL(url, template), null);
});
test("engines without a GET query parameter do not parse unrelated visits", () => {
  for (const url of [
    "https://x.com/search?q=fixed",
    "https://example.org/zen_search_terms_marker",
    "file:///tmp/search?q=zen_search_terms_marker",
  ])
    assert.equal(getSearchTemplate(url), null);
});
test("recent searches are sorted, deduplicated and filtered before the five-result limit", () => {
  const rows = [
    { value: "Guitar", lastUsed: 10 },
    { value: "guitar", lastUsed: 20 },
    { value: "guitar chords", lastUsed: 30 },
    { value: "maps", lastUsed: 40 },
    ...Array.from({ length: 8 }, (_, i) => ({
      value: `guitar ${i}`,
      lastUsed: 50 + i,
    })),
  ];
  assert.deepEqual(recentSearchTerms(rows, "GuiTAr"), [
    "guitar 7",
    "guitar 6",
    "guitar 5",
    "guitar 4",
    "guitar 3",
  ]);
  assert.deepEqual(recentSearchTerms(rows, "chords"), ["guitar chords"]);
});

// Exercise the actual provider with native services replaced by small test doubles.
const source = await readFile(
  new URL(
    "../../src/zen/urlbar/PersonalSiteSearchHistory.sys.mjs",
    import.meta.url,
  ),
  "utf8",
);
function providerFixture({
  isPrivate = false,
  enabled = true,
  delayed = false,
} = {}) {
  let finish;
  const lazy = {
    UrlbarShared: {
      PROVIDER_TYPE: { PROFILE: 1 },
      RESULT_TYPE: { SEARCH: 2 },
      RESULT_SOURCE: { HISTORY: 3 },
    },
    UrlbarSearchUtils: {
      getEngineByName: () => ({ name: "YouTube", getSubmission: () => null }),
    },
    FormHistory: {
      search: () =>
        delayed
          ? new Promise((r) => {
              finish = r;
            })
          : Promise.resolve([{ value: "guitar", lastUsed: 4 }]),
    },
    UrlbarResult: class {
      constructor(value) {
        Object.assign(this, value);
      }
    },
  };
  const Provider = new Function(
    "UrlbarProvider",
    "ChromeUtils",
    "Services",
    "getSearchTemplate",
    "searchTermFromURL",
    "recentSearchTerms",
    source
      .replace(/^import[\s\S]*?;\n/gm, "")
      .replace("const lazy = {};", "const lazy = ChromeUtils.lazy;")
      .replace("export class", "class") + "\nreturn PersonalSiteSearchHistory;",
  )(
    class {},
    { lazy, defineESModuleGetters() {} },
    { prefs: { getBoolPref: () => enabled } },
    getSearchTemplate,
    searchTermFromURL,
    recentSearchTerms,
  );
  const provider = new Provider();
  provider.queryInstance = 1;
  return {
    provider,
    context: {
      searchMode: { engineName: "YouTube" },
      isPrivate,
      searchString: "",
    },
    finish: () => finish([{ value: "old", lastUsed: 1 }]),
  };
}
test("history provider uses the native async activation contract and excludes private/disabled history", async () => {
  for (const patch of [{ isPrivate: true }, { enabled: false }]) {
    const t = providerFixture(patch);
    const activation = t.provider.isActive(t.context);
    assert.equal(typeof activation.then, "function");
    assert.equal(await activation, false);
  }
  const t = providerFixture();
  assert.equal(await t.provider.isActive({ ...t.context, searchMode: null }), false);
});
test("empty engine mode produces a native search result; typing leaves remote providers eligible", async () => {
  const t = providerFixture(),
    results = [];
  await t.provider.startQuery(t.context, (_, result) => results.push(result));
  assert.equal(results[0].payload.engine, "YouTube");
  assert.equal(results[0].payload.suggestion, "guitar");
  assert.equal(t.provider.getPriority({ ...t.context, searchString: "g" }), 0);
});
test("a cancelled query never inserts stale recent searches", async () => {
  const t = providerFixture({ delayed: true }),
    results = [];
  const query = t.provider.startQuery(t.context, (_, result) =>
    results.push(result),
  );
  t.provider.queryInstance++;
  t.finish();
  await query;
  assert.equal(results.length, 0);
});
