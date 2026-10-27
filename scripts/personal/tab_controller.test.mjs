import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {getKeywordTabEngine,shouldHandleSearchTab} from '../../src/zen/urlbar/PersonalSiteSearch.mjs';

const scripts=fileURLToPath(new URL('.',import.meta.url));
const nativeFixture=`export class UrlbarChildController {
  handle(event, executeAction=true) {
    switch(event.keyCode) {
      case KeyEvent.DOM_VK_TAB: {
        this.view.selectedRowIndex++;
        break;
      }
      case KeyEvent.DOM_VK_DOWN:
        this.view.selectedRowIndex++;
        break;
      case KeyEvent.DOM_VK_UP:
        this.view.selectedRowIndex--;
        break;
    }
  }
}`;
const patched=execFileSync('python3',['-c',
  'import sys; from ui_patch import patch_controller; print(patch_controller(sys.stdin.read()))'],
  {cwd:scripts,input:nativeFixture,encoding:'utf8'});
const Controller=new Function('getKeywordTabEngine','shouldHandleSearchTab','KeyEvent',
  patched.replace(/^import .*;\n/m,'').replace('export class','class')+'\nreturn UrlbarChildController;')(
    getKeywordTabEngine,shouldHandleSearchTab,{DOM_VK_TAB:9,DOM_VK_UP:38,DOM_VK_DOWN:40});

function fixture(text='guitar') {
  const c=new Controller(), searches=[];
  c.view={selectedRowIndex:0};
  c.input={sapName:'urlbar',value:text,userTypedValue:text,searchMode:null,
    controller:{engineStore:{initialized:true,getEngines:()=>[{name:'YouTube',aliases:['y']}] }},
    search:(...args)=>searches.push(args)};
  let commands=0;
  c.window={gZenUIManager:{enableCommandsMode:()=>commands++}};
  const key=(key,keyCode,executeAction=true)=>{
    let prevented=false;
    c.handle({key,keyCode,preventDefault:()=>{prevented=true;}},executeAction);
    return prevented;
  };
  return {c,key,searches,commands:()=>commands};
}

test('injected Tab keeps the highlighted suggestion; arrows alone move it',()=>{
  const {c,key}=fixture();
  key('ArrowDown',40);assert.equal(c.view.selectedRowIndex,1);
  key('ArrowDown',40);assert.equal(c.view.selectedRowIndex,2);
  assert.equal(key('Tab',9),true);assert.equal(c.view.selectedRowIndex,2);
  key('ArrowUp',38);assert.equal(c.view.selectedRowIndex,1);
  c.input.searchMode={engineName:'YouTube'};
  key('Tab',9);assert.equal(c.view.selectedRowIndex,1);
});
test('injected Tab enters the typed alias after arrow navigation without picking a result',()=>{
  const {c,key,searches}=fixture('y');
  key('ArrowDown',40);key('Tab',9);
  assert.equal(c.view.selectedRowIndex,1);
  assert.equal(searches.length,1);
  assert.equal(searches[0][1].searchEngine.name,'YouTube');
  assert.equal(searches[0][0],'');
});
test('deferred Tab does not navigate or execute twice, and empty Tab retains commands',()=>{
  const {c,key,searches}=fixture('y');
  key('Tab',9,false);assert.equal(searches.length,0);assert.equal(c.view.selectedRowIndex,0);
  key('Tab',9,true);assert.equal(searches.length,1);
  const empty=fixture('');empty.key('Tab',9);assert.equal(empty.commands(),1);
});
