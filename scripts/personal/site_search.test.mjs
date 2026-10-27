import test from 'node:test';
import assert from 'node:assert/strict';
import {getKeywordTabEngine,enterKeywordTabSearch,shouldHandleSearchTab,getProviderLabel,getProviderTheme,applyProviderBadge,PROVIDER_THEMES} from '../../src/zen/urlbar/PersonalSiteSearch.mjs';

const yt={name:'YouTube',aliases:['y','youtube.com']};
const maps={name:'Google Maps',aliases:['maps']};
function fixture(patch={}) {
  const input={sapName:'urlbar',searchMode:null,userTypedValue:'y',value:'youtube.com/',
    controller:{engineStore:{initialized:true,getEngines:()=>[yt,maps]}},...patch};
  return {input,view:{selectedRowIndex:0},event:{key:'Tab'}};
}
test('exact keyword wins over an autocompleted URL',()=>{const t=fixture();assert.equal(getKeywordTabEngine(t.input,t.event),yt);});
for(const value of ['Y','youtube.com','maps']) {
  test('configured alias '+value,()=>{const t=fixture({userTypedValue:value});assert.equal(getKeywordTabEngine(t.input,t.event),value=='maps'?maps:yt);});
}
for(const value of ['', ' ', ' y', 'y ', 'y guitar','unknown','https://youtube.com']) {
  test('ordinary input '+JSON.stringify(value)+' does not select an engine',()=>{const t=fixture({userTypedValue:value});assert.equal(getKeywordTabEngine(t.input,t.event),null);});
}
for(const modifier of ['shiftKey','ctrlKey','altKey','metaKey','isComposing']) {
  test(modifier+' retains native behavior',()=>{const t=fixture();t.event[modifier]=true;assert.equal(getKeywordTabEngine(t.input,t.event),null);});
}
for(const key of ['ArrowUp','ArrowDown','Enter',' ']) {
  test(key+' is not remapped',()=>{const t=fixture();t.event.key=key;assert.equal(getKeywordTabEngine(t.input,t.event),null);});
}
test('typed alias still enters site search after arrow navigation',()=>{const t=fixture();t.view.selectedRowIndex=2;assert.equal(getKeywordTabEngine(t.input,t.event),yt);});
test('other inputs are untouched',()=>{const t=fixture({sapName:'smartbar'});assert.equal(getKeywordTabEngine(t.input,t.event),null);});
test('existing search mode is untouched',()=>{const t=fixture({searchMode:{engineName:'Google'}});assert.equal(getKeywordTabEngine(t.input,t.event),null);});
test('loading engine store falls through safely',()=>{const t=fixture();t.input.controller.engineStore.initialized=false;assert.equal(getKeywordTabEngine(t.input,t.event),null);});
test('ambiguous aliases never choose an arbitrary engine',()=>{const t=fixture();t.input.controller.engineStore.getEngines=()=>[yt,{aliases:['y']}];assert.equal(getKeywordTabEngine(t.input,t.event),null);});
for(const [name,provider] of [['YouTube (y)','youtube'],['Google Maps (maps)','maps'],['Google Drive (drive)','drive'],['Crunchyroll (crunch)','crunchyroll'],['Chordify (chord)','chordify'],['X (x)','x'],['Instagram (insta)','instagram']]) {
  test('theme '+name,()=>assert.equal(getProviderTheme(name).provider,provider));
}
test('unknown themes preserve user style',()=>assert.equal(getProviderTheme('Unconfigured Provider'),null));
test('leaving site search clears prior color',()=>{
  const attrs=new Map(),styles=new Map();
  const input={setAttribute:(k,v)=>attrs.set(k,v),removeAttribute:k=>attrs.delete(k),
    style:{setProperty:(k,v)=>styles.set(k,v),removeProperty:k=>styles.delete(k)}};
  applyProviderBadge(input,{engineName:'YouTube'});assert.equal(attrs.get('data-personal-search-provider'),'youtube');
  applyProviderBadge(input,{engineName:'Google Maps'});assert.equal(attrs.get('data-personal-search-provider'),'maps');
  applyProviderBadge(input,null);assert.equal(attrs.size,0);assert.equal(styles.size,0);
});
test('all badge colors meet 4.5:1 contrast against white',()=>{
  for(const [name,,hex] of PROVIDER_THEMES) {
    const rgb=hex.slice(1).match(/../g).map(x=>parseInt(x,16)/255).map(x=>x<=0.04045?x/12.92:((x+0.055)/1.055)**2.4);
    const luminance=rgb[0]*0.2126+rgb[1]*0.7152+rgb[2]*0.0722;
    assert.ok(1.05/(luminance+0.05)>=4.5,name);
  }
});
test('channels have separate app, remoting and profile identities',async()=>{
  const {readFile}=await import('node:fs/promises');
  const config=JSON.parse(await readFile(new URL('../../personal/channels.json',import.meta.url)));
  for(const field of ['appName','bundleId','profileDirectory','remotingName'])assert.notEqual(config.channels.dev[field],config.channels.production[field]);
});

