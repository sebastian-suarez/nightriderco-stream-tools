const {test}=require('node:test');
const assert=require('node:assert/strict');
const {Switcher,inspect}=require('../../../payload/SecureDocks/shared/camera-core.js');
function mock({group=false,camera=false,buddy=true,missing=false,duplicate=false}={}){
 const items=[{sourceName:group?'NRC Camera · Workshop':'Webcam',sceneItemId:10,sceneItemEnabled:camera,isGroup:group},...missing?[]:[{sourceName:'[HTML] Typing buddy',sceneItemId:11,sceneItemEnabled:buddy}]];
 if(duplicate)items.push({...items[0],sceneItemId:12});
 return {items,writes:[],calls:[],live:'Workshop',children:[{sourceName:'Webcam',sceneItemId:4,sceneItemEnabled:true}],
 async call(type,data){this.calls.push(type);if(type==='GetSceneItemList')return {sceneItems:structuredClone(items)};if(type==='GetGroupSceneItemList')return {sceneItems:this.children};if(type==='GetCurrentProgramScene')return {currentProgramSceneName:this.live};throw Error(type);},
 async batch(requests){for(const r of requests){this.writes.push(r);if(this.failAt===this.writes.length)throw Error('incomplete');items.find(i=>i.sceneItemId===r.requestData.sceneItemId).sceneItemEnabled=r.requestData.sceneItemEnabled;}}
 };
}
test('Camera group switches with its frame; child visibility and layout are untouched',async()=>{
 const obs=mock({group:true});const s=new Switcher(obs);const result=await s.choose('camera','Workshop');
 assert.equal(result.current,'camera');assert.deepEqual(obs.writes.map(r=>[r.requestData.sceneItemId,r.requestData.sceneItemEnabled]),[[11,false],[10,true]]);
 assert(obs.writes.every(r=>r.requestType==='SetSceneItemEnabled'&&r.requestData.sceneName==='Workshop'));assert.equal(obs.children[0].sceneItemEnabled,true);
});
test('Direct webcam switches in both directions and repeated selection is idempotent',async()=>{
 const obs=mock();const s=new Switcher(obs);await s.choose('camera','Workshop');await s.choose('buddy','Workshop');const count=obs.writes.length;await s.choose('buddy','Workshop');assert.equal(obs.writes.length,count);assert.equal((await inspect(obs,'Workshop')).current,'buddy');
});
test('Missing and duplicate targets block every mutation',async()=>{
 for(const options of [{missing:true},{duplicate:true}]){const obs=mock(options);await assert.rejects(new Switcher(obs).choose('camera','Workshop'));assert.equal(obs.writes.length,0);}
});
test('Both/neither visibility are observed and choosing a source resolves them',async()=>{
 for(const visible of [true,false]){const obs=mock({camera:visible,buddy:visible});assert.equal((await inspect(obs,'Workshop')).current,visible?'both':'neither');assert.equal((await new Switcher(obs).choose('buddy','Workshop')).current,'buddy');}
});
test('A hidden Webcam child blocks switching a misleading visible camera group',async()=>{
 const obs=mock({group:true});obs.children[0].sceneItemEnabled=false;await assert.rejects(new Switcher(obs).choose('camera','Workshop'),/inside/);assert.equal(obs.writes.length,0);
});
test('A change of program scene aborts a follow-active click before writes',async()=>{
 const obs=mock();obs.live='Gameplay';await assert.rejects(new Switcher(obs).choose('camera','Workshop',{follow:true}),/active scene changed/);assert.equal(obs.writes.length,0);
});
test('Partial failure never shows the incoming camera or claims success',async()=>{
 const obs=mock();obs.failAt=2;const s=new Switcher(obs);await assert.rejects(s.choose('camera','Workshop'),/incomplete/);assert.equal(s.busy,false);assert.equal((await inspect(obs,'Workshop')).current,'neither');
});
test('Concurrent clicks are rejected while an existing switch is pending',async()=>{
 const obs=mock();const original=obs.batch.bind(obs);let release;obs.batch=async r=>{await new Promise(resolve=>release=resolve);await original(r);};const s=new Switcher(obs);const first=s.choose('camera','Workshop');await new Promise(r=>setImmediate(r));await assert.rejects(s.choose('buddy','Workshop'),/progress/);release();await first;
});
test('Reusable scene switches camera and frame together independently of program scene',async()=>{
 const obs=mock();obs.items.push({sourceName:'NRC Camera Frame · Workshop',sceneItemId:12,sceneItemEnabled:false});obs.live='Overlays';
 const s=new Switcher(obs);assert.equal((await s.choose('camera','Camera Switch')).current,'camera');
 assert.deepEqual(obs.writes.map(r=>[r.requestData.sceneItemId,r.requestData.sceneItemEnabled]),[[11,false],[10,true],[12,true]]);
 assert.equal((await s.choose('buddy','Camera Switch')).current,'buddy');assert.equal(obs.items.find(i=>i.sceneItemId===12).sceneItemEnabled,false);
 assert(obs.writes.every(r=>r.requestData.sceneName==='Camera Switch'));
});
test('Mixed webcam/frame visibility is detected and corrected by the selected source',async()=>{
 const obs=mock({camera:true,buddy:false});obs.items.push({sourceName:'NRC Camera Frame · Workshop',sceneItemId:12,sceneItemEnabled:false});
 assert.equal((await inspect(obs,'Camera Switch')).current,'mixed');assert.equal((await new Switcher(obs).choose('camera','Camera Switch')).current,'camera');
});
function drivingMock(current='buddy'){
 const obs=mock({camera:current==='camera',buddy:current==='buddy'});
 obs.items.push({sourceName:'[HTML] Driving buddy',sceneItemId:13,sceneItemEnabled:current==='driving'});
 obs.items.push({sourceName:'NRC Camera Frame · Workshop',sceneItemId:14,sceneItemEnabled:current==='camera'});
 return obs;
}
test('Every three-way transition leaves one choice visible and keeps the webcam frame in sync',async()=>{
 for(const from of ['camera','buddy','driving'])for(const to of ['camera','buddy','driving']){
  const obs=drivingMock(from);const after=await new Switcher(obs).choose(to,'Camera Switch');assert.equal(after.current,to);
  assert.equal(obs.items.find(i=>i.sceneItemId===10).sceneItemEnabled,to==='camera');
  assert.equal(obs.items.find(i=>i.sceneItemId===11).sceneItemEnabled,to==='buddy');
  assert.equal(obs.items.find(i=>i.sceneItemId===13).sceneItemEnabled,to==='driving');
  assert.equal(obs.items.find(i=>i.sceneItemId===14).sceneItemEnabled,to==='camera');
  const firstEnable=obs.writes.findIndex(r=>r.requestData.sceneItemEnabled);if(firstEnable>=0)assert(obs.writes.slice(firstEnable).every(r=>r.requestData.sceneItemEnabled));
  assert(obs.writes.every(r=>r.requestType==='SetSceneItemEnabled'&&r.requestData.sceneName==='Camera Switch'));
 }
});
test('Missing Driving buddy only blocks that option; old choices still work',async()=>{
 const obs=mock();await assert.rejects(new Switcher(obs).choose('driving','Camera Switch'),/Driving buddy/);assert.equal(obs.writes.length,0);assert.equal((await new Switcher(obs).choose('camera','Camera Switch')).current,'camera');
});
test('Multiple visible buddies are detected and resolved by any choice',async()=>{
 for(const mode of ['camera','buddy','driving']){const obs=drivingMock();for(const item of obs.items)item.sceneItemEnabled=true;assert.equal((await inspect(obs,'Camera Switch')).current,'both');assert.equal((await new Switcher(obs).choose(mode,'Camera Switch')).current,mode);}
});
test('Failed hiding the outgoing buddy prevents the incoming driving source from appearing',async()=>{
 const obs=drivingMock();obs.failAt=1;await assert.rejects(new Switcher(obs).choose('driving','Camera Switch'),/incomplete/);assert.equal(obs.items.find(i=>i.sceneItemId===13).sceneItemEnabled,false);
});
