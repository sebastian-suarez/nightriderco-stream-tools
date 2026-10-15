import http from 'node:http';
import { readFile, writeFile, mkdir, rename, unlink, access } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { OBS } from './obs-client.mjs';
import { ResolutionEngine } from './engine.mjs';
const root = path.dirname(fileURLToPath(import.meta.url));
const port = Number(process.env.NRC_RESOLUTION_PORT || 17643);
const host = `127.0.0.1:${port}`, origin = `http://${host}`;
const runtime = path.join(root,'runtime');
await mkdir(runtime,{recursive:true,mode:0o700});
const stateFile = path.join(runtime,'last-switch.json');
const store = {
 async read() { try {return JSON.parse(await readFile(stateFile,'utf8'));} catch(e) {if(e.code==='ENOENT')return null;throw e;} },
 async write(value) {
  const text = JSON.stringify(value,null,2);
  if(value.phase==='pending') {
   const backup=path.join(runtime,'snapshot-'+value.at.replaceAll(':','-')+'.json');
   try {await access(backup);}catch {await writeFile(backup,text,{mode:0o600,flag:'wx'});}
  }
  await writeFile(stateFile+'.tmp',text,{mode:0o600});await rename(stateFile+'.tmp',stateFile);
 },
 async clear() {await unlink(stateFile).catch(e=>{if(e.code!=='ENOENT')throw e;});}
};
const obs=new OBS(), engine=new ResolutionEngine(obs,store);
const assets={'/':['dock.html','text/html; charset=utf-8'],'/dock.css':['dock.css','text/css'],'/dock.js':['dock.js','text/javascript']};
function send(res,code,value,type='application/json') {
 const body=typeof value==='string'||Buffer.isBuffer(value)?value:JSON.stringify(value);
 res.writeHead(code,{'Content-Type':type,'Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer','X-Frame-Options':'DENY',
  'Content-Security-Policy':"default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"});res.end(body);
}
const server=http.createServer(async(req,res)=>{
 try {
  if(req.headers.host!==host)return send(res,403,{error:'Open the local dock directly in OBS.'});
  const url=new URL(req.url,origin);
  // Permit only the public top-level page to open from the local startup page.
  const publicDocumentNavigation=req.method==='GET' && url.pathname==='/' && req.headers['sec-fetch-mode']==='navigate' && req.headers['sec-fetch-dest']==='document';
  if(req.headers['sec-fetch-site']==='cross-site' && !publicDocumentNavigation)return send(res,403,{error:'Open the local dock directly in OBS.'});
  if(req.method==='GET' && assets[url.pathname]) {const [file,type]=assets[url.pathname];return send(res,200,await readFile(path.join(root,file)),type);}
  if(req.method==='GET' && url.pathname==='/health')return send(res,200,{service:'nrc-resolution-dock',version:1});
  if(req.method==='GET' && url.pathname==='/state') {
   try{return send(res,200,await engine.inspect());}catch(e){return send(res,200,{connected:false,busy:engine.busy,message:e.message});}
  }
  if(req.method==='POST' && ['/switch','/undo'].includes(url.pathname)) {
   if(req.headers.origin!==origin || req.headers['x-nrc-resolution']!=='1' || req.headers['content-type']!=='application/json')return send(res,403,{error:'Same-origin dock request required.'});
   let body='';for await(const chunk of req){body+=chunk;if(Buffer.byteLength(body)>1024)return send(res,413,{error:'Request too large.'});}
   let data;try{data=JSON.parse(body);}catch{return send(res,400,{error:'Invalid request.'});}
   if(!data || typeof data!=='object')return send(res,400,{error:'Invalid request.'});
   return send(res,200,url.pathname==='/switch'?await engine.switch(data.mode):await engine.undo());
  }
  send(res,404,{error:'Not found.'});
 }catch(error){send(res,409,{error:error.message});}
});
server.requestTimeout=15000;server.headersTimeout=10000;
server.on('error',error=>{if(error.code==='EADDRINUSE')process.exit(0);console.error(error.message);process.exit(1);});
server.listen(port,'127.0.0.1',()=>console.log(`Resolution dock ready at ${origin}`));