for (const patch of [{userTypedValue:'guitar'}, {userTypedValue:'',value:''}, {searchMode:{engineName:'YouTube'}}]) {
  test('bare Tab stays in the address bar '+JSON.stringify(patch),()=>{
    const t=fixture(patch);assert.equal(shouldHandleSearchTab(t.input,t.event),true);
  });
}
for (const key of ['ArrowUp','ArrowDown','Enter',' ']) {
  test('native navigation is untouched for '+key,()=>{const t=fixture();t.event.key=key;assert.equal(shouldHandleSearchTab(t.input,t.event),false);});
}
for (const modifier of ['shiftKey','ctrlKey','altKey','metaKey','isComposing']) {
  test('Tab interception preserves '+modifier,()=>{const t=fixture();t.event[modifier]=true;assert.equal(shouldHandleSearchTab(t.input,t.event),false);});
}
test('search Tab does not intercept other browser inputs',()=>{
  const t=fixture({sapName:'smartbar'});assert.equal(shouldHandleSearchTab(t.input,t.event),false);
});
for (const [name,aliases,label] of [
  ['Chordify (chordify)',['chordify','chord'],'Chordify'],
  ['Chordify (CHORD)',['chord'],'Chordify'],
  ['YouTube (y)',['y'],'YouTube'],
  ['Dictionary (English)',['dict'],'Dictionary (English)'],
  ['Chordify', ['chordify'],'Chordify'],
  ['Research (archive)', [], 'Research (archive)'],
]) {
  test('provider label '+name,()=>assert.equal(getProviderLabel(name,aliases),label));
}

test('first Tab waits for engine startup and activates once ready',async()=>{
  const t=fixture({focused:true});let complete;let calls=0;
  t.input.controller.engineStore.initialized=false;
  t.input.controller.engineStore.init=()=>new Promise(resolve=>{complete=resolve;});
  t.input.search=()=>{calls++;};
  const activation=enterKeywordTabSearch(t.input,t.event);
  assert.equal(calls,0);t.input.controller.engineStore.initialized=true;complete();
  assert.equal(await activation,true);assert.equal(calls,1);
});
for (const change of ['typing','blur','mode']) {
  test('deferred Tab never overwrites '+change,async()=>{
    const t=fixture({focused:true});let complete;let calls=0;
    t.input.controller.engineStore.initialized=false;
    t.input.controller.engineStore.init=()=>new Promise(resolve=>{complete=resolve;});
    t.input.search=()=>{calls++;};
    const activation=enterKeywordTabSearch(t.input,t.event);
    if(change=='typing')t.input.userTypedValue='new query';
    if(change=='blur')t.input.focused=false;
    if(change=='mode')t.input.searchMode={engineName:'Google Maps'};
    t.input.controller.engineStore.initialized=true;complete();
    assert.equal(await activation,false);assert.equal(calls,0);
  });
}
test('failed engine startup leaves typed text intact',async()=>{
  const t=fixture({focused:true});t.input.controller.engineStore.initialized=false;
  t.input.controller.engineStore.init=()=>Promise.reject(new Error('synthetic startup failure'));
  assert.equal(await enterKeywordTabSearch(t.input,t.event),false);
  assert.equal(t.input.userTypedValue,'y');
});
