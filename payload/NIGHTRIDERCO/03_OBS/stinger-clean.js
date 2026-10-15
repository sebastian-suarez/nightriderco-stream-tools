/* Same 60 fps / 72-frame geometry as the native MOV. Clear tail, no CSS reset. */
(()=>{'use strict';
 const W=2560,H=1440,FPS=60,TOTAL=72,DURATION=1200;
 const cfg=window.NRC_CONFIG||{},qs=new URLSearchParams(location.search);
 const canvas=document.getElementById('wipe'),ctx=canvas.getContext('2d');
 const reduced=qs.get('motion')==='off'||matchMedia('(prefers-reduced-motion: reduce)').matches;
 let active=false,start=0,covered=false,last=-1;
 const ease=v=>{const t=Math.max(0,Math.min(1,v));return t*t*(3-2*t)};
 function fit(){const scale=Math.min(innerWidth/W,innerHeight/H);canvas.style.width=W*scale+'px';canvas.style.height=H*scale+'px';canvas.style.left=(innerWidth-W*scale)/2+'px';canvas.style.top=(innerHeight-H*scale)/2+'px'}
 function path(points){ctx.beginPath();points.forEach(([x,y],i)=>i?ctx.lineTo(x,y):ctx.moveTo(x,y));ctx.closePath()}
 function polygon(points,color){path(points);ctx.fillStyle=color;ctx.fill()}
 function draw(index){
  ctx.clearRect(0,0,W,H);
  const t=index/FPS;
  if(index===0||t>=1.10)return;
  if(reduced){if(t>=.45&&t<.75){ctx.fillStyle='#0B1118';ctx.fillRect(0,0,W,H)}return}
  const skew=520,arrival=t<.45,departure=t>=.75;
  let left=-skew-100,right=W+skew+100;
  if(arrival)right=-skew-120+(W+2*skew+240)*ease(t/.45);
  if(departure)left=-skew-120+(W+2*skew+240)*ease((t-.75)/.35);
  ctx.save();ctx.translate(0,H);ctx.scale(1,-1);
  path([[left-skew/2,0],[right-skew/2,0],[right+skew/2,H],[left+skew/2,H]]);ctx.clip();
  ctx.fillStyle='#0B1118';ctx.fillRect(0,0,W,H);
  polygon([[W*.38,0],[W*.73,0],[W*.92,H],[W*.57,H]],'#152330');
  polygon([[-300,0],[230,0],[W*.30,H],[0,H]],'#152330');
  ctx.strokeStyle='rgba(116,223,255,.10)';ctx.lineWidth=2;
  for(let x=-500;x<=W+500;x+=320){ctx.beginPath();ctx.moveTo(x,0);ctx.lineTo(x+skew,H);ctx.stroke()}
  const edge=departure?left+54:right,band=42;
  polygon([[edge-skew/2-band,0],[edge-skew/2,0],[edge+skew/2,H],[edge+skew/2-band,H]],'#74DFFF');
  polygon([[edge-skew/2-band-12,0],[edge-skew/2-band-6,0],[edge+skew/2-band-6,H],[edge+skew/2-band-12,H]],'#F1F6F8');
  ctx.restore();
 }
 function tick(now){
  if(!active)return;
  const elapsed=Math.max(0,now-start),index=Math.min(TOTAL-1,Math.floor(elapsed*FPS/1000));
  if(index!==last){draw(index);last=index}
  if(!covered&&elapsed>=600){covered=true;dispatchEvent(new CustomEvent('nrc:stinger-covered'));if(window.parent!==window)window.parent.postMessage({channel:'nrc',event:'stinger-covered'},'*')}
  if(elapsed>=DURATION){ctx.clearRect(0,0,W,H);active=false;return}
  requestAnimationFrame(tick);
 }
 function play(){if(active)return;active=true;covered=false;last=-1;start=performance.now();ctx.clearRect(0,0,W,H);requestAnimationFrame(tick)}
 fit();addEventListener('resize',fit);addEventListener('click',play);addEventListener('nrc:transition',play);
 addEventListener('message',e=>{if(e.data?.channel==='nrc'&&e.data.event==='transition')play()});
 window.NRC_TRANSITION=play;
 if(qs.has('demo')?qs.get('demo')==='1':cfg.demoTransition===true)setTimeout(play,600);
})();
