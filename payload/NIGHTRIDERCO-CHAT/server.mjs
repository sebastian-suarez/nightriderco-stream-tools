import http from 'node:http';
import { readFile, realpath } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve, extname, sep } from 'node:path';
import { spawn } from 'node:child_process';
import { KickProvider } from './lib/kick-realtime.js';

const publicRoot = resolve(fileURLToPath(new URL('./public/', import.meta.url)));
const mime = {'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.svg':'image/svg+xml','.png':'image/png','.webp':'image/webp','.ico':'image/x-icon','.json':'application/json; charset=utf-8'};
const cache = new Map([['nightriderco', {slug:'nightriderco',roomId:132926621,channelId:133224609,expires:Date.now()+3600_000}]]);
const inflight = new Map();
export function normalizeSlug(input) {
  return typeof input === 'string' && /^[a-zA-Z0-9_-]{1,60}$/.test(input) ? input.toLowerCase() : null;
}
export async function resolveChannel(slug, fetcher = fetch) {
  const known = cache.get(slug);
  if (known && known.expires > Date.now()) return {slug:known.slug,roomId:known.roomId,channelId:known.channelId};
  if (inflight.has(slug)) return inflight.get(slug);
  const task = (async () => {
    const response = await fetcher(`https://kick.com/api/v2/channels/${encodeURIComponent(slug)}`, {
      headers:{accept:'application/json','user-agent':'Mozilla/5.0 NRCChat/1.0'},
      signal:AbortSignal.timeout(12_000), redirect:'error'
    });
    if (!response.ok) throw new Error(response.status === 404 ? 'Channel not found. Check the channel name.' : 'Kick could not resolve this channel. Enter its numeric chat-room ID in Advanced settings.');
    const data = await response.json();
    const roomId = Number(data?.chatroom?.id);
    const channelId = Number(data?.id);
    if (!Number.isSafeInteger(roomId) || roomId < 1) throw new Error('Kick returned no valid chat room for this channel.');
    if (!Number.isSafeInteger(channelId) || channelId < 1) throw new Error('Kick returned no valid channel ID.');
    cache.set(slug, {slug,roomId,channelId,expires:Date.now()+3600_000});
    if (cache.size > 100) cache.delete(cache.keys().next().value);
    return {slug,roomId,channelId};
  })();
  inflight.set(slug,task);
  try {return await task;} finally {inflight.delete(slug);}
}
export function validClientId(input) {return typeof input === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(input);}
export function validChannelId(input) {return (typeof input==='string' || typeof input==='number') && /^\d{1,16}$/.test(String(input)) && Number.isSafeInteger(Number(input)) && Number(input)>0;}
async function kickPost(pathname,body,fetcher) {
  const response=await fetcher(`https://web.kick.com${pathname}`,{
    method:'POST',headers:{'content-type':'application/json',accept:'application/json',referer:'https://kick.com/','x-app-platform':'web'},
    body:JSON.stringify(body),signal:AbortSignal.timeout(12_000),redirect:'error'
  });
  if(!response.ok) throw new Error(`Kick connection service returned ${response.status}. Try reconnecting in a moment.`);
  return response.json();
}
export async function getAnonymousToken(clientId, fetcher=fetch) {
  if(!validClientId(clientId)) throw new Error('Invalid client ID.');
  const data=await kickPost('/api/v1/realtime/auth/connection',{client_id:clientId},fetcher);
  const token=data?.data?.token;
  if(typeof token!=='string' || token.length<10 || token.length>20_000) throw new Error('Kick did not return an anonymous connection token.');
  return {token};
}
export async function getConnection(clientId,channelId,fetcher=fetch) {
  if(!validClientId(clientId) || (channelId!=null && !validChannelId(channelId))) throw new Error('Invalid connection request.');
  const pathname=channelId==null ? '/api/v1/realtime/connection' : `/api/v1/realtime/channels/${Number(channelId)}/chat/connection`;
  const descriptor=await kickPost(pathname,{client:{id:clientId,type:'web'},capabilities:{accepted_providers:[{provider:'centrifugo'}]}},fetcher);
  const connections=descriptor?.data?.connections;
  const endpoint=Array.isArray(connections) ? connections.find(connection=>connection?.provider==='centrifugo')?.credentials?.url : null;
  let url;
  try {url=new URL(endpoint);} catch {throw new Error('Kick returned no supported chat transport.');}
  if(url.protocol!=='wss:' || !/^realtime\.[a-z0-9-]+\.platform\.kick\.com$/.test(url.hostname) || url.pathname!=='/connection/websocket' || url.username || url.password || url.port || url.search || url.hash) throw new Error('Kick returned an unrecognized chat transport. The adapter needs an update.');
  return {url:url.href,...await getAnonymousToken(clientId,fetcher)};
}
export function createServer() {
  let activeStreams=0;
  return http.createServer(async (req,res) => {
    const host = req.headers.host || '';
    if (!/^(127\.0\.0\.1|localhost)(:\d+)?$/.test(host)) {res.writeHead(403);res.end('Local access only');return;}
    const origin = req.headers.origin;
    if (origin && origin !== `http://${host}`) {res.writeHead(403);res.end('Local access only');return;}
    if (req.method !== 'GET' && req.method !== 'HEAD') {res.writeHead(405,{Allow:'GET, HEAD'});res.end();return;}
    res.setHeader('X-Content-Type-Options','nosniff');
    res.setHeader('Referrer-Policy','no-referrer');
    res.setHeader('Cache-Control','no-store');
    res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' https://files.kick.com https://emotes.kick.com data:; connect-src 'self'; frame-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'self'");
    let url;
    try {url = new URL(req.url,`http://${host}`);} catch {res.writeHead(400);res.end('Invalid request');return;}
    if(url.pathname==='/api/kick/events') {
      const slug=normalizeSlug(url.searchParams.get('slug'));
      const room=url.searchParams.get('room');
      if(!slug || (room && !validChannelId(room))) {res.writeHead(400);res.end('Invalid chat settings.');return;}
      if(req.method==='HEAD') {res.writeHead(200,{'Content-Type':'text/event-stream'});res.end();return;}
      if(activeStreams>=12) {res.writeHead(429);res.end('Too many local chat connections. Close unused preview tabs.');return;}
      activeStreams++;
      res.writeHead(200,{'Content-Type':'text/event-stream; charset=utf-8','Connection':'keep-alive','X-Accel-Buffering':'no'});
      res.flushHeaders();
      let closed=false;
      const send=(type,value)=>{
        if(closed || res.destroyed) return;
        // A hidden OBS source must not accumulate an unbounded response buffer.
        if(res.writableLength>1_048_576) {res.destroy();return;}
        res.write(`data: ${JSON.stringify({type,value})}\n\n`);
      };
      const provider=new KickProvider({channel:slug,roomId:room || null,
        fetchImpl:async (pathname)=>{
          const local=new URL(pathname,'http://127.0.0.1');
          try {
            let data;
            if(local.pathname==='/api/kick/channel') data=await resolveChannel(normalizeSlug(local.searchParams.get('slug')));
            else if(local.pathname==='/api/kick/connection') data=await getConnection(local.searchParams.get('clientId'),local.searchParams.get('channelId'));
            else if(local.pathname==='/api/kick/token') data=await getAnonymousToken(local.searchParams.get('clientId'));
            else return {ok:false,status:404,json:async()=>({error:'Unsupported local connection request.'})};
            return {ok:true,status:200,json:async()=>data};
          } catch(error) {return {ok:false,status:502,json:async()=>({error:error.message})};}
        },
        onMessage:value=>send('message',value),onDelete:value=>send('delete',value),onBan:value=>send('ban',value),onClear:()=>send('clear'),onStatus:value=>send('status',value)
      });
      const keepalive=setInterval(()=>{if(!closed)res.write(': keepalive\n\n');},15000);
      const cleanup=()=>{if(closed)return;closed=true;activeStreams--;clearInterval(keepalive);provider.disconnect();};
      res.on('close',cleanup);
      provider.connect().catch(()=>send('status',{state:'error',detail:'Could not open Kick chat. Try reconnecting.',roomId:room}));
      return;
    }
    if(url.pathname==='/api/kick/connection' || url.pathname==='/api/kick/token') {
      res.setHeader('Content-Type','application/json; charset=utf-8');
      const clientId=url.searchParams.get('clientId');
      const channelId=url.searchParams.get('channelId');
      if(!validClientId(clientId) || (channelId!==null && !validChannelId(channelId))) {res.writeHead(400);res.end(JSON.stringify({error:'Invalid connection request.'}));return;}
      try {res.end(JSON.stringify(url.pathname.endsWith('/token') ? await getAnonymousToken(clientId) : await getConnection(clientId,channelId)));}
      catch(error) {res.writeHead(502);res.end(JSON.stringify({error:error.name==='TimeoutError' ? 'Kick took too long to respond. Try reconnecting.' : error.message}));}
      return;
    }
    if (url.pathname === '/api/kick/channel') {
      res.setHeader('Content-Type','application/json; charset=utf-8');
      const slug = normalizeSlug(url.searchParams.get('slug'));
      if (!slug) {res.writeHead(400);res.end(JSON.stringify({error:'Enter a valid Kick channel name (letters, numbers, underscores or dashes).'}));return;}
      try {res.end(JSON.stringify(await resolveChannel(slug)));}
      catch(error) {res.writeHead(502);res.end(JSON.stringify({error: error.name === 'TimeoutError' ? 'Kick took too long to respond. Use the chat-room ID in Advanced settings.' : error.message}));}
      return;
    }
    let pathname;
    try {pathname = decodeURIComponent(url.pathname);} catch {res.writeHead(400);res.end();return;}
    const filename = resolve(publicRoot, '.'+(pathname==='/'?'/index.html':pathname));
    if (!filename.startsWith(publicRoot+sep) || !mime[extname(filename)]) {res.writeHead(404);res.end('Not found');return;}
    try {
      const canonical = await realpath(filename);
      if (!canonical.startsWith(publicRoot+sep)) {res.writeHead(404);res.end('Not found');return;}
      const content = await readFile(canonical);
      res.setHeader('Content-Type',mime[extname(filename)]);
      res.setHeader('Content-Length',content.byteLength);
      res.end(req.method === 'HEAD' ? undefined : content);
    } catch {res.writeHead(404);res.end('Not found');}
  });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const port = Number(process.env.NRC_CHAT_PORT || 3377);
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('NRC_CHAT_PORT must be between 1024 and 65535.');
  const server = createServer();
  server.on('error',error => {
    console.error(error.code === 'EADDRINUSE' ? `Port ${port} is already in use. If chat is already running, open http://127.0.0.1:${port}. Otherwise close the other app or choose NRC_CHAT_PORT.` : error.message);
    process.exitCode=1;
  });
  server.listen(port,'127.0.0.1',() => {
    const address = `http://127.0.0.1:${port}`;
    console.log(`NIGHTRIDERCO CHAT\nStudio: ${address}\nKeep this window open while streaming. Press Control+C to stop.`);
    if (process.argv.includes('--open') && process.platform === 'darwin') spawn('/usr/bin/open',[address],{stdio:'ignore'}).on('error',()=>{});
  });
  const stop = () => {server.close(()=>process.exit(0));server.closeAllConnections();};
  process.on('SIGINT',stop);process.on('SIGTERM',stop);
}
