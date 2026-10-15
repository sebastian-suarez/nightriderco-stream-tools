/* The full-body artwork stays joined; a continuous skin moves the relaxed pose. */
(() => {
 'use strict';
 let canvas=document.getElementById('mascot');
 const W=1280,H=1280,TAU=Math.PI*2,BEAT=500,LOOP=BEAT*16;
 const reduced=matchMedia('(prefers-reduced-motion: reduce)');
 const sprite=new Image();
 let ready=false,frames=0,frameId=null,manual=false,epoch=performance.now(),lastPose=null;
 const smooth=(a,b,x)=>{const t=Math.max(0,Math.min(1,(x-a)/(b-a)));return t*t*(3-2*t);};
 const rotate=(x,y,cx,cy,a)=>{const dx=x-cx,dy=y-cy;return [cx+dx*Math.cos(a)-dy*Math.sin(a),cy+dx*Math.sin(a)+dy*Math.cos(a)];};
 const COLS=32,ROWS=48,uv=[],indices=[];
 for(let y=0;y<=ROWS;y++)for(let x=0;x<=COLS;x++)uv.push(x/COLS,y/ROWS);
 for(let y=0;y<ROWS;y++)for(let x=0;x<COLS;x++){const a=y*(COLS+1)+x,b=a+1,c=a+COLS+1,d=c+1;indices.push(a,c,b,b,c,d);}
 const points=new Float32Array(uv.length);
 let gl=canvas.getContext('webgl',{alpha:true,antialias:true,premultipliedAlpha:false,preserveDrawingBuffer:true}),ctx=null,positionBuffer=null,texture=null;
 function fallback(){
  const copy=canvas.cloneNode();canvas.replaceWith(copy);canvas=copy;gl=null;ctx=canvas.getContext('2d');
 }
 function setupGL(){
  if(!gl){fallback();return;}
  function shader(type,source){const s=gl.createShader(type);gl.shaderSource(s,source);gl.compileShader(s);if(!gl.getShaderParameter(s,gl.COMPILE_STATUS))throw Error(gl.getShaderInfoLog(s));return s;}
  const p=gl.createProgram();
  gl.attachShader(p,shader(gl.VERTEX_SHADER,'attribute vec2 position; attribute vec2 texCoord; varying vec2 uv; void main(){gl_Position=vec4(position.x/300.0-1.0,1.0-position.y/300.0,0.0,1.0);uv=texCoord;}'));
  gl.attachShader(p,shader(gl.FRAGMENT_SHADER,'precision mediump float; varying vec2 uv; uniform sampler2D artwork; void main(){gl_FragColor=texture2D(artwork,uv);}'));
  gl.linkProgram(p);if(!gl.getProgramParameter(p,gl.LINK_STATUS))throw Error(gl.getProgramInfoLog(p));gl.useProgram(p);
  positionBuffer=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,positionBuffer);gl.bufferData(gl.ARRAY_BUFFER,points.byteLength,gl.DYNAMIC_DRAW);
  const pos=gl.getAttribLocation(p,'position');gl.enableVertexAttribArray(pos);gl.vertexAttribPointer(pos,2,gl.FLOAT,false,0,0);
  const t=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,t);gl.bufferData(gl.ARRAY_BUFFER,new Float32Array(uv),gl.STATIC_DRAW);
  const tc=gl.getAttribLocation(p,'texCoord');gl.enableVertexAttribArray(tc);gl.vertexAttribPointer(tc,2,gl.FLOAT,false,0,0);
  const idx=gl.createBuffer();gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER,idx);gl.bufferData(gl.ELEMENT_ARRAY_BUFFER,new Uint16Array(indices),gl.STATIC_DRAW);
  texture=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,texture);
  gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);
  gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL,false);gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,sprite);
  gl.enable(gl.BLEND);gl.blendFuncSeparate(gl.SRC_ALPHA,gl.ONE_MINUS_SRC_ALPHA,gl.ONE,gl.ONE_MINUS_SRC_ALPHA);
 }
 function poseAt(time){
  const t=Math.max(0,time)%LOOP,b=t/BEAT*TAU,m=reduced.matches?0:1;
  const sweep=.5-.5*Math.cos(TAU*t/LOOP),pump=.5-.5*Math.cos(2*TAU*t/LOOP);
  return {b,sway:Math.sin(b/2)*24*m,rock:Math.sin(b/2)*.037*m,bounce:(1-Math.cos(b))*12*m,
   leftArm:(Math.sin(b/2+.35)*(.28+.08*sweep)-.06*pump)*m,
   rightArm:(-Math.sin(b/2-.35)*(.28+.08*sweep)+.06*pump)*m,
   leftPawX:(Math.sin(b/2)*32*sweep-15*pump)*m,
   rightPawX:(Math.sin(b/2)*32*sweep+15*pump)*m,
   pawLift:Math.max(0,Math.sin(b))*22*pump*m,
   leftStep:Math.pow(Math.max(0,Math.sin(b/2)),2)*62*m,
   rightStep:Math.pow(Math.max(0,-Math.sin(b/2)),2)*62*m,
   legShift:Math.sin(b/2)*20*m,tail:Math.sin(b/4)*16*m,head:Math.sin(b/2+.6)*.032*m};
 }
 function deform(x,y,p){
  const ox=x,oy=y;
  // Short, round front paws swing from the sides of the puppy's tiny chest.
  const armY=smooth(710,820,oy)*(1-smooth(950,1080,oy));
  const wl=smooth(220,350,ox)*(1-smooth(490,610,ox))*armY;
  const wr=smooth(660,780,ox)*(1-smooth(935,1065,ox))*armY;
  const l=rotate(ox,oy,427,806,p.leftArm),r=rotate(ox,oy,843,806,p.rightArm);
  const hand=smooth(820,900,oy);
  x+=(l[0]-ox+p.leftPawX*hand)*wl+(r[0]-ox+p.rightPawX*hand)*wr;
  y+=(l[1]-oy-p.pawLift*hand)*wl+(r[1]-oy-p.pawLift*hand)*wr;
  // Oversized head remains a rigid shape, blending only through the neck ruff.
  const hw=1-smooth(695,815,oy),h=rotate(ox,oy,635,770,p.head);
  x+=(h[0]-ox)*hw;y+=(h[1]-oy)*hw;
  // Alternate knee lifts and small side steps, adapted from the T800 clip.
  const legs=smooth(1025,1140,oy),leftFoot=1-smooth(590,670,ox),rightFoot=1-leftFoot;
  y-=legs*(p.leftStep*leftFoot+p.rightStep*rightFoot);x+=legs*p.legShift;
  const tailWeight=smooth(890,1020,ox)*smooth(730,830,oy)*(1-smooth(1010,1110,oy));
  x+=p.tail*tailWeight;
  const upper=1-smooth(1020,1190,oy);x+=p.sway*upper;y-=p.bounce*upper;
  const body=rotate(x,y,635,1155,p.rock*upper);
  return [40+body[0]*(520/W),30+body[1]*(520/H)];
 }
 function draw(time){
  if(!ready)return;const p=poseAt(time);lastPose=p;
  for(let i=0;i<uv.length;i+=2){const v=deform(uv[i]*W,uv[i+1]*H,p);points[i]=v[0];points[i+1]=v[1];}
  if(gl){
   gl.viewport(0,0,canvas.width,canvas.height);gl.clearColor(0,0,0,0);gl.clear(gl.COLOR_BUFFER_BIT);
   gl.bindBuffer(gl.ARRAY_BUFFER,positionBuffer);gl.bufferSubData(gl.ARRAY_BUFFER,0,points);gl.drawElements(gl.TRIANGLES,indices.length,gl.UNSIGNED_SHORT,0);
  }else{
   ctx.setTransform(canvas.width/600,0,0,canvas.height/600,0,0);ctx.clearRect(0,0,600,600);
   ctx.save();ctx.translate(300+p.sway*.3,550-p.bounce*.35);ctx.rotate(p.rock);ctx.drawImage(sprite,-260,-520,520,520);ctx.restore();
  }
  frames++;
 }
 function frame(now){frameId=null;if(manual)return;draw(now-epoch);frameId=requestAnimationFrame(frame);}
 function start(){if(frameId!==null)cancelAnimationFrame(frameId);if(ready&&!manual)frameId=requestAnimationFrame(frame);}
 addEventListener('pagehide',()=>{if(frameId!==null)cancelAnimationFrame(frameId);frameId=null;});addEventListener('pageshow',start);
 document.addEventListener('visibilitychange',()=>{if(document.hidden){if(frameId!==null)cancelAnimationFrame(frameId);frameId=null;}else start();});
 addEventListener('obsSourceVisibleChanged',e=>{if(e.detail?.visible){epoch=performance.now();start();}});
 canvas.addEventListener('webglcontextlost',e=>{e.preventDefault();if(frameId!==null)cancelAnimationFrame(frameId);frameId=null;ready=false;});
 canvas.addEventListener('webglcontextrestored',()=>{setupGL();ready=true;start();});
 sprite.onload=()=>{try{setupGL();}catch(e){console.warn('Using the simple renderer:',e.message);fallback();}ready=true;start();};
 sprite.onerror=()=>console.error('Full-body artwork could not be loaded. Keep the assets folder with scene.html.');
 // Data-URL texture keeps OBS local-file mode self-contained and origin-safe.
 sprite.src=window.HUSKY_CHIBI_TEXTURE;
 window.HuskyDance={getState:()=>({ready,frames,loopMs:LOOP,pose:lastPose,version:'3-chibi-t800-inspired',renderer:gl?'webgl':'canvas',vertexCount:points.length/2}),renderAt(t){manual=true;if(frameId!==null)cancelAnimationFrame(frameId);frameId=null;draw(t);},play(){manual=false;epoch=performance.now();start();},inspectMesh:()=>Array.from(points)};
})();
