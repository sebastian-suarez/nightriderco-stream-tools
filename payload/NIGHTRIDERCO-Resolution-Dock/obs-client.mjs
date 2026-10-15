import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { createHash, randomUUID } from 'node:crypto';
export class OBS {
  constructor() { this.pending = new Map(); this.connected = false; }
  async connect() {
    if (this.connected) return;
    if (this.connecting) return this.connecting;
    this.connecting = this.open().finally(() => { this.connecting = null; });
    return this.connecting;
  }
  async open() {
    const config = JSON.parse(await readFile(homedir() + '/Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json', 'utf8'));
    if (!config.server_enabled) throw new Error('Enable the WebSocket server in OBS → Tools.');
    const ws = new WebSocket(`ws://127.0.0.1:${config.server_port || 4455}`, 'obswebsocket.json');
    this.ws = ws;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { ws.close(); reject(new Error('OBS connection timed out.')); }, 5000);
      ws.addEventListener('message', event => {
        try {
          const { op, d } = JSON.parse(event.data);
          if (op === 0) {
            const identify = { rpcVersion: 1, eventSubscriptions: 0 };
            if (d.authentication) {
              const sha = text => createHash('sha256').update(text).digest('base64');
              identify.authentication = sha(sha(config.server_password + d.authentication.salt) + d.authentication.challenge);
            }
            delete config.server_password;
            ws.send(JSON.stringify({ op: 1, d: identify }));
          } else if (op === 2) { clearTimeout(timer); this.connected = true; resolve(); }
          else if (op === 7) {
            const p = this.pending.get(d.requestId);
            if (!p) return;
            clearTimeout(p.timer); this.pending.delete(d.requestId);
            if (d.requestStatus.result) p.resolve(d.responseData || {});
            else p.reject(Object.assign(new Error(`${d.requestType}: ${d.requestStatus.comment || 'OBS refused the request'}`), {obsCode:d.requestStatus.code,requestType:d.requestType}));
          }
        } catch (error) { clearTimeout(timer); reject(error); }
      });
      ws.addEventListener('error', () => { clearTimeout(timer); reject(new Error('Open OBS Studio to connect.')); });
      ws.addEventListener('close', () => {
        clearTimeout(timer); this.connected = false;
        for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(new Error('OBS disconnected; inspect the backup before retrying.')); }
        this.pending.clear(); reject(new Error('OBS disconnected.'));
      });
    });
  }
  async call(requestType, requestData = {}) {
    await this.connect();
    const requestId = randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(requestId); reject(new Error(`${requestType} timed out; its result is uncertain.`)); }, 10000);
      this.pending.set(requestId, { resolve, reject, timer });
      try { this.ws.send(JSON.stringify({ op: 6, d: { requestId, requestType, requestData } })); }
      catch (error) { clearTimeout(timer); this.pending.delete(requestId); reject(error); }
    });
  }
  close() { this.ws?.close(); }
}
