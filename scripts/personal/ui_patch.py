"""Shared, anchor-checked changes for released artifacts and full source builds."""
IMPORT='import { getKeywordTabEngine, shouldHandleSearchTab } from "resource:///modules/zen/urlbar/PersonalSiteSearch.mjs";\n\n'
BRANCH='''        if (shouldHandleSearchTab(this.input, event)) {
          event.preventDefault();
          if (executeAction) {
            const keywordEngine = getKeywordTabEngine(this.input, event);
            if (keywordEngine) {
              this.input.search("", {
                searchEngine: keywordEngine,
                searchModeEntry: "typed",
              });
            } else if (!this.input.value && !this.input.searchMode) {
              this.window.gZenUIManager.enableCommandsMode(event);
            }
          }
          break;
        }

'''

def patch_controller(source):
    if 'getKeywordTabEngine' in source:
        raise RuntimeError('Controller already contains the personal patch; use a clean base')
    anchor='export class UrlbarChildController {'
    if source.count(anchor)!=1:
        raise RuntimeError('Upstream controller class changed; review the patch')
    source=source.replace(anchor,IMPORT+anchor)
    anchor='      case KeyEvent.DOM_VK_TAB: {\n'
    if source.count(anchor)!=1:
        raise RuntimeError('Upstream Tab handler changed; review the patch')
    return source.replace(anchor,anchor+BRANCH)


def patch_input(source):
    if 'getProviderLabel' in source:
        raise RuntimeError('Input already contains the personal patch; use a clean base')
    anchor='export class UrlbarInputBase extends HTMLElement {'
    if source.count(anchor)!=1:
        raise RuntimeError('Upstream input class changed; review the patch')
    source=source.replace(anchor, 'import { getProviderLabel } from "resource:///modules/zen/urlbar/PersonalSiteSearch.mjs";\n\n'+anchor)
    anchor='this._searchModeIndicatorTitle.textContent = engineName;'
    if source.count(anchor)!=1:
        raise RuntimeError('Upstream search badge changed; review the patch')
    return source.replace(anchor, '''this._searchModeIndicatorTitle.textContent = getProviderLabel(
          engineName,
          this.controller.engineStore.getEngineByName(engineName)?.aliases
        );''')
