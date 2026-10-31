import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const fixture=`class View {
  #shouldShowHeuristic(result) {
    if (!result?.heuristic) throw new Error('heuristic required');
    return !UrlbarPrefs.get('experimental.hideHeuristic') || result.type === UrlbarShared.RESULT_TYPE.TIP;
  }
  show(result) { return this.#shouldShowHeuristic(result); }
}`;
const patched=execFileSync('python3',['-c','import sys; from ui_patch import patch_view; print(patch_view(sys.stdin.read()))'],
  {cwd:fileURLToPath(new URL('.',import.meta.url)),input:fixture,encoding:'utf8'});
const View=new Function('UrlbarPrefs','UrlbarShared',patched+'; return View;')(
  {get:()=>true},{RESULT_TYPE:{TIP:5},RESULT_SOURCE:{ZEN_ACTIONS:7}});
test('hide heuristic still hides ordinary web search but keeps recent search and Actions selectable',()=>{
  const view=new View();
  assert.equal(view.show({heuristic:true,providerName:'UrlbarProviderHeuristicFallback'}),false);
  assert.equal(view.show({heuristic:true,providerName:'PersonalSiteSearchHistory'}),true);
  assert.equal(view.show({heuristic:true,source:7}),true);
  assert.equal(view.show({heuristic:true,type:5}),true);
});
