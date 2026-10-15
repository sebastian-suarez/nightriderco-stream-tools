/* OBS WebSocket 5. Local-only; authentication is delegated to the existing Keychain helper. */
(function(root) {
'use strict';
const SCENE='Camera Switch';
const FRAME='NRC Camera Frame · Workshop';
class Socket {
  constructor({authenticate, onChange=()=>{}, WebSocketImpl=root.WebSocket}) {
    this.authenticate=authenticate; this.onChange=onChange; this.WebSocketImpl=WebSocketImpl;
    this.pending=new Map(); this.serial=0; this.connected=false;
  }
  async connect(port=4455) {
    this.close();
    const ws=this.ws=new this.WebSocketImpl(`ws://127.0.0.1:${port}`, 'obswebsocket.json');
    return new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>{reject(Error('OBS connection timed out.'));ws.close();},12000);
      ws.onmessage=async event=>{
        if(this.ws!==ws)return;
        try {
          const {op,d}=JSON.parse(event.data);
          if(op===0) {
            const identify={rpcVersion:1,eventSubscriptions:4|128};
            if(d.authentication) identify.authentication=await this.authenticate(port,d.authentication.salt,d.authentication.challenge);
            if(this.ws===ws && ws.readyState===1)ws.send(JSON.stringify({op:1,d:identify}));
          } else if(op===2) {clearTimeout(timer);this.connected=true;resolve();}
          else if(op===5)this.onChange(d);
          else if(op===7 || op===9) {
            const p=this.pending.get(d.requestId); if(!p)return;
            this.pending.delete(d.requestId);clearTimeout(p.timer);
            if(op===9) {
              if(!Array.isArray(d.results) || d.results.length!==p.count || d.results.some(r=>!r.requestStatus?.result)) p.reject(Error('Switch was incomplete. Check the current source before retrying.'));
              else p.resolve(d.results);
            } else if(!d.requestStatus?.result) p.reject(Error(d.requestStatus?.comment||'OBS could not complete the request.'));
            else p.resolve(d.responseData||{});
          }
        }catch(e){clearTimeout(timer);reject(e); if(!this.connected)ws.close();}
      };
      ws.onerror=()=>{clearTimeout(timer);reject(Error('Open OBS and enable its WebSocket server.'));};
      ws.onclose=()=>{
        clearTimeout(timer);reject(Error('OBS disconnected.'));
        if(this.ws!==ws)return;
        this.connected=false;
        for(const p of this.pending.values()){clearTimeout(p.timer);p.reject(Error('OBS disconnected. Check source visibility after reconnecting.'));}
        this.pending.clear();this.onChange({eventType:'Disconnected'});
      };
    });
  }
  send(op,data,count) {
    if(!this.connected || this.ws?.readyState!==1)return Promise.reject(Error('Connect to OBS first.'));
    const requestId='camera-switch-'+(++this.serial);
    return new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>{this.pending.delete(requestId);reject(Error('OBS timed out. Check source visibility before retrying.'));},6000);
      this.pending.set(requestId,{resolve,reject,timer,count});
      try{this.ws.send(JSON.stringify({op,d:{...data,requestId}}));}
      catch(e){clearTimeout(timer);this.pending.delete(requestId);reject(e);}
    });
  }
  call(requestType,requestData={}){return this.send(6,{requestType,requestData});}
  batch(requests){return this.send(8,{requests,executionType:0,haltOnFailure:true},requests.length);}
  close(){
    const ws=this.ws;this.ws=null;this.connected=false;
    for(const p of this.pending.values()){clearTimeout(p.timer);p.reject(Error('Connection closed.'));}
    this.pending.clear();ws?.close();
  }
}
function unique(items,name){
  const matches=items.filter(i=>i.sourceName===name);
  if(matches.length>1)throw Error(`More than one “${name}” was found. Use one copy in this scene.`);
  return matches[0];
}
async function inspect(obs,sceneName) {
  const {sceneItems}=await obs.call('GetSceneItemList',{sceneName});
  const buddy=unique(sceneItems,'[HTML] Typing buddy');
  const driving=unique(sceneItems,'[HTML] Driving buddy');
  let camera=unique(sceneItems,'Webcam');
  const group=unique(sceneItems,'NRC Camera · '+sceneName);
  if(group?.isGroup){
    if(camera)throw Error('This scene has both a standalone webcam and a camera group. Choose one in OBS first.');
    const children=await obs.call('GetGroupSceneItemList',{sceneName:group.sourceName});
    const webcam=unique(children.sceneItems,'Webcam');
    if(!webcam?.sceneItemEnabled)throw Error('Enable Webcam inside its camera group first.');
    camera=group;
  }
  if(!camera || !buddy)throw Error('Add Webcam and [HTML] Typing buddy to this scene to enable switching.');
  if(camera.sceneItemId===buddy.sceneItemId)throw Error('Camera and typing buddy must be separate sources.');
  const frame=sceneName===SCENE ? unique(sceneItems,FRAME) : null;
  const cameraItems=[camera,...frame?[frame]:[]];
  const mixed=cameraItems.some(i=>i.sceneItemEnabled!==camera.sceneItemEnabled);
  const active=[['camera',camera],['buddy',buddy],['driving',driving]].filter(([,item])=>item?.sceneItemEnabled).map(([mode])=>mode);
  const current=mixed?'mixed':active.length>1?'both':active[0]||'neither';
  return {sceneName,camera,cameraItems,buddy,driving,current};
}
class Switcher {
  constructor(obs){this.obs=obs;this.busy=false;}
  async choose(mode,sceneName,{follow=false}={}){
    if(!['camera','buddy','driving'].includes(mode))throw Error('Choose Webcam, Typing buddy or Driving buddy.');
    if(this.busy)throw Error('A switch is already in progress.');
    this.busy=true;
    try {
      const before=await inspect(this.obs,sceneName);
      if(follow){
        const live=await this.obs.call('GetCurrentProgramScene');
        if(live.currentProgramSceneName!==sceneName)throw Error('The active scene changed. Try again in the new scene.');
      }
      if(mode==='driving'&&!before.driving)throw Error('Add [HTML] Driving buddy to Camera Switch to enable this option.');
      const choices={camera:before.cameraItems,buddy:[before.buddy],driving:before.driving?[before.driving]:[]};
      const target=choices[mode];
      const other=Object.entries(choices).filter(([name])=>name!==mode).flatMap(([,items])=>items);
      const requests=[];
      // Hide the outgoing source first. A failed enable never leaves both visible.
      for(const [item,enabled] of [...other.map(i=>[i,false]),...target.map(i=>[i,true])]){
        if(item.sceneItemEnabled!==enabled)requests.push({requestType:'SetSceneItemEnabled',requestData:{sceneName,sceneItemId:item.sceneItemId,sceneItemEnabled:enabled}});
      }
      if(requests.length)await this.obs.batch(requests);
      const after=await inspect(this.obs,sceneName);
      if(after.current!==mode)throw Error('Visibility changed while switching. Check OBS and try again.');
      return after;
    } finally {this.busy=false;}
  }
}
root.NRCCamera={Socket,Switcher,inspect,SCENE};
if(typeof module!=='undefined')module.exports=root.NRCCamera;
})(typeof globalThis!=='undefined'?globalThis:this);
