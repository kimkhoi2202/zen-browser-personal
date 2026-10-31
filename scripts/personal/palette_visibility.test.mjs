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
  choose(firstResult, queryContext) {
      if (firstResult.heuristic) {
        // Select the heuristic result.
        return this.#shouldShowHeuristic(firstResult);
      }
      return false;
  }
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
  assert.equal(view.choose({source:7},{searchMode:{source:7}}),true);
  assert.equal(view.choose({source:3},{searchMode:{source:3}}),false);
});
const managerFixture=`class Manager {
  add(provider, result) {
    if (
      result.heuristic &&
      this.context.searchMode &&
      (!this.context.trimmedSearchString ||
        (!this.context.searchMode.engineName && !result.autofill))
    ) return false;
    return true;
  }
}`;
const managerPatch=execFileSync('python3',['-c','import sys; from ui_patch import patch_providers_manager; print(patch_providers_manager(sys.stdin.read()))'],
  {cwd:fileURLToPath(new URL('.',import.meta.url)),input:managerFixture,encoding:'utf8'});
const Manager=new Function(managerPatch+';return Manager;')();
test('empty-query filtering retains only the matching engine recent-search heuristic',()=>{
  const manager=new Manager();manager.context={searchMode:{engineName:'YouTube'},trimmedSearchString:''};
  const result={heuristic:true,payload:{engine:'YouTube'}};
  assert.equal(manager.add({name:'PersonalSiteSearchHistory'},result),true);
  assert.equal(manager.add({name:'PersonalSiteSearchHistory'},{...result,payload:{engine:'Google'}}),false);
  assert.equal(manager.add({name:'UrlbarProviderHeuristicFallback'},result),false);
});
