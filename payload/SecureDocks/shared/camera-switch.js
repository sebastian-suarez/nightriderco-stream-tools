(() => {
'use strict';
const $=id=>document.getElementById(id);
const api=new NRCKeychain.KeychainClient();
const sceneName=NRCCamera.SCENE;
let snapshot=null, refreshing=false, generation=0, connecting=false, stopped=false, retry=null, actionError='', readError='';
const obs=new NRCCamera.Socket({authenticate:(port,salt,challenge)=>api.authentication(port,salt,challenge),onChange:()=>{
  if(!obs.connected){snapshot=null;render();scheduleReconnect();}else if(!switcher.busy)refresh();
}});
const switcher=new NRCCamera.Switcher(obs);
function render(){
  $('connection').textContent=obs.connected?'Connected':connecting?'Connecting…':'Offline';
  $('connection').classList.toggle('online',obs.connected);
  for(const mode of ['camera','buddy','driving']){
    const missing=mode==='driving'&&snapshot&&!snapshot.driving;
    $(mode).disabled=!obs.connected||!snapshot||switcher.busy||missing;
    $(mode).setAttribute('aria-pressed',String(snapshot?.current===mode));
    $(mode+'-state').textContent=missing?'Source not added':snapshot?.current===mode?'Visible now':({camera:'Show camera + frame',buddy:'Show typing buddy',driving:'Show driving buddy'}[mode]);
  }
  $('scene-name').textContent=snapshot?'Shared across your scenes':(!obs.connected?'Waiting for OBS…':'Camera Switch unavailable');
  $('message').textContent=switcher.busy?'Switching…':snapshot?({camera:'Webcam is visible.',buddy:'Typing buddy is visible.',driving:'Driving buddy is visible.',both:'Multiple sources are visible. Choose one to switch.',neither:'All are hidden. Choose one to show.',mixed:'Camera and frame differ. Choose a source to sync them.'}[snapshot.current]):'Connecting to the reusable Camera Switch scene.';
  const error=actionError||readError;$('error').hidden=!error;$('error').textContent=error;
}
async function refresh(){
  if(!obs.connected||refreshing||switcher.busy)return;
  refreshing=true;const version=generation;
  try{
    const observed=await NRCCamera.inspect(obs,sceneName);
    if(version===generation&&!switcher.busy){snapshot=observed;readError='';render();}
  }catch(e){if(version===generation&&!switcher.busy){snapshot=null;readError=e.message;render();}}
  finally{refreshing=false;}
}
function scheduleReconnect(){clearTimeout(retry);if(!stopped)retry=setTimeout(connect,3500);}
async function connect(){
  if(connecting||stopped)return;
  connecting=true;actionError='';readError='';snapshot=null;generation++;render();
  try{
    let port=4455;try{port=NRCKeychain.validPort(localStorage.getItem(NRCKeychain.PORT_KEY)||4455);}catch{}
    await obs.connect(port);connecting=false;actionError='';render();await refresh();
  }catch(e){actionError=e.message+' Reconnecting automatically.';scheduleReconnect();}
  finally{connecting=false;render();}
}
for(const mode of ['camera','buddy','driving'])$(mode).addEventListener('click',async()=>{
  if(!snapshot||switcher.busy)return;
  actionError='';generation++;
  try{
    const operation=switcher.choose(mode,sceneName);render();
    snapshot=await operation;
  }catch(e){actionError=e.message;snapshot=null;}
  finally{render();await refresh();}
});
$('refresh').addEventListener('click',()=>{actionError='';if(obs.connected)refresh();else connect();});
const poll=setInterval(()=>{if(obs.connected)refresh();},1200);
addEventListener('pagehide',()=>{stopped=true;clearInterval(poll);clearTimeout(retry);obs.close();});
render();connect();
})();
