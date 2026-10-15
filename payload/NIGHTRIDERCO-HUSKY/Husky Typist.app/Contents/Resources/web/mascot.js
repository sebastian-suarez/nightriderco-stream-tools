/* NIGHTRIDERCO · local-only typing mascot. No key content is collected. */
(() => {
  'use strict';
  const canvas = document.getElementById('mascot');
  const ctx = canvas.getContext('2d');
  const atlas = new Image();
  const keyboard = new Image();
  const talking = new Image();
  const params = new URLSearchParams(location.search);
  const mode = ['live','demo','idle'].includes(params.get('mode')) ? params.get('mode') : 'live';
  const src = {
    body: [25,0,485,630], blink: [526,0,485,630],
    left: [103,625,361,380], right: [580,625,365,380]
  };
  const state = {mode, animationVersion:'1.8-articulated-scroll', connected:false, listening:false, micListening:false,
    micDB:-90,voiceLevel:0,mouthOpen:0,micStatus:'Microphone is off',voiceThreshold:-42,
    mouseListening:false,mouseX:.5,mouseY:.5,mouseActive:false,mouseDown:false,mouseClicks:0,trackBlend:0,scrolling:false,scrollDirection:[0,0],scrollGestures:0,armRig:null,
    pulses:0, renderedFrames:0};
  let ready = false, stopped = false, counter = null, session = null;
  let lastPoll = 0, lastTap = -10000, side = 0, queued = 0, previewQueued = 0;
  let leftAt = -10000, rightAt = -10000, frameTime = 0, nextBlink = 3700;
  let blinkUntil = 0, liveEnabled = true;
  let voiceTarget=0, voicePreviewUntil=0, mouthOpen=0, previousFrame=0;
  let speechPhase=0, wasSpeaking=false;
  let pollTimer=null,polling=false;
  const mouseArm=document.createElement('canvas');mouseArm.width=220;mouseArm.height=240;
  let mouseCounter=null,clickCounter=null,mouseAt=-10000,clickAt=-10000;
  let mouseX=.5,mouseY=.5,targetX=.5,targetY=.5,mouseDown=false,trackBlend=0;
  let mousePreviewUntil=0,scrollPreviewUntil=0;
  let scrollCounter=null,scrollAt=-10000,scrollX=0,scrollY=0,scrollPhase=0,scrollBlend=0;
  const clamp=v=>Math.max(0,Math.min(1,v));
  const smooth=v=>{v=clamp(v);return v*v*(3-2*v);};
  function sprite(name, x,y,w,h) { ctx.drawImage(atlas,...src[name],x,y,w,h); }
  function tap(now) {
    if (trackBlend<.35 && side++ % 2 === 0) leftAt = now; else rightAt = now;
    lastTap = now;
    state.pulses++;
  }
  function displacement(time, started) {
    const elapsed = time-started;
    return elapsed >= 0 && elapsed < 210 ? Math.sin(elapsed/210*Math.PI)*16 : 0;
  }
  function articulate(level,dt,time) {
    const speaking=level>0.05;
    let target=0;
    if(speaking) {
      if(!wasSpeaking) speechPhase=0;
      // Volume gates the animation; it must not hold one pose throughout a phrase.
      // A short closed interval between syllables keeps sustained speech animated.
      const cadence=3.1+level*.65+Math.sin(time/730)*.25+Math.sin(time/1930)*.18;
      speechPhase=(speechPhase+dt/1000*cadence)%1;
      let syllable=0;
      if(speechPhase<.22) syllable=(1-Math.cos(Math.PI*speechPhase/.22))/2;
      else if(speechPhase<.46) syllable=1;
      else if(speechPhase<.72) syllable=(1+Math.cos(Math.PI*(speechPhase-.46)/.26))/2;
      const opening=.65+.35*Math.sqrt(level);
      target=syllable*opening*(.96+.04*Math.sin(time/431));
    } else speechPhase=0;
    wasSpeaking=speaking;
    mouthOpen+=(target-mouthOpen)*(1-Math.exp(-dt/(target>mouthOpen?20:18)));
    if(!speaking && mouthOpen<.001) mouthOpen=0;
  }
  // Deform the existing lower muzzle, keeping its texture opaque. The jaw moves
  // down from the lip seam; the nose, upper muzzle and outer cheek fur stay fixed.
  function drawJaw(open,breath) {
    const left=263,right=340,bottom=344;
    const scaleX=src.body[2]/360,scaleY=src.body[3]/467;
    for(let x=left;x<right;x++) {
      const u=(x+.5-301.5)/38.5;
      const hinge=Math.pow(Math.max(0,1-u*u),.8);
      const seam=298+3*u*u;
      const drop=22*open*hinge;
      if(drop<.02)continue;
      const sourceX=src.body[0]+(x-120)*scaleX;
      // The mouth interior is revealed geometrically, without an opacity blend.
      ctx.drawImage(talking,sourceX,(298-24)*scaleY,scaleX,24*scaleY,
        x,seam+breath,1,drop+.5);
      // Lower lip, chin and fur travel with the jaw, tapering to the fixed neck.
      ctx.drawImage(atlas,sourceX,(seam-24)*scaleY,scaleX,(bottom-seam)*scaleY,
        x,seam+drop+breath,1,bottom-seam-drop);
    }
  }
  function buildMouseArm() {
    const c=mouseArm.getContext('2d');c.clearRect(0,0,220,240);
    // Straighten the original fur texture once. Each bone rotates this same
    // texture at a constant length; reaching never lengthens the arm.
    c.save();c.translate(90,30);c.rotate(33*Math.PI/180);
    c.drawImage(atlas,...src.left,104-145,326-350,142,150);c.restore();
  }
  const boneLength=[58,72];
  function solveArm(shoulder,paw) {
    const [upper,lower]=boneLength,dx=paw[0]-shoulder[0],dy=paw[1]-shoulder[1];
    const distance=Math.max(Math.abs(upper-lower)+.01,Math.min(upper+lower-.01,Math.hypot(dx,dy)));
    const direction=Math.atan2(dy,dx);
    const bend=Math.acos(Math.max(-1,Math.min(1,(upper*upper+distance*distance-lower*lower)/(2*upper*distance))));
    const angle=direction+bend;
    const elbow=[shoulder[0]+Math.cos(angle)*upper,shoulder[1]+Math.sin(angle)*upper];
    const end=[shoulder[0]+Math.cos(direction)*distance,shoulder[1]+Math.sin(direction)*distance];
    return {shoulder,elbow,paw:end,upperAngle:angle-Math.PI/2,lowerAngle:Math.atan2(end[1]-elbow[1],end[0]-elbow[0])-Math.PI/2};
  }
  function texturedTriangle(source,dest) {
    const [s0,s1,s2]=source,[p0,p1,p2]=dest;
    const ux=s1[0]-s0[0],uy=s1[1]-s0[1],vx=s2[0]-s0[0],vy=s2[1]-s0[1],det=ux*vy-uy*vx;
    const a=((p1[0]-p0[0])*vy-(p2[0]-p0[0])*uy)/det;
    const b=((p1[1]-p0[1])*vy-(p2[1]-p0[1])*uy)/det;
    const c=((p2[0]-p0[0])*ux-(p1[0]-p0[0])*vx)/det;
    const d=((p2[1]-p0[1])*ux-(p1[1]-p0[1])*vx)/det;
    ctx.save();ctx.beginPath();
    const orientation=Math.sign((p1[0]-p0[0])*(p2[1]-p0[1])-(p1[1]-p0[1])*(p2[0]-p0[0]));
    const normals=dest.map((p,i)=>{const q=dest[(i+1)%3],length=Math.hypot(q[0]-p[0],q[1]-p[1])||1;return [(q[1]-p[1])/length*orientation,-(q[0]-p[0])/length*orientation];});
    for(let i=0;i<3;i++){
      const p=dest[i],a=normals[(i+2)%3],b=normals[i],scale=.65/Math.max(.08,1+a[0]*b[0]+a[1]*b[1]);
      const x=p[0]+(a[0]+b[0])*scale,y=p[1]+(a[1]+b[1])*scale;
      if(i===0)ctx.moveTo(x,y);else ctx.lineTo(x,y);
    }
    ctx.closePath();ctx.clip();ctx.transform(a,b,c,d,p0[0]-a*s0[0]-c*s0[1],p0[1]-b*s0[0]-d*s0[1]);
    ctx.drawImage(mouseArm,0,0);ctx.restore();
  }
  function drawArm(pose,reach,mirrored=false) {
    const rotate=(x,y,angle,origin)=>[origin[0]+x*Math.cos(angle)-y*Math.sin(angle),origin[1]+x*Math.sin(angle)+y*Math.cos(angle)];
    const wrist=rotate(0,49,pose.lowerAngle,pose.elbow);
    const handAngle=pose.lowerAngle*(1-reach*.82)+Math.sin(scrollPhase*Math.PI*2)*.055*scrollBlend*reach;
    function warp(x,y) {
      const offset=x-90;
      const upper=rotate(offset,(y-30)*58/60,pose.upperAngle,pose.shoulder);
      const lower=rotate(offset,(y-90)*49/42,pose.lowerAngle,pose.elbow);
      const hand=rotate(offset,y-132,handAngle,wrist);
      const elbowWeight=smooth((y-82)/16),wristWeight=smooth((y-126)/12);
      const arm=upper.map((v,i)=>v+(lower[i]-v)*elbowWeight);
      const result=arm.map((v,i)=>v+(hand[i]-v)*wristWeight);
      return mirrored?[600-result[0],result[1]]:result;
    }
    const rows=[0,82,86,90,94,98,126,130,134,138,195],columns=[20,65,115,182];
    for(let iy=0;iy<rows.length-1;iy++)for(let ix=0;ix<columns.length-1;ix++) {
      const x=columns[ix],nextX=columns[ix+1],y=rows[iy],nextY=rows[iy+1];
      const a=[x,y],b=[nextX,y],c=[nextX,nextY],d=[x,nextY];
      const da=warp(...a),db=warp(...b),dc=warp(...c),dd=warp(...d);
      texturedTriangle([a,b,c],[da,db,dc]);texturedTriangle([a,c,d],[da,dc,dd]);
    }
  }
  function trackpadPath(offset=0) {
    ctx.beginPath();ctx.moveTo(259,466+offset);ctx.lineTo(342,466+offset);
    ctx.quadraticCurveTo(347,466+offset,349,471+offset);ctx.lineTo(366,524+offset);
    ctx.quadraticCurveTo(368,531+offset,360,532+offset);ctx.lineTo(241,532+offset);
    ctx.quadraticCurveTo(233,531+offset,236,524+offset);ctx.lineTo(253,471+offset);
    ctx.quadraticCurveTo(254,466+offset,259,466+offset);ctx.closePath();
  }
  function drawTrackpad(time) {
    ctx.save();
    ctx.shadowColor='rgba(0,0,0,.45)';ctx.shadowBlur=9;ctx.shadowOffsetY=5;
    trackpadPath(5);ctx.fillStyle='#64757e';ctx.fill();ctx.shadowColor='transparent';
    trackpadPath();const glass=ctx.createLinearGradient(250,466,345,534);
    glass.addColorStop(0,'#f3f5f6');glass.addColorStop(.45,'#dce3e7');glass.addColorStop(1,'#b6c2ca');
    ctx.fillStyle=glass;ctx.fill();ctx.strokeStyle='#edf5f8';ctx.lineWidth=1;ctx.stroke();
    ctx.beginPath();ctx.moveTo(243,532);ctx.lineTo(359,532);ctx.strokeStyle='#92a8b5';ctx.stroke();
    if(scrollBlend>.04) {
      ctx.save();trackpadPath();ctx.clip();ctx.globalAlpha=scrollBlend*.38;
      ctx.strokeStyle='#58cbea';ctx.lineWidth=2;ctx.lineCap='round';
      for(const offset of [-9,9]) {
        const x=300+(mouseX-.5)*28+offset,y=516+Math.sin(scrollPhase*Math.PI*2)*4;
        ctx.beginPath();ctx.moveTo(x-scrollX*4,y+scrollY*5);ctx.lineTo(x+scrollX*4,y-scrollY*5);ctx.stroke();
      }
      ctx.restore();
    }
    // A small contact ripple makes a click readable at stream-overlay scale.
    const clickAge=time-clickAt;
    if(clickAge>=0&&clickAge<230) {
      ctx.save();trackpadPath();ctx.clip();ctx.globalAlpha=(1-clickAge/230)*.65;
      ctx.strokeStyle='#65d7fa';ctx.lineWidth=2;
      ctx.beginPath();ctx.ellipse(301+(mouseX-.5)*38,500+(mouseY-.5)*22,8+clickAge*.045,4+clickAge*.022,0,0,Math.PI*2);ctx.stroke();ctx.restore();
    }
    ctx.restore();
  }
  function drawArticulatedArms(time,leftTap,rightTap) {
    const reach=smooth(trackBlend);
    const press=mouseDown?3:Math.max(0,1-(time-clickAt)/160)*3;
    // Lift through an arc while the shoulder rolls inward and the elbow folds.
    const lift=Math.sin(Math.PI*reach)*26;
    const shoulder=[210+34*reach,365+23*reach];
    const stroke=Math.sin(scrollPhase*Math.PI*2)*7*scrollBlend;
    const release=Math.max(0,Math.cos(scrollPhase*Math.PI*2))*2.5*scrollBlend;
    const pad=[300+(mouseX-.5)*28+scrollX*stroke,486+(mouseY-.5)*14-scrollY*stroke+press-release];
    const paw=[126+(pad[0]-126)*reach,455+(pad[1]-455)*reach-lift+leftTap*.32*(1-reach)];
    const left=solveArm(shoulder,paw);
    const right=solveArm([210,365],[126,455+rightTap*.32]);
    drawArm(right,0,true);drawArm(left,reach);
    state.armRig={shoulder:left.shoulder,elbow:left.elbow,paw:left.paw,upperLength:Math.hypot(left.elbow[0]-left.shoulder[0],left.elbow[1]-left.shoulder[1]),lowerLength:Math.hypot(left.paw[0]-left.elbow[0],left.paw[1]-left.elbow[1])};
  }
  function updatePointer(time,dt) {
    const demoMouse=mode==='demo'&&time%8000>=4000&&time%8000<6900;
    if(demoMouse||time<mousePreviewUntil) {
      targetX=.5+Math.sin(time/510)*.46;targetY=.5+Math.cos(time/680)*.4;
      mouseAt=time;
      const down=time%1100>870&&time%1100<960;
      if(down&&!mouseDown){clickAt=time;state.mouseClicks++;}mouseDown=down;
    } else if(mode!=='live') mouseDown=false;
    const demoScroll=mode==='demo'&&time%8000>=5500&&time%8000<6500;
    if(demoScroll||time<scrollPreviewUntil){scrollAt=time;mouseAt=time;scrollY=1;scrollX=0;}
    const scrollFresh=time-scrollAt<190;
    scrollBlend+=((scrollFresh?1:0)-scrollBlend)*(1-Math.exp(-dt/(scrollFresh?45:110)));
    if(scrollBlend>.005)scrollPhase=(scrollPhase+dt/1000*3.2)%1;
    state.scrolling=scrollFresh;state.scrollDirection=[scrollX,scrollY];
    const fresh=mode!=='live'||time<mousePreviewUntil||time<scrollPreviewUntil||time-lastPoll<700;
    const active=fresh&&(mouseDown||time-mouseAt<1100)&&mouseAt>lastTap&&time-lastTap>220;
    trackBlend+=((active?1:0)-trackBlend)*(1-Math.exp(-dt/(active?170:140)));
    mouseX+=(targetX-mouseX)*(1-Math.exp(-dt/65));mouseY+=(targetY-mouseY)*(1-Math.exp(-dt/65));
    state.mouseX=mouseX;state.mouseY=mouseY;state.mouseActive=active;state.mouseDown=mouseDown&&fresh;state.trackBlend=trackBlend;
  }
  function draw(time) {
    ctx.clearRect(0,0,600,600);
    if (!ready) return;
    const active = time-lastTap < 350;
    const breath = Math.sin(time/1000*1.65)*1.1;
    // Only the small eye region changes during a blink; the face never jumps.
    sprite('body',120,24+breath,360,467);
    if(time >= nextBlink) {blinkUntil=time+125;nextBlink=time+4400+(Math.sin(time)*700);}
    if(time<blinkUntil) {
      ctx.save();ctx.beginPath();ctx.rect(212,177+breath,191,48);ctx.clip();
      sprite('blink',120,24+breath,360,467);ctx.restore();
    }
    if(mouthOpen>0.001) drawJaw(mouthOpen,breath);
    // The wolf is the typist: wrist supports are away from the camera, beside him.
    // The rear number-row edges face the viewer in the foreground.
    ctx.drawImage(keyboard,20,160,870,570,19,396,258,169);
    ctx.drawImage(keyboard,890,160,870,570,323,396,258,169);
    drawTrackpad(time);
    // Arms overlap the chest and keyboard; smooth motion is interpolated per frame.
    const l=displacement(time,leftAt), r=displacement(time,rightAt);
    drawArticulatedArms(time,l,r);
    if(active) {
      ctx.save();ctx.globalAlpha=.35*Math.max(l,r)/16;ctx.fillStyle='#74DFFF';
      ctx.beginPath();ctx.ellipse(l>r?126:474,480,18,2,0,0,Math.PI*2);ctx.fill();ctx.restore();
    }
  }
  function frame(time) {
    if(stopped) return;
    frameTime=time;
    const dt=Math.max(1,Math.min(80,time-(previousFrame||time-16.7)));previousFrame=time;
    let level=mode==='demo' && time%6000>900 && time%6000<3550
      ? .6+Math.sin(time/260)*.15 : voiceTarget;
    if(time<voicePreviewUntil)level=.7+Math.sin(time/230)*.12;
    if(mode==='live' && time>=voicePreviewUntil && time-lastPoll>700)level=0;
    articulate(level,dt,time);
    state.voiceLevel=level;state.mouthOpen=mouthOpen;
    if(mode==='demo' && time-lastTap>125 && time%8000<3500) tap(time);
    if(previewQueued>0 && time-lastTap>=65) {previewQueued--;tap(time);}
    else if(queued>0 && time-lastTap>=65) {queued--;tap(time);}
    updatePointer(time,dt);
    draw(time);state.renderedFrames++;
    if(state.renderedFrames%10===0 && typeof parent!=='undefined' && parent!==window)
      parent.postMessage({type:'husky-state',state:{...state}},location.protocol==='file:'?'*':location.origin);
    requestAnimationFrame(frame);
  }
  async function poll() {
    if(stopped || mode!=='live' || polling) return;
    if(!liveEnabled) {pollTimer=setTimeout(poll,150);return;}
    polling=true;
    const controller=new AbortController();const timeout=setTimeout(()=>controller.abort(),1600);
    try {
      const response=await fetch('/state',{cache:'no-store',signal:controller.signal});
      if(!response.ok) throw new Error('Helper unavailable');
      const data=await response.json();
      if(data.app!=='nightriderco-husky' || !Number.isSafeInteger(data.counter)) throw new Error('Wrong helper');
      const now=performance.now();
      // Reconnects establish a fresh baseline: old typing never replays.
      if(session===data.session && counter!==null && now-lastPoll<700 && data.counter>=counter && data.listening && data.paused!==true)
        queued=Math.min(4,queued+data.counter-counter);
      const pointerReady=data.mouseListening===true&&data.paused!==true;
      const sameSession=session===data.session&&now-lastPoll<700;
      if(!sameSession){mouseAt=-10000;clickAt=-10000;scrollAt=-10000;scrollBlend=0;}
      if(pointerReady&&Number.isFinite(data.mouseX)&&Number.isFinite(data.mouseY)) {
        targetX=clamp(data.mouseX);targetY=clamp(data.mouseY);
        if(sameSession&&mouseCounter!==null&&Number.isSafeInteger(data.mouseCounter)&&data.mouseCounter>mouseCounter)mouseAt=now;
        if(sameSession&&clickCounter!==null&&Number.isSafeInteger(data.mouseClicks)&&data.mouseClicks>clickCounter){clickAt=now;mouseAt=now;state.mouseClicks+=Math.min(4,data.mouseClicks-clickCounter);}
      }
      if(pointerReady&&sameSession&&scrollCounter!==null&&Number.isSafeInteger(data.scrollCounter)&&data.scrollCounter>scrollCounter) {
        scrollX=Number.isFinite(data.scrollX)?Math.sign(data.scrollX):0;
        scrollY=Number.isFinite(data.scrollY)?Math.sign(data.scrollY):0;
        if(scrollX||scrollY){scrollAt=now;mouseAt=now;state.scrollGestures++;}
      }
      scrollCounter=Number.isSafeInteger(data.scrollCounter)?data.scrollCounter:null;
      mouseDown=pointerReady&&sameSession&&data.mouseDown===true;
      state.mouseListening=pointerReady;
      mouseCounter=Number.isSafeInteger(data.mouseCounter)?data.mouseCounter:null;
      clickCounter=Number.isSafeInteger(data.mouseClicks)?data.mouseClicks:null;
      if(!pointerReady){mouseAt=-10000;mouseDown=false;scrollAt=-10000;scrollBlend=0;}
      counter=data.counter;session=data.session;lastPoll=now;
      state.connected=true;state.listening=data.listening===true && data.paused!==true;
      state.micListening=data.micListening===true && data.paused!==true;
      state.micDB=Number.isFinite(data.micDB)?Math.max(-90,Math.min(0,data.micDB)):-90;
      state.voiceThreshold=Number.isFinite(data.voiceThreshold)?data.voiceThreshold:-42;
      state.micStatus=typeof data.micStatus==='string'?data.micStatus:'Microphone is off';
      voiceTarget=state.micListening && Number.isFinite(data.voiceLevel)?Math.max(0,Math.min(1,data.voiceLevel)):0;
      if(!state.listening) queued=0;
    } catch(_) {state.connected=false;state.listening=false;state.micListening=false;state.micDB=-90;voiceTarget=0;counter=null;queued=0;mouseAt=-10000;mouseDown=false;state.mouseListening=false;mouseCounter=null;clickCounter=null;scrollCounter=null;scrollAt=-10000;scrollBlend=0;}
    finally {clearTimeout(timeout);polling=false;clearTimeout(pollTimer);if(!stopped)pollTimer=setTimeout(poll,state.connected?40:1200);}
  }
  // Preview controls affect artwork only. They cannot generate operating-system input.
  addEventListener('message',event=>{
    if(event.source!==parent || (location.protocol!=='file:' && event.origin!==location.origin)) return;
    if(event.data?.type==='husky-preview-tap') {previewQueued=Math.min(4,previewQueued+1);}
    if(event.data?.type==='husky-preview-mouse') {mousePreviewUntil=performance.now()+3000;}
    if(event.data?.type==='husky-preview-scroll') {scrollPreviewUntil=performance.now()+2200;}
    if(event.data?.type==='husky-preview-voice') {voicePreviewUntil=performance.now()+2000;}
    if(event.data?.type==='husky-live-enabled') {liveEnabled=event.data.enabled===true;counter=null;queued=0;voiceTarget=0;}
  });
  addEventListener('pagehide',()=>{stopped=true;clearTimeout(pollTimer);});
  addEventListener('pageshow',()=>{
    if(!stopped)return;
    stopped=false;counter=null;queued=0;voiceTarget=0;lastPoll=0;previousFrame=0;
    if(ready){requestAnimationFrame(frame);poll();}
  });
  window.HuskyMascot={getState:()=>({...state,queued}),previewTap:()=>{previewQueued=Math.min(4,previewQueued+1);},previewVoice:()=>{voicePreviewUntil=performance.now()+2000;},previewMouse:()=>{mousePreviewUntil=performance.now()+3000;},previewScroll:()=>{scrollPreviewUntil=performance.now()+2200;},renderAt:time=>draw(time)};
  let loaded=0;
  const onImageLoaded=()=>{if(++loaded===3){ready=true;buildMouseArm();requestAnimationFrame(frame);poll();}};
  atlas.onload=onImageLoaded;keyboard.onload=onImageLoaded;talking.onload=onImageLoaded;
  atlas.onerror=keyboard.onerror=talking.onerror=()=>console.error('Mascot artwork could not be loaded. Keep the app bundle intact.');
  atlas.src='husky-atlas.png';
  keyboard.src='keyboard-facing-wolf.png';
  talking.src='wolf-speaking.png';
})();
