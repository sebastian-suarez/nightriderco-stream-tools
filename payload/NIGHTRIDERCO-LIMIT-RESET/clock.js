(() => {
 'use strict';
 const config=window.LIMIT_RESET_CONFIG||{},zone=config.timeZone||'America/Bogota',deadline=Date.parse(config.resetAt);
 const nowFormat=new Intl.DateTimeFormat('en-US',{timeZone:zone,hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:true});
 const resetFormat=new Intl.DateTimeFormat('en-US',{timeZone:zone,hour:'numeric',minute:'2-digit',hour12:true});
 const $=id=>document.getElementById(id);let timer=null,lastState=null;
 const pad=n=>String(n).padStart(2,'0');
 function render(now=Date.now()){
  const parts=Object.fromEntries(nowFormat.formatToParts(new Date(now)).map(p=>[p.type,p.value]));
  $('local-time').textContent=`${parts.hour}:${parts.minute}:${parts.second}`;$('local-period').textContent=parts.dayPeriod;
  const valid=Number.isFinite(deadline),remaining=valid?Math.max(0,Math.ceil((deadline-now)/1000)):null,reached=valid&&remaining===0;
  $('reset-time').textContent=valid?resetFormat.format(new Date(deadline)):'SET RESET TIME';
  $('countdown-label').textContent=reached?'RESET TIME REACHED':'UNTIL RESET';
  $('countdown').textContent=valid?`${pad(Math.floor(remaining/3600))}:${pad(Math.floor(remaining%3600/60))}:${pad(remaining%60)}`:'--:--:--';
  document.querySelector('.clock').classList.toggle('reached',reached);
  lastState={now,deadline,remaining,reached,timeZone:zone,currentTime:`${$('local-time').textContent} ${parts.dayPeriod}`,resetTime:$('reset-time').textContent};
 }
 function start(){clearInterval(timer);render();timer=setInterval(()=>render(),250);}
 addEventListener('pagehide',()=>{clearInterval(timer);timer=null;});addEventListener('pageshow',start);
 window.LimitClock={renderAt(t){clearInterval(timer);timer=null;render(t);},resume:start,getState:()=>({...lastState})};start();
})();
