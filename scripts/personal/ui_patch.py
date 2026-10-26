"""Shared, anchor-checked changes for released artifacts and full source builds."""
IMPORT='import { getKeywordTabEngine } from "resource:///modules/zen/urlbar/PersonalSiteSearch.mjs";\n\n'
BRANCH='''        const keywordEngine = getKeywordTabEngine(this.input, this.view, event);
        if (keywordEngine) {
          event.preventDefault();
          if (executeAction) {
            this.input.search("", {
              searchEngine: keywordEngine,
              searchModeEntry: "typed",
            });
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
