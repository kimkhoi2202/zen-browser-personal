"""Shared, anchor-checked changes for released artifacts and full source builds."""
ADDONS_CSS_ARCHIVE='chrome/toolkit/content/mozapps/extensions/aboutaddons.css'
ADDONS_CSS_SOURCE='src/zen/common/styles/zen-addons-grid.css'
ADDONS_CSS_MARKER='/* Personal Zen: responsive extension list. */'


def patch_addons_styles(source, styles):
    if ADDONS_CSS_MARKER in source:
        raise RuntimeError('Add-ons stylesheet already patched; use a clean base')
    for anchor in ('#main > addon-list > section,', 'max-width: var(--page-main-content-width);'):
        if anchor not in source:
            raise RuntimeError('Upstream add-ons layout changed; review the patch')
    return source.rstrip()+'\n\n'+ADDONS_CSS_MARKER+'\n'+styles.rstrip()+'\n'


IMPORT='import { enterKeywordTabSearch, shouldHandleSearchTab } from "resource:///modules/zen/urlbar/PersonalSiteSearch.mjs";\n\n'
BRANCH='''        if (shouldHandleSearchTab(this.input, event)) {
          event.preventDefault();
          if (executeAction) {
            if (!this.input.value && !this.input.searchMode) {
              this.window.gZenUIManager.enableCommandsMode(event);
            } else {
              enterKeywordTabSearch(this.input, event).catch(console.error);
            }
          }
          break;
        }

'''

def patch_controller(source):
    if 'enterKeywordTabSearch' in source or 'getKeywordTabEngine' in source:
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
    source=source.replace(anchor, '''this._searchModeIndicatorTitle.textContent = getProviderLabel(
          engineName,
          this.controller.engineStore.getEngineByName(engineName)?.aliases
        );''')
    anchor='''          { name: engineName }
        );
      } else if (source) {'''
    if source.count(anchor)!=1:
        raise RuntimeError('Upstream search accessibility label changed; review the patch')
    return source.replace(anchor, '''          { name: getProviderLabel(
              engineName,
              this.controller.engineStore.getEngineByName(engineName)?.aliases
            ) }
        );
      } else if (source) {''')
