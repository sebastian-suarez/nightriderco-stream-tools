// Kick's anonymous web client transport, verified 2026-10-13.
// The documented developer API uses webhooks; this transport is unofficial.
// See PRIMARY-SOURCES.txt for the inspected client and protocol references.

const MAX_FRAME = 262144;
const MAX_TEXT = 4000;
const MAX_SEEN = 2000;
const NOOP = () => {};
const EVENTS = 'App\\Events\\';

function object(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function limitedText(value, max) {
  return typeof value === 'string' ? value.slice(0, max) : '';
}

export function normalizeNumericId(value) {
  if (typeof value === 'number' && !Number.isSafeInteger(value)) return null;
  const id = typeof value === 'number' || typeof value === 'string' ? String(value) : '';
  return /^[1-9]\d{0,15}$/.test(id) && Number.isSafeInteger(Number(id)) ? id : null;
}

export function normalizeMessageId(value) {
  return typeof value === 'string' && /^[A-Za-z0-9_.:-]{1,128}$/.test(value) ? value : null;
}

export function normalizeChannel(value) {
  const slug = typeof value === 'string' ? value.trim().toLowerCase() : '';
  return /^[a-z0-9_-]{1,60}$/.test(slug) ? slug : null;
}

export function normalizeKickMessage(payload, expectedRoomId) {
  if (!object(payload) || !object(payload.sender) || typeof payload.content !== 'string') return null;
  if (expectedRoomId && payload.chatroom_id !== undefined && normalizeNumericId(payload.chatroom_id) !== String(expectedRoomId)) return null;
  const id = normalizeMessageId(payload.id);
  const userId = normalizeNumericId(payload.sender.id);
  const username = limitedText(payload.sender.username, 64).trim();
  if (!id || !userId || !username) return null;
  const identity = object(payload.sender.identity) ? payload.sender.identity : {};
  const color = typeof identity.color === 'string' && /^#[a-fA-F0-9]{6}$/.test(identity.color) ? identity.color : null;
  const badges = Array.isArray(identity.badges) ? identity.badges.slice(0, 12).filter(object).map(badge => ({
    type: limitedText(badge.type, 40),
    text: limitedText(badge.text, 60),
  })).filter(badge => badge.type) : [];
  const timestamp = limitedText(payload.created_at, 64);
  return {
    id,
    platform: 'kick',
    userId,
    username,
    color,
    badges,
    text: payload.content.slice(0, MAX_TEXT),
    createdAt: Number.isFinite(Date.parse(timestamp)) ? new Date(timestamp).toISOString() : new Date().toISOString(),
  };
}

export function decodeKickData(value) {
  if (typeof value === 'string') {
    if (value.length > MAX_FRAME) return null;
    try { value = JSON.parse(value); } catch { return null; }
  }
  return object(value) ? value : null;
}

export function parseKickFrames(raw) {
  if (typeof raw !== 'string' || raw.length > MAX_FRAME) return [];
  const frames = [];
  for (const line of raw.trim().split('\n').slice(0, 1000)) {
    try {
      const frame = JSON.parse(line);
      if (object(frame)) frames.push(frame);
    } catch { /* A malformed frame cannot reach the renderer. */ }
  }
  return frames;
}

export function normalizeKickEvent(envelope, expectedRoomId) {
  if (!object(envelope) || typeof envelope.event !== 'string') return null;
  const data = decodeKickData(envelope.data);
  if (!data) return null;
  if (envelope.event === `${EVENTS}ChatMessageEvent`) {
    const message = normalizeKickMessage(data, expectedRoomId);
    return message ? { type: 'message', message } : null;
  }
  // These exact shapes are consumed by Kick's current chat client.
  if (envelope.event === `${EVENTS}MessageDeletedEvent`) {
    const id = object(data.message) ? normalizeMessageId(data.message.id) : null;
    return id ? { type: 'delete', id } : null;
  }
  if (envelope.event === `${EVENTS}UserBannedEvent`) {
    const userId = object(data.user) ? normalizeNumericId(data.user.id) : null;
    return userId ? { type: 'ban', userId } : null;
  }
  if (envelope.event === `${EVENTS}ChatroomClearEvent` && normalizeMessageId(data.id)) return { type: 'clear' };
  return null;
}

export function isKickRealtimeUrl(value) {
  if (typeof value !== 'string' || value.length > 200) return false;
  try {
    const url = new URL(value);
    return url.protocol === 'wss:' && /^realtime\.[a-z]{2}-[a-z]+-\d\.platform\.kick\.com$/.test(url.hostname) &&
      url.pathname === '/connection/websocket' && !url.port && !url.search && !url.hash && !url.username && !url.password;
  } catch { return false; }
}

export class KickProvider {
  constructor({ channel = '', roomId = null, onMessage = NOOP, onDelete = NOOP, onBan = NOOP, onClear = NOOP, onStatus = NOOP,
    fetchImpl = globalThis.fetch?.bind(globalThis), WebSocketImpl = globalThis.WebSocket, random = Math.random } = {}) {
    this.channel = channel;
    this.roomOverride = roomId;
    this.roomId = null;
    this.channelId = null;
    this.callbacks = { onMessage, onDelete, onBan, onClear, onStatus };
    this.fetch = fetchImpl;
    this.WebSocket = WebSocketImpl;
    this.random = random;
    this.active = false;
    this.generation = 0;
    this.attempt = 0;
    this.commandId = 0;
    this.pending = new Map();
    this.seen = new Set();
    this.timers = new Set();
    this.socket = null;
    this.requestController = null;
    this.clientId = null;
    this.subscribed = false;
    this.heartbeatMs = 35000;
    this.sendPong = false;
    this.heartbeatTimer = null;
    this.refreshTimer = null;
  }

  emit(name, ...args) {
    try { this.callbacks[name]?.(...args); } catch { /* UI callbacks must not break the transport. */ }
  }

  status(state, detail) {
    this.emit('onStatus', { state, detail, roomId: this.roomId });
  }

  later(callback, delay) {
    const timer = setTimeout(() => { this.timers.delete(timer); callback(); }, delay);
    this.timers.add(timer);
    return timer;
  }

  clearTimer(timer) {
    if (timer !== null && timer !== undefined) { clearTimeout(timer); this.timers.delete(timer); }
  }

  clearTimers() {
    for (const timer of this.timers) clearTimeout(timer);
    this.timers.clear();
    this.heartbeatTimer = null;
    this.refreshTimer = null;
    this.pending.clear();
  }

  async request(path, generation) {
    const controller = new AbortController();
    this.requestController = controller;
    const timeout = this.later(() => controller.abort(), 12000);
    try {
      const response = await this.fetch(path, { signal: controller.signal, cache: 'no-store', credentials: 'omit' });
      if (!response.ok) {
        let detail = '';
        try { detail = limitedText((await response.json()).error, 180); } catch { /* Do not show upstream bodies. */ }
        const error = new Error(detail || `Kick connection request failed (${response.status}).`);
        error.fatal = [400, 401, 403, 404].includes(response.status);
        throw error;
      }
      const data = await response.json();
      if (generation !== this.generation || !this.active) return null;
      return data;
    } finally {
      this.clearTimer(timeout);
      if (this.requestController === controller) this.requestController = null;
    }
  }

  async connect() {
    this.stop(false);
    this.active = true;
    this.roomId = null;
    this.channelId = null;
    const generation = ++this.generation;
    this.attempt = 0;
    this.seen.clear();
    this.clientId = globalThis.crypto?.randomUUID?.();
    if (!this.clientId || !this.fetch || !this.WebSocket) return this.fatal('This browser cannot open the Kick chat connection.');
    if (this.roomOverride !== null && this.roomOverride !== '') {
      this.roomId = normalizeNumericId(this.roomOverride);
      if (!this.roomId) return this.fatal('Enter a valid Kick chatroom ID.');
    } else {
      const slug = normalizeChannel(this.channel);
      if (!slug) return this.fatal('Enter your Kick channel name.');
      this.status('resolving', `Finding ${slug} chat…`);
      try {
        const result = await this.request(`/api/kick/channel?slug=${encodeURIComponent(slug)}`, generation);
        if (!result) return;
        this.roomId = normalizeNumericId(result.roomId);
        this.channelId = normalizeNumericId(result.channelId);
        if (!this.roomId || !this.channelId) return this.fatal('Kick returned an invalid chatroom.');
      } catch (error) {
        if (generation !== this.generation || !this.active) return;
        return this.fatal(error.message || 'Could not find this Kick channel. Enter its chatroom ID instead.');
      }
    }
    await this.open(generation);
  }

  async open(generation) {
    if (!this.active || generation !== this.generation) return;
    this.status(this.attempt ? 'reconnecting' : 'connecting', 'Opening Kick chat…');
    try {
      const query = new URLSearchParams({ clientId: this.clientId });
      if (this.channelId) query.set('channelId', this.channelId);
      const result = await this.request(`/api/kick/connection?${query}`, generation);
      if (!result) return;
      if (!isKickRealtimeUrl(result.url) || typeof result.token !== 'string' || result.token.length > 16384 || !result.token) {
        return this.fatal('Kick returned an unsupported chat connection.');
      }
      const socket = new this.WebSocket(result.url);
      this.socket = socket;
      this.commandId = 0;
      this.subscribed = false;
      this.sendPong = false;
      this.heartbeatMs = 35000;
      this.armHeartbeat(generation);
      socket.onopen = () => {
        if (this.isCurrent(socket, generation)) this.sendCommand('connect', { token: result.token, name: 'js', version: 'nightrider-1' });
      };
      socket.onmessage = event => {
        if (!this.isCurrent(socket, generation)) return;
        const frames = parseKickFrames(event.data);
        if (!frames.length) return;
        this.armHeartbeat(generation);
        for (const frame of frames) {
          if (!this.isCurrent(socket, generation)) break;
          this.handleFrame(frame, generation);
        }
      };
      socket.onerror = () => {
        if (this.isCurrent(socket, generation)) this.retry('Kick connection interrupted. Retrying…', generation);
      };
      socket.onclose = event => {
        if (!this.isCurrent(socket, generation)) return;
        if (event.code >= 3500 && event.code < 4000 && event.code !== 3502) return this.fatal('Kick closed the chat connection. Reconnect from the setup page.');
        this.retry('Kick connection closed. Retrying…', generation);
      };
    } catch (error) {
      if (generation !== this.generation || !this.active) return;
      if (error.fatal) this.fatal(error.message);
      else this.retry('Could not reach Kick. Retrying…', generation);
    }
  }

  isCurrent(socket, generation) {
    return this.active && this.socket === socket && this.generation === generation;
  }

  sendCommand(kind, data) {
    if (!this.socket || this.socket.readyState !== 1) return;
    const id = ++this.commandId;
    const timer = this.later(() => this.retry('Kick chat did not respond. Retrying…', this.generation), 12000);
    this.pending.set(id, { kind, timer });
    try { this.socket.send(JSON.stringify({ id, [kind]: data })); }
    catch { this.retry('Kick connection interrupted. Retrying…', this.generation); }
  }

  handleFrame(frame, generation) {
    if (!Object.keys(frame).length) {
      if (this.sendPong && this.socket?.readyState === 1) this.socket.send('{}');
      return;
    }
    if (Number.isSafeInteger(frame.id) && this.pending.has(frame.id)) {
      const { kind, timer } = this.pending.get(frame.id);
      this.pending.delete(frame.id);
      this.clearTimer(timer);
      if (object(frame.error)) {
        if (frame.error.temporary === true || frame.error.code === 109) return this.retry('Kick chat is temporarily unavailable. Retrying…', generation);
        return this.fatal(`Kick rejected the ${kind === 'subscribe' ? 'chatroom subscription' : 'chat connection'}. Check your channel or chatroom ID.`);
      }
      if (!object(frame[kind])) return this.retry('Kick returned an unexpected response. Retrying…', generation);
      if (kind === 'connect') {
        const ping = frame.connect.ping;
        this.heartbeatMs = Number.isFinite(ping) && ping > 0 ? Math.min(ping, 120) * 1000 + 10000 : 35000;
        this.sendPong = frame.connect.pong === true;
        this.armHeartbeat(generation);
        this.scheduleRefresh(frame.connect, generation);
        this.sendCommand('subscribe', { channel: `chatrooms.${this.roomId}.v2` });
      } else if (kind === 'subscribe') {
        this.subscribed = true;
        this.attempt = 0;
        this.status('connected', 'Kick chat connected');
      } else if (kind === 'refresh') this.scheduleRefresh(frame.refresh, generation);
      return;
    }
    const push = frame.push;
    if (!object(push)) return;
    if (object(push.disconnect)) return this.retry('Kick is refreshing the chat connection…', generation);
    if (push.channel !== `chatrooms.${this.roomId}.v2`) return;
    if (object(push.unsubscribe)) return this.fatal('Kick ended the chatroom subscription. Reconnect from the setup page.');
    if (!this.subscribed || !object(push.pub)) return;
    const normalized = normalizeKickEvent(decodeKickData(push.pub.data), this.roomId);
    if (!normalized) return;
    if (normalized.type === 'message') {
      if (this.seen.has(normalized.message.id)) return;
      this.seen.add(normalized.message.id);
      if (this.seen.size > MAX_SEEN) this.seen.delete(this.seen.values().next().value);
      this.emit('onMessage', normalized.message);
    } else if (normalized.type === 'delete') this.emit('onDelete', normalized.id);
    else if (normalized.type === 'ban') this.emit('onBan', normalized.userId);
    else this.emit('onClear');
  }

  armHeartbeat(generation) {
    this.clearTimer(this.heartbeatTimer);
    this.heartbeatTimer = this.later(() => this.retry('Kick chat stopped responding. Reconnecting…', generation), this.heartbeatMs);
  }

  scheduleRefresh(result, generation) {
    this.clearTimer(this.refreshTimer);
    if (result.expires !== true || !Number.isFinite(result.ttl) || result.ttl <= 0) return;
    const ttl = Math.min(result.ttl, 86400);
    this.refreshTimer = this.later(async () => {
      try {
        const result = await this.request(`/api/kick/token?clientId=${encodeURIComponent(this.clientId)}`, generation);
        if (!result) return;
        if (typeof result.token !== 'string' || !result.token || result.token.length > 16384) return this.retry('Could not renew Kick chat. Reconnecting…', generation);
        this.sendCommand('refresh', { token: result.token });
      } catch {
        if (generation === this.generation && this.active) this.retry('Could not renew Kick chat. Reconnecting…', generation);
      }
    }, Math.max(1000, (ttl - Math.min(60, ttl * 0.1)) * 1000));
  }

  retry(detail, generation) {
    if (!this.active || generation !== this.generation) return;
    this.closeSocket();
    this.clearTimers();
    this.requestController?.abort();
    const nextGeneration = ++this.generation;
    const delay = Math.min(30000, 1000 * 2 ** Math.min(this.attempt++, 5)) + Math.floor(this.random() * 1000);
    this.status('reconnecting', detail);
    this.later(() => this.open(nextGeneration), delay);
  }

  fatal(detail) {
    this.stop(false);
    this.status('error', detail);
  }

  closeSocket() {
    const socket = this.socket;
    this.socket = null;
    this.subscribed = false;
    if (socket) {
      socket.onopen = socket.onmessage = socket.onerror = socket.onclose = null;
      try { socket.close(); } catch { /* Closing a not-yet-open socket is harmless. */ }
    }
  }

  stop(report) {
    this.active = false;
    this.generation++;
    this.requestController?.abort();
    this.requestController = null;
    this.closeSocket();
    this.clearTimers();
    if (report) this.status('disconnected', 'Kick chat disconnected');
  }

  disconnect() {
    this.stop(true);
  }
}
