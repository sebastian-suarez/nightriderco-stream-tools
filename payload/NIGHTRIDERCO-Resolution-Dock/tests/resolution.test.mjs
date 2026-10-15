import test from 'node:test';
import assert from 'node:assert/strict';
import {ResolutionEngine,resizeTransform,fullFrame,writableTransform} from '../engine.mjs';
const t = {positionX:100,positionY:80,scaleX:1,scaleY:1,sourceWidth:2560,sourceHeight:1440,rotation:0,alignment:5,boundsType:'OBS_BOUNDS_NONE',boundsAlignment:0,boundsWidth:0,boundsHeight:0,cropLeft:0,cropRight:0,cropTop:0,cropBottom:0};
function mock(){
 const state={video:{baseWidth:2560,baseHeight:1440,outputWidth:1920,outputHeight:1080},active:false,context:{collection:'Test',profile:'Main'},
  inputs:[{name:'Browser',kind:'browser_source',uuid:'b',size:{width:2560,height:1440}},{name:'Chat',kind:'browser_source',uuid:'ch',size:{width:680,height:923}}],
  containers:[{name:'Group',group:true,items:[{sceneItemId:1,sourceName:'Camera',sourceUuid:'cam',sceneItemTransform:{...t,positionX:8,positionY:8,sourceWidth:1920,sourceHeight:1080,scaleX:.3,scaleY:.3}}]},
  {name:'Overlay',group:false,items:[{sceneItemId:2,sourceName:'Browser',sourceUuid:'b',sceneItemTransform:{...t}}]},
  {name:'Main',group:false,items:[{sceneItemId:3,sourceName:'Overlay',sourceUuid:'ov',sceneItemTransform:{...t}},{sceneItemId:4,sourceName:'Group',sourceUuid:'gr',isGroup:true,sceneItemTransform:{...t,sourceWidth:600,sourceHeight:350}},{sceneItemId:5,sourceName:'Display',sourceUuid:'d',sceneItemTransform:{...t,sourceWidth:5120,sourceHeight:2880,scaleX:.5,scaleY:.5}},{sceneItemId:6,sourceName:'Chat',sourceUuid:'ch',sceneItemTransform:{...t,sourceWidth:680,sourceHeight:923,scaleX:.7,scaleY:.7}}]}],
  parameters:[{parameterCategory:'AdvOut',parameterName:'RescaleRes',parameterValue:'1920x1080'}]};
 const writes=[];let stored=null,failType=null;
 const obs={async call(type,data={}){
  if(type.startsWith('Set')){writes.push({type,data});if(failType===type){failType=null;throw Error('Injected failure');}}
  if(type==='GetVideoSettings')return structuredClone(state.video);
  if(type==='GetSceneCollectionList')return {currentSceneCollectionName:state.context.collection};
  if(type==='GetProfileList')return {currentProfileName:state.context.profile};
  if(['GetStreamStatus','GetRecordStatus','GetReplayBufferStatus','GetVirtualCamStatus'].includes(type))return {outputActive:state.active};
  if(type==='GetOutputList')return {outputs:[]};
  if(type==='GetInputList')return {inputs:state.inputs.map(i=>({inputName:i.name,inputUuid:i.uuid,inputKind:i.kind,unversionedInputKind:i.kind}))};
  if(type==='GetInputSettings')return {inputSettings:structuredClone(state.inputs.find(i=>i.name===data.inputName).size)};
  if(type==='GetSceneList')return {scenes:state.containers.filter(c=>!c.group).map(c=>({sceneName:c.name}))};
  if(type==='GetGroupList')return {groups:state.containers.filter(c=>c.group).map(c=>c.name)};
  if(type==='GetProfileParameter')return {parameterValue:state.parameters.find(p=>p.parameterName===data.parameterName)?.parameterValue??null};
  if(type==='GetSceneItemList'||type==='GetGroupSceneItemList')return {sceneItems:structuredClone(state.containers.find(c=>c.name===data.sceneName).items)};
  if(type==='GetSceneItemTransform')return {sceneItemTransform:structuredClone(state.containers.find(c=>c.name===data.sceneName).items.find(i=>i.sceneItemId===data.sceneItemId).sceneItemTransform)};
  if(type==='SetVideoSettings'){
   Object.assign(state.video,data);
   for(const c of state.containers)for(const i of c.items)if(i.sourceName==='Overlay')Object.assign(i.sceneItemTransform,{sourceWidth:data.baseWidth,sourceHeight:data.baseHeight});return{};
  }
  if(type==='SetInputSettings'){
   Object.assign(state.inputs.find(i=>i.name===data.inputName).size,data.inputSettings);
   for(const c of state.containers)for(const i of c.items)if(i.sourceName===data.inputName)Object.assign(i.sceneItemTransform,{sourceWidth:data.inputSettings.width,sourceHeight:data.inputSettings.height});return{};
  }
  if(type==='SetProfileParameter'){Object.assign(state.parameters.find(p=>p.parameterName===data.parameterName),data);return{};}
  if(type==='SetPersistentData')return{};
  if(type==='SetSceneItemTransform'){Object.assign(state.containers.find(c=>c.name===data.sceneName).items.find(i=>i.sceneItemId===data.sceneItemId).sceneItemTransform,data.sceneItemTransform);return{};}
  throw Error('Unexpected '+type);
 }};
 const store={read:async()=>structuredClone(stored),write:async v=>{stored=structuredClone(v)},clear:async()=>{stored=null}};
 return {engine:new ResolutionEngine(obs,store),state,writes,store,fail:type=>{failType=type}};
}
test('native captures scale; resized browsers and nested scenes avoid double scaling',()=>{
 assert.equal(resizeTransform(t,t,.75).scaleX,.75);
 assert.equal(resizeTransform(t,{...t,sourceWidth:1920,sourceHeight:1080},.75).scaleX,1);
 const crop=resizeTransform({...t,cropLeft:100},{...t,sourceWidth:1920,sourceHeight:1080},.75);assert.equal(crop.cropLeft,75);
});
test('fullscreen detection leaves chat widget viewport intact',()=>{
 assert(fullFrame({kind:'browser_source',size:{width:2560,height:1440}}));
 assert(!fullFrame({kind:'browser_source',size:{width:680,height:923}}));
});
test('FHD then 2K preserves groups, native captures, chat and nested scenes',async()=>{
 const m=mock();await m.engine.switch('fhd');
 const main=m.state.containers.find(c=>c.name==='Main').items;
 assert.equal(main[0].sceneItemTransform.scaleX,1);
 assert.equal(main[1].sceneItemTransform.scaleX,.75);
 assert.equal(main[2].sceneItemTransform.scaleX,.375);
 assert(Math.abs(main[3].sceneItemTransform.scaleX-.525)<1e-10);
 assert.equal(m.state.containers[0].items[0].sceneItemTransform.positionX,8);
 assert.deepEqual(m.state.inputs[1].size,{width:680,height:923});
 await m.engine.switch('qhd');assert.equal(main[1].sceneItemTransform.scaleX,1);
 assert.equal(main[2].sceneItemTransform.scaleX,.5);
});
test('active outputs refuse every mutation',async()=>{
 const m=mock();m.state.active=true;await assert.rejects(m.engine.switch('fhd'),/Stop/);assert.equal(m.writes.length,0);
});
test('a partial failure restores the exact starting video, browser and transforms',async()=>{
 const m=mock(),before=structuredClone(m.state);m.fail('SetSceneItemTransform');await assert.rejects(m.engine.switch('fhd'),/Injected failure/);
 assert.deepEqual(m.state,before);assert.equal((await m.store.read()).phase,'rolled-back');
});
test('undo restores a mixed canvas/output setup',async()=>{
 const m=mock(),before=structuredClone(m.state);await m.engine.switch('fhd');await m.engine.undo();assert.deepEqual(m.state,before);assert.equal(await m.store.read(),null);
});
test('recovery refuses a different collection before mutating anything',async()=>{
 const m=mock();await m.engine.switch('fhd');m.state.context.collection='Other';m.writes.length=0;await assert.rejects(m.engine.undo(),/collection changed/);
 assert.equal(m.writes.filter(w=>w.type!=='SetPersistentData').length,0);
});

test('OBS setters receive no zero or fractional unused bounds',()=>{
 const output=writableTransform({...t,boundsWidth:0,boundsHeight:.75});
 assert.equal(output.boundsWidth,undefined);assert.equal(output.boundsHeight,undefined);
});
test('disabled optional outputs are handled without hiding connection failures',async()=>{
 const m=mock(),call=m.engine.obs.call;
 m.engine.obs.call=async(type,data)=>{if(type==='GetReplayBufferStatus')throw Object.assign(Error('not available'),{obsCode:604});return call(type,data)};
 assert.deepEqual(await m.engine.outputs(),[]);
 m.engine.obs.call=async()=>{throw Error('connection lost')};await assert.rejects(m.engine.outputs(),/connection lost/);
});
