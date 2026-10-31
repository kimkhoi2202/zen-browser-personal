"""Shared, anchor-checked changes for released artifacts and full source builds."""
ADDONS_CSS_ARCHIVE='chrome/toolkit/content/mozapps/extensions/aboutaddons.css'
ADDONS_CSS_SOURCE='src/zen/common/styles/zen-addons-grid.css'
ADDONS_CSS_MARKER='/* Personal Zen: responsive extension list. */'
CONTENT_AREA_CSS_ARCHIVE='chrome/browser/skin/classic/browser/tabbrowser/content-area.css'


def patch_findbar_position(source):
    # Give native Find a separate auto-sized row. Zen's Zap bar still uses the
    # existing bottom findbar area; notifications and DevTools keep their slots.
    prefix='    "devtools-side-start      devtools-side-start-splitter '
    suffix=' devtools-side-end-splitter  devtools-side-end"'
    browser=prefix+'browserstack            '+suffix+'\n'
    top=prefix+'personal-findbar         '+suffix+'\n'
    tracks='    /* browserstack, we want to take all the available height */\n'
    item='''  & > findbar {
    grid-area: findbar;
  }'''
    if 'personal-findbar' in source or any(source.count(x)!=1 for x in (browser,tracks,item)):
        raise RuntimeError('Upstream findbar layout changed or already patched; use a clean base')
    return (source.replace(browser,top+browser)
            .replace(tracks,'    /* Native Find above the page; the shared bottom slot stays intact. */\n    auto\n'+tracks)
            .replace(item,item.replace('grid-area: findbar;','grid-area: personal-findbar;')))


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
    source = source.replace(anchor, '''          { name: getProviderLabel(
              engineName,
              this.controller.engineStore.getEngineByName(engineName)?.aliases
            ) }
        );
      } else if (source) {''')
    anchor = '    this.toggleAttribute("searchmode", true);'
    if source.count(anchor) != 1:
        raise RuntimeError('Upstream search mode state changed; review the patch')
    return source.replace(anchor, '''    this.document.l10n.setAttributes(
      this.inputField, "personal-command-palette-search"
    );
''' + anchor)


def patch_view(source):
    anchor = '''  #shouldShowHeuristic(result) {
'''
    if source.count(anchor) != 1 or 'PersonalSiteSearchHistory' in source:
        raise RuntimeError('Upstream result visibility changed or already patched; use a clean base')
    return source.replace(anchor, anchor + '''    // Recent engine searches and explicit browser commands are selectable
    // actions, not the redundant web-search heuristic hidden by Zen.
    if (result?.heuristic && (
      result.providerName === "PersonalSiteSearchHistory" ||
      result.source === UrlbarShared.RESULT_SOURCE.ZEN_ACTIONS
    )) {
      return true;
    }
''')


def patch_providers_manager(source):
    anchor = '''      result.heuristic &&
      this.context.searchMode &&
'''
    if source.count(anchor) != 1 or 'PersonalSiteSearchHistory' in source:
        raise RuntimeError('Upstream empty-search filtering changed or already patched; use a clean base')
    return source.replace(anchor, anchor + '''      !(provider.name === "PersonalSiteSearchHistory" &&
        this.context.searchMode.engineName === result.payload.engine) &&
''')
