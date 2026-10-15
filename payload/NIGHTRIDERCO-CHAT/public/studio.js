import { ChatView } from './chat-view.js';
import { startDemo } from './demo.js';
import { KickProvider } from './providers/kick.js';

const defaults={channel:'nightriderco',room:'132926621',theme:'panel',lang:'en',fontSize:24,maxMessages:12,fadeSeconds:0,hideCommands:true,bots:''};
const words={
  en:{studio:'CHAT STUDIO',local:'LOCAL COMPANION',eyebrow:'THE COMMUNITY, ON SCREEN',headline:'A place for\nyour crew.',intro:'Every message, part of the ride. Your own chat overlay, made to match the NIGHTRIDERCO stream.',youtubeLater:'YouTube ready to add later',connection:'Your connection',channel:'Kick channel',channelHint:'Public chat. No password or stream key needed.',connect:'Connect Kick',reconnect:'Reconnect Kick',demo:'Demo',appearance:'Make it yours',layout:'Overlay style',panel:'Community',panelHint:'Just Chatting scene',minimal:'Minimal',minimalHint:'Over your gameplay',textSize:'Text size',messageLimit:'Message limit',fadeAfter:'Fade after',seconds:'sec',fadeHint:'0 keeps messages until the panel fills.',hideCommands:'Hide chat commands',commandsHint:'Messages beginning with !',advanced:'Advanced settings',bots:'Hide these usernames',botsHint:'Separate exact usernames with commas.',room:'Kick chatroom ID',roomHint:'Verified for nightriderco. Leave empty to look it up.',roomOtherHint:'Optional. Leave empty to look up this channel.',preview:'The view from your stream',previewCaption:'Matched to your stream pack.',clear:'Clear preview',sceneTitle:'A perfect fit for Just Chatting.',sceneDetail:'Use a 680 × 923 Browser Source at X 1800, Y 250 on your 2560 × 1440 canvas. Keep the scene overlay above it.',obsTitle:'Take your crew into OBS.',obsHint:'Add a Browser Source, leave Local file off, and paste this URL. Keep this companion running.',copy:'Copy URL',open:'Open overlay',liveUrl:'This URL uses real Kick chat. Demo messages stay in the studio.',footer:'BUILD. CODE. RACE. TOGETHER.',demoTitle:'Demo preview',demoDetail:'Illustrative messages. Kick is not connected.',resolvingTitle:'Looking up your channel',resolvingDetail:'Finding the public Kick chatroom.',connectingTitle:'Connecting to Kick',connectingDetail:'Opening the chat connection.',connectedTitle:'Chat connected',connectedDetail:'Listening for new messages. This is a chat connection, not a stream-live indicator.',reconnectingTitle:'Reconnecting',reconnectingDetail:'The connection dropped. Trying again automatically.',errorTitle:'Chat is offline',errorDetail:'Check the channel or advanced chatroom ID, then reconnect.',disconnectedTitle:'Disconnected',disconnectedDetail:'Connect Kick to receive real chat messages.',demoMode:'DEMO PREVIEW',connectedMode:'CHAT CONNECTED',offlineMode:'CHAT OFFLINE',connectingMode:'CONNECTING',demoState:'DEMO',connectedState:'CONNECTED',offlineState:'OFFLINE',connectingState:'CONNECTING',copied:'Overlay URL copied. Paste it into your OBS Browser Source.',copyFailed:'Select the URL and copy it manually.',invalidChannel:'Enter a Kick channel username.',invalidRoom:'Use only numbers for the chatroom ID.'},
  es:{studio:'ESTUDIO DE CHAT',local:'ASISTENTE LOCAL',eyebrow:'LA COMUNIDAD, EN PANTALLA',headline:'Un lugar para\ntu comunidad.',intro:'Cada mensaje, parte del camino. Tu propio chat, diseñado para combinar con el stream de NIGHTRIDERCO.',youtubeLater:'YouTube se podrá agregar después',connection:'Tu conexión',channel:'Canal de Kick',channelHint:'Chat público. No necesitas contraseña ni clave de stream.',connect:'Conectar Kick',reconnect:'Reconectar Kick',demo:'Demo',appearance:'Hazlo tuyo',layout:'Estilo del chat',panel:'Comunidad',panelHint:'Escena Charlemos',minimal:'Minimalista',minimalHint:'Sobre tu juego',textSize:'Tamaño del texto',messageLimit:'Límite de mensajes',fadeAfter:'Ocultar después de',seconds:'seg',fadeHint:'0 conserva los mensajes hasta que se llene el panel.',hideCommands:'Ocultar comandos',commandsHint:'Mensajes que empiezan con !',advanced:'Ajustes avanzados',bots:'Ocultar estos usuarios',botsHint:'Separa los nombres de usuario exactos con comas.',room:'ID del chat de Kick',roomHint:'Verificado para nightriderco. Déjalo vacío para buscarlo.',roomOtherHint:'Opcional. Déjalo vacío para buscar el chat del canal.',preview:'Así se verá en tu stream',previewCaption:'A juego con tus gráficos de stream.',clear:'Limpiar vista previa',sceneTitle:'Encaja en tu escena Charlemos.',sceneDetail:'Usa una Fuente de navegador de 680 × 923 en X 1800, Y 250, sobre tu lienzo de 2560 × 1440. Coloca el gráfico de escena encima.',obsTitle:'Lleva tu comunidad a OBS.',obsHint:'Agrega una Fuente de navegador, deja Archivo local desactivado y pega esta URL. Mantén este asistente abierto.',copy:'Copiar URL',open:'Abrir chat',liveUrl:'Esta URL usa el chat real de Kick. Los mensajes de demo se quedan aquí.',footer:'CREAR. PROGRAMAR. CORRER. JUNTOS.',demoTitle:'Vista previa de demo',demoDetail:'Mensajes de ejemplo. Kick no está conectado.',resolvingTitle:'Buscando tu canal',resolvingDetail:'Buscando el chat público de Kick.',connectingTitle:'Conectando con Kick',connectingDetail:'Abriendo la conexión del chat.',connectedTitle:'Chat conectado',connectedDetail:'Esperando nuevos mensajes. Esta conexión no indica si el stream está en vivo.',reconnectingTitle:'Reconectando',reconnectingDetail:'Se perdió la conexión. Reintentando automáticamente.',errorTitle:'Chat sin conexión',errorDetail:'Revisa el canal o el ID avanzado del chat y reconecta.',disconnectedTitle:'Desconectado',disconnectedDetail:'Conecta Kick para recibir mensajes reales.',demoMode:'VISTA PREVIA',connectedMode:'CHAT CONECTADO',offlineMode:'SIN CONEXIÓN',connectingMode:'CONECTANDO',demoState:'DEMO',connectedState:'CONECTADO',offlineState:'SIN CONEXIÓN',connectingState:'CONECTANDO',copied:'URL del chat copiada. Pégala en tu Fuente de navegador de OBS.',copyFailed:'Selecciona la URL y cópiala manualmente.',invalidChannel:'Escribe el nombre de usuario de un canal de Kick.',invalidRoom:'El ID del chat debe contener solo números.'}
};
const form=document.querySelector('#settings-form');
const fields=Object.fromEntries(['channel','room','fontSize','maxMessages','fadeSeconds','hideCommands','bots'].map(key=>[key,document.getElementById(key)]));
const clamp=(value,min,max,fallback)=> Number.isFinite(Number(value)) ? Math.max(min,Math.min(max,Number(value))) : fallback;
let language='en';
let mode='demo';
let provider=null;
let stopDemo=null;
let connectionEpoch=0;
let lastStatus={state:'demo'};
try{
  const saved=JSON.parse(localStorage.getItem('nrc-chat-settings') || '{}');
  for(const key of Object.keys(fields)) if(saved[key] !== undefined) { if(key==='hideCommands') fields[key].checked=saved[key]===true; else fields[key].value=String(saved[key]); }
  if(saved.theme === 'minimal') form.elements.theme.value='minimal';
  language=saved.lang === 'es' ? 'es' : 'en';
}catch{}
// A shared studio URL may apply settings, but never silently starts a live connection.
const query=new URLSearchParams(location.search);
for(const key of Object.keys(fields)) if(query.has(key)) { if(key==='hideCommands') fields[key].checked=['1','true'].includes(query.get(key)); else fields[key].value=query.get(key); }
if(query.has('theme')) form.elements.theme.value=query.get('theme')==='minimal'?'minimal':'panel';
if(query.has('lang')) language=query.get('lang')==='es'?'es':'en';
const normalizeChannel=value=>String(value).trim().replace(/^https?:\/\/(www\.)?kick\.com\//i,'').replace(/^kick\.com\//i,'').replace(/\/$/,'').toLowerCase();
function getSettings(){
  return {channel:normalizeChannel(fields.channel.value),room:fields.room.value.trim(),theme:form.elements.theme.value==='minimal'?'minimal':'panel',lang:language,fontSize:clamp(fields.fontSize.value,18,38,24),maxMessages:Math.round(clamp(fields.maxMessages.value,3,30,12)),fadeSeconds:clamp(fields.fadeSeconds.value,0,300,0),hideCommands:fields.hideCommands.checked,bots:fields.bots.value.trim()};
}
let settings=getSettings();
const view=new ChatView(document.querySelector('#preview-messages'),settings);
function setStatus(status){
  lastStatus=status;
  const text=words[language];
  const state=status.state || 'disconnected';
  document.querySelector('#connection-dot').dataset.state=state;
  document.querySelector('#connection-title').textContent=text[`${state}Title`] || text.disconnectedTitle;
  const detail=document.querySelector('#connection-detail');
  detail.textContent=state==='error' && status.detail ? String(status.detail) : text[`${state}Detail`] || text.disconnectedDetail;
  if(status.detail) detail.title=String(status.detail); else detail.removeAttribute('title');
  const previewMode=document.querySelector('#preview-mode');
  const stateLabel=state==='demo'?'demo':state==='connected'?'connected':['resolving','connecting','reconnecting'].includes(state)?'connecting':'offline';
  previewMode.textContent=text[`${stateLabel}Mode`]; previewMode.dataset.mode=state;
  const previewState=document.querySelector('#preview-state'); previewState.textContent=text[`${stateLabel}State`]; previewState.dataset.state=state;
  document.querySelector('#preview-demo-note').hidden=state!=='demo';
  document.querySelector('#demo-button').classList.toggle('active',state==='demo');
  const connectButton=document.querySelector('#connect-button');
  connectButton.querySelector('[data-i18n]').textContent=mode==='live'?text.reconnect:text.connect;
}
function translate(){
  const text=words[language]; document.documentElement.lang=language;
  document.querySelectorAll('[data-i18n]').forEach(element=>{
    const key=element.dataset.i18n; if(!text[key]) return;
    if(key==='headline') { const parts=text[key].split('\n'); element.replaceChildren(document.createTextNode(parts[0]+' '),document.createElement('br'),document.createTextNode(parts[1])); }
    else element.textContent=text[key];
  });
  document.querySelectorAll('[data-language]').forEach(button=>{const selected=button.dataset.language===language;button.classList.toggle('active',selected);button.setAttribute('aria-pressed',String(selected));});
  setStatus(lastStatus);
}
function refreshSettings(){
  settings=getSettings();
  fields.channel.setCustomValidity(''); fields.room.setCustomValidity('');
  view.configure(settings);
  document.querySelector('#fontSize-value').replaceChildren(document.createTextNode(`${settings.fontSize} `),Object.assign(document.createElement('small'),{textContent:'px'}));
  fields.fontSize.style.setProperty('--range-progress',`${(settings.fontSize-18)/20*100}%`);
  const url=new URL('/overlay.html',location.origin);
  for(const [key,value] of Object.entries(settings)) url.searchParams.set(key,String(value));
  document.querySelector('#overlay-url').value=url.toString(); document.querySelector('#open-overlay').href=url.toString();
  const roomHint=document.querySelector('[data-i18n="roomHint"]'); roomHint.textContent=words[language][settings.channel==='nightriderco'?'roomHint':'roomOtherHint'];
  try{localStorage.setItem('nrc-chat-settings',JSON.stringify(settings));}catch{}
}
function disconnect(){
  connectionEpoch++;
  if(provider){provider.disconnect();provider=null;}
  if(stopDemo){stopDemo();stopDemo=null;}
}
function demo(){disconnect();mode='demo';view.clear();setStatus({state:'demo'});stopDemo=startDemo(view);}
async function connect(){
  refreshSettings();
  if(!/^[a-z0-9_-]{1,60}$/.test(settings.channel)){fields.channel.setCustomValidity(words[language].invalidChannel);fields.channel.reportValidity();return;}
  if(settings.room && (!/^[1-9]\d{0,15}$/.test(settings.room) || !Number.isSafeInteger(Number(settings.room)))){fields.room.setCustomValidity(words[language].invalidRoom);fields.room.reportValidity();return;}
  fields.channel.value=settings.channel;
  disconnect(); mode='live';view.clear();setStatus({state:'connecting'});
  const epoch=connectionEpoch;
  provider=new KickProvider({channel:settings.channel,roomId:settings.room,onMessage:message=>{if(epoch===connectionEpoch)view.add(message);},onDelete:id=>{if(epoch===connectionEpoch)view.remove(typeof id==='object'?id.id:id);},onBan:id=>{if(epoch===connectionEpoch)view.ban(typeof id==='object'?id.userId:id);},onClear:()=>{if(epoch===connectionEpoch)view.clear();},onStatus:status=>{
    if(epoch!==connectionEpoch)return;
    setStatus(status);
    if(status.roomId && !fields.room.value){fields.room.value=String(status.roomId);refreshSettings();}
  }});
  try{await provider.connect();}catch(error){if(epoch===connectionEpoch)setStatus({state:'error',detail:error.message});}
}
form.addEventListener('submit',event=>{event.preventDefault();connect();});
form.addEventListener('input',refreshSettings);
form.addEventListener('change',()=>{const current=getSettings();fields.fontSize.value=current.fontSize;fields.maxMessages.value=current.maxMessages;fields.fadeSeconds.value=current.fadeSeconds;refreshSettings();});
fields.channel.addEventListener('change',()=>{if(normalizeChannel(fields.channel.value)!=='nightriderco' && fields.room.value===defaults.room){fields.room.value='';refreshSettings();}});
// A connection belongs to the channel and room that were actually subscribed.
// Editing either stops that subscription until the user deliberately reconnects.
function connectionEdited(){if(mode==='live' && provider){disconnect();view.clear();setStatus({state:'disconnected'});}}
fields.channel.addEventListener('input',connectionEdited);
fields.room.addEventListener('input',connectionEdited);
document.querySelector('#connect-button').addEventListener('click',connect);
document.querySelector('#demo-button').addEventListener('click',demo);
document.querySelector('#clear-button').addEventListener('click',()=>view.clear());
document.querySelectorAll('[data-language]').forEach(button=>button.addEventListener('click',()=>{language=button.dataset.language;translate();refreshSettings();}));
document.querySelector('#copy-button').addEventListener('click',async()=>{
  const input=document.querySelector('#overlay-url'); const status=document.querySelector('#clipboard-status');
  try{
    if(navigator.clipboard?.writeText) await navigator.clipboard.writeText(input.value);
    else {input.focus();input.select();if(!document.execCommand('copy'))throw new Error('Clipboard unavailable');}
    status.textContent=words[language].copied;
  }catch{input.focus();input.select();status.textContent=words[language].copyFailed;}
});
const previewWindow=document.querySelector('#preview-window');
function fitPreview(){document.querySelector('#preview-canvas').style.transform=`scale(${previewWindow.clientWidth/680})`;view.trim();}
new ResizeObserver(fitPreview).observe(previewWindow);
translate();refreshSettings();demo();fitPreview();
addEventListener('pagehide',()=>{disconnect();view.destroy();},{once:true});
