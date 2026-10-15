import { ChatView } from './chat-view.js';
import { startDemo } from './demo.js';
import { KickProvider } from './providers/kick.js';

const query=new URLSearchParams(location.search);
const settings={channel:query.get('channel') || 'nightriderco',roomId:query.get('room') || '',theme:query.get('theme'),lang:query.get('lang'),fontSize:query.get('fontSize') || 24,maxMessages:query.get('maxMessages') || 12,fadeSeconds:query.get('fadeSeconds') || 0,hideCommands:query.get('hideCommands'),bots:query.get('bots') || ''};
const view=new ChatView(document.querySelector('#messages'),settings);
const state=document.querySelector('#overlay-state');
const labels={en:{demo:'DEMO',resolving:'RESOLVING',connecting:'CONNECTING',connected:'CONNECTED',reconnecting:'RECONNECTING',error:'OFFLINE',disconnected:'OFFLINE'},es:{demo:'DEMO',resolving:'BUSCANDO',connecting:'CONECTANDO',connected:'CONECTADO',reconnecting:'RECONECTANDO',error:'SIN CONEXIÓN',disconnected:'SIN CONEXIÓN'}};
let provider;
let stopDemo;
if(query.get('mode') === 'demo') {
  state.dataset.state='demo'; state.textContent='DEMO';
  document.querySelector('#demo-note').hidden=false;
  stopDemo=startDemo(view);
} else {
  provider=new KickProvider({channel:settings.channel,roomId:settings.roomId,onMessage:message=>view.add(message),onDelete:id=>view.remove(typeof id==='object'?id.id:id),onBan:id=>view.ban(typeof id==='object'?id.userId:id),onClear:()=>view.clear(),onStatus:status=>{
    state.dataset.state=status.state;
    state.textContent=labels[view.options.lang][status.state] || labels[view.options.lang].disconnected;
    state.title=String(status.detail || '');
  }});
  Promise.resolve(provider.connect()).catch(error=> {state.dataset.state='error';state.textContent=labels[view.options.lang].error;state.title=error.message;});
}
addEventListener('pagehide',()=>{provider?.disconnect();stopDemo?.();view.destroy();},{once:true});
