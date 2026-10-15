/* NIGHTRIDERCO driving buddy v1.0 — standalone artwork, no input/device access. */
(() => {
  'use strict';
  const canvas=document.getElementById('mascot'),ctx=canvas.getContext('2d');
  const params=new URLSearchParams(location.search);
  const modes=['auto','idle','left','right'];
  let mode=modes.includes(params.get('mode'))?params.get('mode'):'auto';
  let intensity=['calm','normal','spirited'].includes(params.get('motion'))?params.get('motion'):'normal';
  let seed=Number(params.get('seed'))||Math.floor(Math.random()*4294967295);
  const initialSeed=seed;
  const random=()=>{seed|=0;seed=seed+0x6D2B79F5|0;let t=Math.imul(seed^seed>>>15,1|seed);t=t+Math.imul(t^t>>>7,61|t)^t;return ((t^t>>>14)>>>0)/4294967296;};
  const clamp=(v,lo=0,hi=1)=>Math.max(lo,Math.min(hi,v));
  const smooth=v=>{v=clamp(v);return v*v*(3-2*v);};
  const ease=v=>{v=clamp(v);return v*v*v*(v*(v*6-15)+10);};
  const atlas=new Image(),wheel=new Image();
  const src={body:[25,0,485,630],blink:[526,0,485,630],left:[103,625,361,380]};
  const armTexture=document.createElement('canvas');armTexture.width=220;armTexture.height=240;
  const frontArm=document.createElement('canvas');frontArm.width=220;frontArm.height=240;
  let ready=false,raf=null,previous=null,time=0,angle=0,lean=0,paused=false;
  let segmentStart=0,segmentDuration=3200,from=0,to=0,nextBlink=3300,blinkUntil=0;
  const state={version:'1.0.0',ready:false,frames:0,mode,intensity,seed:initialSeed,input:'procedural',wheelConnected:false,angleDegrees:0,blinking:false,arms:[]};
  const wheelOrigin=[627,627],wheelScale=.25,wheelCenter=[300,451];
  const rotate=(x,y,a,o)=>[o[0]+x*Math.cos(a)-y*Math.sin(a),o[1]+x*Math.sin(a)+y*Math.cos(a)];

  function buildArmTexture(){
    const c=armTexture.getContext('2d');c.save();c.translate(90,30);c.rotate(33*Math.PI/180);
    c.drawImage(atlas,...src.left,104-145,326-350,142,150);c.restore();
    const f=frontArm.getContext('2d');f.drawImage(armTexture,0,0);f.globalCompositeOperation='destination-in';
    const mask=f.createLinearGradient(0,28,0,66);mask.addColorStop(0,'rgba(0,0,0,0)');mask.addColorStop(1,'rgba(0,0,0,1)');f.fillStyle=mask;f.fillRect(0,0,220,240);f.globalCompositeOperation='source-over';
  }
  function solveArm(shoulder,wrist,side){
    const upper=91,lower=72,dx=wrist[0]-shoulder[0],dy=wrist[1]-shoulder[1];
    const distance=clamp(Math.hypot(dx,dy),Math.abs(upper-lower)+.01,upper+lower-.01);
    const direction=Math.atan2(dy,dx),bend=Math.acos(clamp((upper*upper+distance*distance-lower*lower)/(2*upper*distance),-1,1));
    const a=direction+side*bend;
    const elbow=[shoulder[0]+Math.cos(a)*upper,shoulder[1]+Math.sin(a)*upper];
    return {shoulder,elbow,wrist,upper,lower,upperAngle:a-Math.PI/2,lowerAngle:Math.atan2(wrist[1]-elbow[1],wrist[0]-elbow[0])-Math.PI/2};
  }
  function triangle(source,dest,texture){
    const [s0,s1,s2]=source,[p0,p1,p2]=dest;
    const ux=s1[0]-s0[0],uy=s1[1]-s0[1],vx=s2[0]-s0[0],vy=s2[1]-s0[1],det=ux*vy-uy*vx;
    const a=((p1[0]-p0[0])*vy-(p2[0]-p0[0])*uy)/det,b=((p1[1]-p0[1])*vy-(p2[1]-p0[1])*uy)/det;
    const c=((p2[0]-p0[0])*ux-(p1[0]-p0[0])*vx)/det,d=((p2[1]-p0[1])*ux-(p1[1]-p0[1])*vx)/det;
    const orientation=Math.sign((p1[0]-p0[0])*(p2[1]-p0[1])-(p1[1]-p0[1])*(p2[0]-p0[0]));
    const normals=dest.map((p,i)=>{const q=dest[(i+1)%3],n=Math.hypot(q[0]-p[0],q[1]-p[1])||1;return[(q[1]-p[1])/n*orientation,-(q[0]-p[0])/n*orientation];});
    ctx.save();ctx.beginPath();
    for(let i=0;i<3;i++){const p=dest[i],a=normals[(i+2)%3],b=normals[i],n=.6/Math.max(.08,1+a[0]*b[0]+a[1]*b[1]);
      const x=p[0]+(a[0]+b[0])*n,y=p[1]+(a[1]+b[1])*n;if(i===0)ctx.moveTo(x,y);else ctx.lineTo(x,y);}
    ctx.closePath();ctx.clip();ctx.transform(a,b,c,d,p0[0]-a*s0[0]-c*s0[1],p0[1]-b*s0[0]-d*s0[1]);
    ctx.drawImage(texture,0,0);ctx.restore();
  }
  function drawArm(pose,side,texture=armTexture){
    function warp(x,y){
      const offset=(x-90)*(.94-.25*smooth((y-100)/32))*(side===1?1:-1);
      const upper=rotate(offset,(y-30)*pose.upper/60,pose.upperAngle,pose.shoulder);
      const lower=rotate(offset,(y-90)*pose.lower/42,pose.lowerAngle,pose.elbow);
      const w=smooth((y-82)/16);return upper.map((v,i)=>v+(lower[i]-v)*w);
    }
    const rows=[5,30,65,82,86,90,94,98,112,125,136],cols=[20,65,115,182];
    for(let y=0;y<rows.length-1;y++)for(let x=0;x<cols.length-1;x++){
      const a=[cols[x],rows[y]],b=[cols[x+1],rows[y]],c=[cols[x+1],rows[y+1]],d=[cols[x],rows[y+1]];
      triangle([a,b,c],[warp(...a),warp(...b),warp(...c)],texture);triangle([a,c,d],[warp(...a),warp(...c),warp(...d)],texture);
    }
  }
  function bodyTransform(){ctx.translate(300,390);ctx.rotate(lean);ctx.translate(-300,-390);}
  function drawBody(breath,blink){
    ctx.save();bodyTransform();ctx.drawImage(atlas,...src.body,120,24+breath,360,467);
    if(blink){ctx.save();ctx.beginPath();ctx.rect(212,177+breath,191,48);ctx.clip();ctx.drawImage(atlas,...src.blink,120,24+breath,360,467);ctx.restore();}
    ctx.restore();
  }
  function rounded(x,y,w,h,r){ctx.beginPath();ctx.roundRect(x,y,w,h,r);}
  function drawBase(){
    // The fixed motor housing faces the viewer; the rim turns on its shaft.
    ctx.save();
    let g=ctx.createLinearGradient(259,454,342,551);g.addColorStop(0,'#353d47');g.addColorStop(.48,'#141c23');g.addColorStop(1,'#0b1016');
    ctx.fillStyle='#0a0f14';ctx.strokeStyle='#526370';ctx.lineWidth=1.5;
    rounded(277,438,46,51,11);ctx.fill();ctx.stroke();
    ctx.fillStyle=g;ctx.beginPath();ctx.moveTo(255,470);ctx.lineTo(345,470);ctx.lineTo(361,491);ctx.lineTo(361,552);ctx.quadraticCurveTo(361,563,350,563);ctx.lineTo(250,563);ctx.quadraticCurveTo(239,563,239,552);ctx.lineTo(239,491);ctx.closePath();ctx.fill();ctx.stroke();
    ctx.fillStyle='#080d12';rounded(247,491,106,55,6);ctx.fill();
    for(let y=496;y<542;y+=6){ctx.strokeStyle='#39454f';ctx.lineWidth=2;ctx.beginPath();ctx.moveTo(254,y);ctx.lineTo(346,y);ctx.stroke();ctx.strokeStyle='#06090d';ctx.beginPath();ctx.moveTo(254,y+2);ctx.lineTo(346,y+2);ctx.stroke();}
    ctx.fillStyle='#aebcc5';ctx.font='600 9px system-ui,sans-serif';ctx.textAlign='center';ctx.fillText('logitech G',300,485);
    ctx.font='600 7px system-ui,sans-serif';ctx.fillStyle='#738793';ctx.fillText('RS50',300,555);
    ctx.fillStyle='#111b23';rounded(257,562,86,9,3);ctx.fill();ctx.strokeStyle='#334551';ctx.stroke();
    ctx.restore();
  }
  function render(){
    ctx.clearRect(0,0,600,600);if(!ready)return;
    const breath=Math.sin(time*.00165)*1.1,blink=time<blinkUntil;
    const shoulders=[rotate(-125,-16+breath,lean,[300,390]),rotate(125,-16+breath,lean,[300,390])];
    // Both grip points share exactly the wheel transform, so neither paw slides.
    const wrists=[rotate(-118,0,angle,wheelCenter),rotate(118,0,angle,wheelCenter)];
    const poses=[solveArm(shoulders[0],wrists[0],1),solveArm(shoulders[1],wrists[1],-1)];
    poses.forEach((p,i)=>drawArm(p,i===0?1:-1));
    drawBody(breath,blink);
    // Keep shoulders under the ruff but put the elbows in front of the lower body.
    poses.forEach((p,i)=>drawArm(p,i===0?1:-1,frontArm));
    ctx.save();ctx.translate(...wheelCenter);ctx.rotate(angle);
    ctx.drawImage(wheel,-wheelOrigin[0]*wheelScale,-wheelOrigin[1]*wheelScale,wheel.width*wheelScale,wheel.height*wheelScale);ctx.restore();
    drawBase();
    Object.assign(state,{mode,intensity,angleDegrees:angle*180/Math.PI,blinking:blink,time,paused,arms:poses.map(p=>({shoulder:p.shoulder,elbow:p.elbow,wrist:p.wrist,upperLength:Math.hypot(p.elbow[0]-p.shoulder[0],p.elbow[1]-p.shoulder[1]),lowerLength:Math.hypot(p.wrist[0]-p.elbow[0],p.wrist[1]-p.elbow[1])}))});
  }
  function step(dt){
    if(paused)return;
    time+=dt;
    if(time>=nextBlink){blinkUntil=time+120;nextBlink=time+3100+random()*3200;}
    const max=intensity==='calm'?14:intensity==='spirited'?30:23;
    if(time-segmentStart>=segmentDuration){
      from=to;segmentStart=time;segmentDuration=2500+random()*3800;
      const choice=random();to=choice<.23?0:(random()*2-1)*max*Math.PI/180;
    }
    const segmentAngle=from+(to-from)*ease((time-segmentStart)/segmentDuration);
    const corrections=(Math.sin(time*.0031)+Math.sin(time*.0017+.8)*.45)*.008;
    // We see the back of the wheel, so driver-left appears clockwise to us.
    const target=mode==='idle'?0:mode==='left'?.40:mode==='right'?-.40:segmentAngle+corrections;
    angle+=(target-angle)*(1-Math.exp(-dt/150));
    const leanTarget=-angle*.055+Math.sin(time*.00072)*.003;
    lean+=(leanTarget-lean)*(1-Math.exp(-dt/300));
  }
  function frame(now){
    raf=null;if(previous!==null)step(clamp(now-previous,0,50));previous=now;render();state.frames++;
    if(!paused)raf=requestAnimationFrame(frame);
  }
  function start(){if(raf===null&&!paused){previous=null;raf=requestAnimationFrame(frame);}}
  function setMode(value){if(modes.includes(value)){mode=value;state.mode=mode;}}
  function setIntensity(value){if(['calm','normal','spirited'].includes(value)){intensity=value;from=angle;to=0;segmentStart=time;segmentDuration=1800;}}
  function setPaused(value){paused=!!value;if(paused){if(raf!==null)cancelAnimationFrame(raf);raf=null;render();}else start();}
  // Narrow local preview API; no keyboard, mouse, microphone, gamepad or wheel listeners.
  window.DrivingBuddy={getState:()=>structuredClone(state),setMode,setIntensity,setPaused,
    advance(ms){if(!paused)throw Error('Pause before advancing the preview');const was=paused;paused=false;for(let n=0;n<ms;n+=16.6667)step(Math.min(16.6667,ms-n));paused=was;render();return this.getState();}};
  addEventListener('pagehide',()=>{if(raf!==null)cancelAnimationFrame(raf);raf=null;previous=null;});
  addEventListener('pageshow',()=>{if(ready)start();});
  document.addEventListener('visibilitychange',()=>{previous=null;});
  let loaded=0;
  function onload(){if(++loaded!==2)return;ready=true;state.ready=true;buildArmTexture();to=(random()*.5+.25)*-.35;start();}
  atlas.onload=wheel.onload=onload;
  atlas.onerror=wheel.onerror=()=>{state.error='Artwork missing. Keep the assets folder beside overlay.html.';console.error(state.error);};
  atlas.src='assets/husky-atlas.png';wheel.src='assets/rs50-wheel-paws.png';
})();
