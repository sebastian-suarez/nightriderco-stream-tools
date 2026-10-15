
/* All sources stay local: no analytics, no remote fonts, no service credentials. */
(()=>{'use strict';
const cfg=window.NRC_CONFIG, qs=new URLSearchParams(location.search), page=document.body.dataset.page;
const stage=document.getElementById('stage'), dims=page==='language-bar'?[1200,120]:[2560,1440];
const requestedLang=qs.has('lang')?qs.get('lang'):cfg.defaultLanguage;
const fixed=['en','es'].includes(requestedLang)?requestedLang:null;
const interval=Math.max(3000,Number(cfg.languageInterval)||6000);
document.documentElement.style.setProperty('--language-duration',interval+'ms');
let lang=fixed||'en';
Object.entries(cfg.colors).forEach(([k,v])=>document.documentElement.style.setProperty('--'+k,v));
if(qs.get('motion')==='off')document.body.classList.add('no-motion');
function resize(){const s=Math.min(innerWidth/dims[0],innerHeight/dims[1]);stage.style.transform=`scale(${s})`;stage.style.left=`${(innerWidth-dims[0]*s)/2}px`;stage.style.top=`${(innerHeight-dims[1]*s)/2}px`;}
addEventListener('resize',resize);resize();
const get=(key,l=lang)=>cfg.text[key]?.[l]||key;
function setLanguage(next,animate=true){lang=next;document.documentElement.lang=next;document.querySelectorAll('[data-i18n]').forEach(el=>{if(animate)el.classList.add('changing');setTimeout(()=>{el.textContent=get(el.dataset.i18n);el.classList.remove('changing')},animate?180:0)});}
setLanguage(lang,false);
if(!fixed&&page!=='alerts')setInterval(()=>setLanguage(lang==='en'?'es':'en'),interval);
if(page==='starting-soon'){
 const supplied=Number(qs.has('minutes')?qs.get('minutes'):cfg.countdownMinutes);const minutes=Number.isFinite(supplied)?Math.max(0,Math.min(supplied,180)):5;
 const end=Date.now()+minutes*60000;const counter=document.getElementById('countdown');
 function tick(){const left=Math.max(0,Math.ceil((end-Date.now())/1000));counter.textContent=`${String(Math.floor(left/60)).padStart(2,'0')}:${String(left%60).padStart(2,'0')}`;if(!left){const label=document.getElementById('count-label');label.dataset.i18n='ready';label.textContent=get('ready');}}
 tick();setInterval(tick,250);
}
if(page==='alerts'){
 const settings=cfg.alerts||{};
 const clamp=(value,min,max,fallback)=>Number.isFinite(Number(value))?Math.max(min,Math.min(max,Number(value))):fallback;
 const duration=clamp(settings.durationMs,1800,6000,2800),gap=clamp(settings.gapMs,400,5000,900),margin=clamp(settings.margin,16,160,40);
 const positions=['top-right','top-left','bottom-right','bottom-left'];
 const position=positions.includes(settings.position)?settings.position:'top-right';
 let busy=false;const queue=[];const card=document.querySelector('.alert-card');
 const title=document.getElementById('alert-title'),name=document.getElementById('alert-name'),detail=document.getElementById('alert-detail'),mark=document.getElementById('alert-icon');
 card.style.top=card.style.right=card.style.bottom=card.style.left='auto';
 card.style[position.startsWith('top')?'top':'bottom']=margin+'px';
 card.style[position.endsWith('right')?'right':'left']=margin+'px';
 const icons={follower:'<path d="M46 80V22M17 51l29-29 29 29M18 82h56"/>',sub:'<path d="M46 11l10 23 25 3-19 17 6 25-22-13-22 13 6-25-19-17 25-3z"/>',gift:'<rect x="17" y="38" width="58" height="43"/><path d="M12 27h68v16H12zM46 27v54M46 27C12 26 24-6 46 27C68-6 80 26 46 27"/>',tip:'<path d="M17 25h58v43H17zM30 17h58v43M46 35v23M39 40h13M39 53h13"/>',raid:'<path d="M46 11v70M21 26l25-15 25 15M11 67l35 14 35-14M20 44l26-13 26 13"/>'};
 const fallback={follower:{en:'NEW FOLLOWER',es:'NUEVO SEGUIDOR'},sub:{en:'NEW SUBSCRIBER',es:'NUEVO SUSCRIPTOR'},gift:{en:'GIFTED SUBSCRIPTIONS',es:'SUSCRIPCIONES REGALADAS'},tip:{en:'THANK YOU FOR THE SUPPORT',es:'GRACIAS POR EL APOYO'},raid:{en:'RAID INCOMING',es:'LLEGA UNA RAID'}};
 const clean=(value,max=64)=>typeof value==='string'?value.slice(0,max):'';
 const eventTitle=(type,language)=>clean(cfg.text?.[type+'Title']?.[language],96)||fallback[type][language];
 function showNext(){
  if(busy||!queue.length)return;busy=true;
  const d=queue.shift(),type=d.type,base=fixed||'en';
  title.classList.remove('changing');title.textContent=eventTitle(type,base);
  name.textContent=d.demo?(clean(cfg.text?.preview?.[base])||(base==='es'?'VISTA PREVIA':'PREVIEW')):(clean(d.name)||clean(cfg.name)||'NIGHTRIDERCO');
  const count=Number(d.count);
  detail.textContent=clean(d.amount,24)||(Number.isFinite(count)&&count>0?'× '+Math.floor(count):'');
  detail.hidden=!detail.textContent;mark.innerHTML=icons[type];
  if(cfg.audio?.enabled===true){const audio=new Audio('../06_AUDIO/'+(type==='follower'?'follow':type)+'.wav');audio.volume=clamp(cfg.audio.volume,0,1,0.15);audio.play().catch(()=>{});}
  card.classList.remove('visible');void card.offsetWidth;card.classList.add('visible');
  if(!fixed)setTimeout(()=>{title.classList.add('changing');setTimeout(()=>{title.textContent=eventTitle(type,'es');title.classList.remove('changing');},160);},Math.round(duration/2)-160);
  setTimeout(()=>{card.classList.remove('visible');},duration);
  setTimeout(()=>{busy=false;showNext();},duration+gap);
 }
 function enqueue(d){if(!d||!Object.hasOwn(icons,d.type))return;if(queue.length>=20)queue.shift();queue.push({type:d.type,name:d.name,amount:d.amount,count:d.count,demo:d.demo===true});showNext();}
 addEventListener('nrc:alert',e=>enqueue(e.detail));
 addEventListener('message',e=>{if(e.data&&e.data.channel==='nrc'&&e.data.event==='alert')enqueue(e.data.detail)});
 window.NRC_ALERT=enqueue;
 if(qs.has('demo')?qs.get('demo')==='1':cfg.demoAlerts===true)setTimeout(()=>['follower','sub','gift','tip','raid'].forEach(type=>enqueue({type,demo:true})),700);
}
if(page==='stinger'){
 const sheet=document.querySelector('.stinger-sheet');let active=false;
 function play(){if(active)return;active=true;sheet.classList.remove('playing');void sheet.offsetWidth;sheet.classList.add('playing');setTimeout(()=>{dispatchEvent(new CustomEvent('nrc:stinger-covered'));if(window.parent!==window)window.parent.postMessage({channel:'nrc',event:'stinger-covered'},'*')},650);setTimeout(()=>{sheet.classList.remove('playing');active=false},1400);}
 addEventListener('click',play);addEventListener('nrc:transition',play);addEventListener('message',e=>{if(e.data?.channel==='nrc'&&e.data.event==='transition')play()});window.NRC_TRANSITION=play;
 if(qs.has('demo')?qs.get('demo')==='1':cfg.demoTransition===true)setTimeout(play,600);
}
})();
