'use strict';
class MockContext{
 constructor(canvas){this.canvas=canvas;this.operations=[];this.stack=[];this.fillStyle='#000000';this.strokeStyle='#000000';this.globalAlpha=1;this.globalCompositeOperation='source-over';this.transform=[1,0,0,1,0,0];}
 record(name,args=[]){this.operations.push({name,args:[...args],fillStyle:this.fillStyle,strokeStyle:this.strokeStyle,globalAlpha:this.globalAlpha,composite:this.globalCompositeOperation,transform:[...this.transform]});}
 save(){this.stack.push({fillStyle:this.fillStyle,strokeStyle:this.strokeStyle,globalAlpha:this.globalAlpha,globalCompositeOperation:this.globalCompositeOperation,transform:[...this.transform]});this.record('save');}
 restore(){Object.assign(this,this.stack.pop());this.record('restore');}
 setTransform(...args){this.transform=args.length===1?[args[0].a,args[0].b,args[0].c,args[0].d,args[0].e,args[0].f]:args;this.record('setTransform',args);}
 resetTransform(){this.transform=[1,0,0,1,0,0];this.record('resetTransform');}
 scale(x,y){this.transform[0]*=x;this.transform[3]*=y;this.record('scale',[x,y]);}
 translate(x,y){this.transform[4]+=x;this.transform[5]+=y;this.record('translate',[x,y]);}
 rotate(t){this.record('rotate',[t]);}
 createLinearGradient(...args){const value={kind:'linear-gradient',args,stops:[],addColorStop(at,color){this.stops.push([at,color]);}};this.record('createLinearGradient',args);return value;}
 createRadialGradient(...args){const value=this.createLinearGradient(...args);value.kind='radial-gradient';return value;}
 measureText(text){return{width:text.length*20};}
}
for(const name of ['fillRect','clearRect','strokeRect','beginPath','moveTo','lineTo','closePath','fill','stroke','clip','rect','arc','fillText','strokeText','drawImage','roundRect'])MockContext.prototype[name]=function(...args){this.record(name,args);};
function makeCanvas(width=2560,height=1440){const canvas={width,height,style:{},calls:[]};canvas.ctx=new MockContext(canvas);canvas.getContext=(type,options)=>{canvas.calls.push({type,options});return canvas.ctx;};return canvas;}
module.exports={MockContext,makeCanvas};
