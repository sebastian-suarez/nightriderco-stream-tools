const clamp = (value, minimum, maximum, fallback) => Number.isFinite(Number(value)) ? Math.max(minimum, Math.min(maximum, Number(value))) : fallback;
const localEmotes = { hi: '/assets/skadi-hi-112.png', gg: '/assets/skadi-gg-112.png', heart: '/assets/skadi-heart-112.png' };
const copy = { en: { title:'THE COMMUNITY', kick:'KICK', ride:'YOU ARE PART OF THE RIDE', demoNote:'DEMO · SAMPLE MESSAGES' }, es: { title:'LA COMUNIDAD', kick:'KICK', ride:'ERES PARTE DEL CAMINO', demoNote:'DEMO · MENSAJES DE EJEMPLO' } };

/** Platform-independent, text-safe chat renderer. No HTML from chat is inserted. */
export class ChatView {
  constructor(element, options = {}) {
    if (!element) throw new Error('ChatView needs a container.');
    this.element = element;
    this.messages = new Map();
    this.options = {};
    this.element.classList.add('chat-messages');
    this.configure(options);
    this.expiry = setInterval(() => this.expire(), 1000);
  }
  configure(options = {}) {
    this.options = { ...this.options, ...options };
    this.options.fontSize = clamp(this.options.fontSize, 18, 38, 24);
    this.options.maxMessages = Math.round(clamp(this.options.maxMessages, 3, 30, 12));
    this.options.fadeSeconds = clamp(this.options.fadeSeconds, 0, 300, 0);
    this.options.lang = this.options.lang === 'es' ? 'es' : 'en';
    this.options.theme = this.options.theme === 'minimal' ? 'minimal' : 'panel';
    this.options.hideCommands = this.options.hideCommands === true || this.options.hideCommands === 'true' || this.options.hideCommands === '1';
    this.botNames = new Set(String(this.options.bots || '').split(',').map(name => name.trim().toLowerCase()).filter(Boolean));
    this.element.style.setProperty('--chat-size', `${this.options.fontSize}px`);
    const shell = this.element.closest('.nrc-chat');
    if (shell) {
      shell.dataset.theme=this.options.theme;
      shell.lang=this.options.lang;
      const demoNote=shell.querySelector('.chat-demo-note'); if(demoNote) demoNote.textContent=copy[this.options.lang].demoNote;
      shell.querySelectorAll('[data-chat-copy]').forEach(node => { const text=copy[this.options.lang][node.dataset.chatCopy]; if(text) node.textContent=text; });
    }
    for(const [id, entry] of this.messages) if(this.filtered(entry.message)) this.remove(id);
    this.trim();
    this.expire();
  }
  filtered(message) {
    return (this.options.hideCommands && /^\s*!/.test(message.text || '')) || this.botNames.has(String(message.username || '').toLowerCase());
  }
  add(message) {
    if(!message || typeof message.text !== 'string' || !message.username || this.filtered(message)) return;
    const id=String(message.id || `${Date.now()}-${Math.random()}`);
    if(this.messages.has(id)) return;
    const item=document.createElement('article'); item.className='chat-message'; item.dataset.messageId=id;
    const head=document.createElement('div'); head.className='chat-message-head';
    const name=document.createElement('span'); name.className='chat-username'; name.textContent=String(message.username).slice(0,100);
    // Keep all viewer names in the established ice palette for readable contrast.
    head.append(name);
    if(Array.isArray(message.badges)) for(const badge of message.badges.slice(0,4)) {
      const type=String(badge.type || '').toLowerCase();
      const el=document.createElement('span'); el.className='chat-badge'; el.dataset.type=type;
      el.textContent=String(badge.text || type).slice(0,35); head.append(el);
    }
    const body=document.createElement('div'); body.className='chat-message-text';
    this.renderText(body, message.text.slice(0,5000), message.demo === true);
    item.append(head,body);
    this.messages.set(id,{ element:item, message, receivedAt:Date.now() });
    this.element.append(item);
    this.trim();
  }
  renderText(element, text, demo) {
    // Numeric Kick IDs only. User text cannot choose a host or arbitrary image URL.
    const pattern=/\[emote:(\d{1,20}):([^\]\r\n]{1,80})\]|\[demo:(hi|gg|heart)\]/g;
    let cursor=0;
    for(const match of text.matchAll(pattern)) {
      element.append(document.createTextNode(text.slice(cursor,match.index)));
      if(match[3] && !demo) element.append(document.createTextNode(match[0]));
      else {
        const image=document.createElement('img'); image.className='chat-emote'; image.alt=match[2] || `Skadi ${match[3]}`;
        image.loading='eager'; image.referrerPolicy='no-referrer'; image.src=match[3] ? localEmotes[match[3]] : `https://files.kick.com/emotes/${match[1]}/fullsize`;
        image.addEventListener('error',()=>image.replaceWith(document.createTextNode(image.alt)),{once:true});
        element.append(image);
      }
      cursor=match.index+match[0].length;
    }
    element.append(document.createTextNode(text.slice(cursor)));
  }
  trim() {
    while(this.messages.size > this.options.maxMessages) this.remove(this.messages.keys().next().value);
    // Very long posts remain clipped by the container; remove older rows first.
    while(this.messages.size > 1 && this.element.scrollHeight > this.element.clientHeight && this.element.clientHeight > 0) this.remove(this.messages.keys().next().value);
  }
  expire() {
    if(!this.options.fadeSeconds) return;
    const before=Date.now()-this.options.fadeSeconds*1000;
    for(const [id,item] of this.messages) if(item.receivedAt < before) this.remove(id);
  }
  remove(id) {
    const entry=this.messages.get(String(id)); if(!entry) return;
    entry.element.remove(); this.messages.delete(String(id));
  }
  ban(userId) {
    const target=String(userId ?? ''); if(!target) return;
    for(const [id,item] of this.messages) if(String(item.message.userId ?? '')===target) this.remove(id);
  }
  clear() { for(const id of Array.from(this.messages.keys())) this.remove(id); }
  destroy() { clearInterval(this.expiry); this.clear(); this.element.replaceChildren(); }
}
