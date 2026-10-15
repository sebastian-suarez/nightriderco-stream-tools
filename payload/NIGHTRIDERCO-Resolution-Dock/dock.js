(() => {
 const $=id=>document.getElementById(id);let busy=false,state=null;
 function render(s){
  state=s;const online=!!s.connected,locked=busy||s.busy||!online||s.active?.length>0||s.recovery;
  $('connection').textContent=online?'Connected':'Offline';$('connection').classList.toggle('online',online);
  for(const mode of ['fhd','qhd']){$(mode).disabled=!!locked;$(mode).setAttribute('aria-pressed',String(s.mode===mode));}
  $('canvas').textContent=s.video?`Canvas · ${s.video.baseWidth} × ${s.video.baseHeight}`:'Canvas · —';
  $('output').textContent=s.video?`Output · ${s.video.outputWidth} × ${s.video.outputHeight}`:'Output · —';
  $('profile').textContent=s.context?`${s.context.collection} · ${s.context.profile}`:'OBS Studio';
  $('undo').disabled=busy||s.busy||!online||!s.canUndo||s.active?.length>0;
  $('message').textContent=busy||s.busy?'Updating resolution and layouts…':s.recovery?'An interrupted change needs recovery. Use Restore previous.':s.active?.length?`Resolution locked while ${s.active.join(', ')} is active.`:s.message||'Choose FHD or 2K. All scenes update together.';
 }
 async function refresh(){if(busy)return;try{const r=await fetch('/state');if(!r.ok)throw Error('Local helper unavailable.');render(await r.json());}catch(e){render({connected:false,message:'Start the Resolution Dock helper, then refresh this dock.'});}}
 async function action(route,data){if(busy)return;busy=true;$('error').hidden=true;if(state)render(state);
  try{const r=await fetch(route,{method:'POST',headers:{'Content-Type':'application/json','X-NRC-Resolution':'1'},body:JSON.stringify(data)});const result=await r.json();if(!r.ok)throw Error(result.error||'OBS could not apply the change.');state=result;}
  catch(e){$('error').textContent=e.message;$('error').hidden=false;}
  finally{busy=false;await refresh();}
 }
 for(const mode of ['fhd','qhd'])$(mode).addEventListener('click',()=>action('/switch',{mode}));
 $('undo').addEventListener('click',()=>action('/undo',{}));
 refresh();setInterval(refresh,2000);
})();
