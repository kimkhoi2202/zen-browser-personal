/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import { UrlbarProvider } from "moz-src:///browser/components/urlbar/UrlbarUtils.sys.mjs";
import {
  getSearchTemplate,
  searchTermFromURL,
  recentSearchTerms,
} from "resource:///modules/zen/urlbar/PersonalSiteSearch.mjs";

const lazy = {};
ChromeUtils.defineESModuleGetters(lazy, {
  PlacesUtils: "resource://gre/modules/PlacesUtils.sys.mjs",
  FormHistory: "resource://gre/modules/FormHistory.sys.mjs",
  DEFAULT_FORM_HISTORY_PARAM:
    "moz-src:///toolkit/components/search/SearchSuggestionController.sys.mjs",
  UrlbarResult: "chrome://browser/content/urlbar/UrlbarResult.mjs",
  UrlbarShared: "chrome://browser/content/urlbar/UrlbarShared.mjs",
  UrlbarSearchUtils:
    "moz-src:///browser/components/urlbar/UrlbarSearchUtils.sys.mjs",
});

/** Local-only recent searches, including imported search URLs. No timers. */
export class PersonalSiteSearchHistory extends UrlbarProvider {
  get type() {
    return lazy.UrlbarShared.PROVIDER_TYPE.PROFILE;
  }
  get name() {
    return "PersonalSiteSearchHistory";
  }
  async isActive(context) {
    return (
      !!context.searchMode?.engineName &&
      !context.isPrivate &&
      Services.prefs.getBoolPref("browser.urlbar.suggest.history", true) &&
      Services.prefs.getBoolPref("browser.formfill.enable", true)
    );
  }
  getPriority(context) {
    return context.searchString ? 0 : 1;
  }

  async startQuery(context, addCallback) {
    const instance = this.queryInstance;
    const engine = lazy.UrlbarSearchUtils.getEngineByName(
      context.searchMode.engineName,
    );
    if (!engine) return;
    const entries = await lazy.FormHistory.search(["value", "lastUsed"], {
      fieldname: lazy.DEFAULT_FORM_HISTORY_PARAM,
      source: engine.name,
    });
    const submission = engine.getSubmission(
      "zen_search_terms_marker",
      null,
      "keyword",
    );
    const template =
      !submission?.postData && getSearchTemplate(submission?.uri.spec);
    if (template) {
      const db = await lazy.PlacesUtils.promiseDBConnection();
      const rows = await db.executeCached(
        `
        SELECT url, last_visit_date FROM moz_places
        WHERE url >= :prefix AND url < :end AND last_visit_date IS NOT NULL
        ORDER BY last_visit_date DESC LIMIT 100`,
        { prefix: template.prefix, end: template.prefix + "\uffff" },
      );
      for (const row of rows) {
        const value = searchTermFromURL(row.getResultByName("url"), template);
        if (value)
          entries.push({
            value,
            lastUsed: row.getResultByName("last_visit_date"),
          });
      }
    }
    if (instance !== this.queryInstance) return;
    for (const term of recentSearchTerms(entries, context.searchString)) {
      addCallback(
        this,
        new lazy.UrlbarResult({
          type: lazy.UrlbarShared.RESULT_TYPE.SEARCH,
          source: lazy.UrlbarShared.RESULT_SOURCE.HISTORY,
          payload: {
            engine: engine.name,
            suggestion: term,
            title: term,
            icon: "chrome://global/skin/icons/search-glass.svg",
          },
        }),
      );
    }
  }
}
