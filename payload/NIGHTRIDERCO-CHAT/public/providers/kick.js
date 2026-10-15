// The local companion owns Kick's upstream connection. This client receives
// normalized events over same-origin SSE, including in OBS's browser engine.
const NOOP=()=>{};
export class KickProvider {
  constructor({channel='nightriderco',roomId=null,onMessage=NOOP,onDelete=NOOP,onBan=NOOP,onClear=NOOP,onStatus=NOOP,EventSourceImpl=globalThis.EventSource}={}) {
    this.channel=channel;this.roomId=roomId;this.callbacks={onMessage,onDelete,onBan,onClear,onStatus};
    this.EventSource=EventSourceImpl;this.source=null;this.generation=0;
  }
  emit(name,value) {try{this.callbacks[name]?.(value);}catch{}}
  status(state,detail) {this.emit('onStatus',{state,detail,roomId:this.roomId});}
  connect() {
    this.stop();
    const channel=typeof this.channel==='string'?this.channel.trim().toLowerCase():'';
    if(this.roomId!=null && typeof this.roomId!=='string' && typeof this.roomId!=='number') {this.status('error','Enter a valid chat-room ID.');return;}
    const room=this.roomId==null?'':String(this.roomId);
    if(!/^[a-z0-9_-]{1,60}$/.test(channel) || (room && (!/^[1-9]\d{0,15}$/.test(room) || !Number.isSafeInteger(Number(room))))) {this.status('error','Enter a valid channel name and chat-room ID.');return;}
    if(!this.EventSource) {this.status('error','This browser does not support the local chat connection.');return;}
    const generation=++this.generation;
    const query=new URLSearchParams({slug:channel});if(room)query.set('room',room);
    this.status('connecting','Opening the local Kick companion…');
    let source;
    try{source=new this.EventSource(`/api/kick/events?${query}`);}catch{this.status('error','Could not open the local chat companion.');return;}
    this.source=source;
    source.onmessage=event=>{
      if(this.source!==source || generation!==this.generation || typeof event.data!=='string' || event.data.length>262144)return;
      let data;try{data=JSON.parse(event.data);}catch{return;}
      if(!data || typeof data!=='object')return;
      if(data.type==='status' && data.value && ['resolving','connecting','connected','reconnecting','error','disconnected'].includes(data.value.state))this.emit('onStatus',data.value);
      else if(data.type==='message' && data.value && typeof data.value.text==='string')this.emit('onMessage',data.value);
      else if(data.type==='delete' && typeof data.value==='string')this.emit('onDelete',data.value);
      else if(data.type==='ban' && (typeof data.value==='string'||typeof data.value==='number'))this.emit('onBan',String(data.value));
      else if(data.type==='clear')this.emit('onClear');
    };
    source.onerror=()=>{if(this.source===source && generation===this.generation)this.status('reconnecting','The local companion is unavailable. Keep START-CHAT.command running; reconnecting automatically…');};
  }
  stop() {this.generation++;if(this.source){this.source.onmessage=this.source.onerror=null;this.source.close();this.source=null;}}
  disconnect() {this.stop();this.status('disconnected','Kick chat disconnected');}
}
