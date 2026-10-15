import test from 'node:test';
import assert from 'node:assert/strict';
import {
  KickProvider, normalizeNumericId, normalizeKickMessage, normalizeKickEvent, parseKickFrames, isKickRealtimeUrl,
} from '../lib/kick-realtime.js';

const endpoint = 'wss://realtime.us-west-2.platform.kick.com/connection/websocket';
const message = {
  id: '245f8fc9-1e49-4ee8-9dcc-ede8c5a72457', chatroom_id: 668,
  content: 'Hello [emote:37225:KEKLEO] <img src=x onerror=alert(1)>',
  created_at: '2026-10-13T19:37:47+00:00',
  sender: { id: 1953305, username: 'EffX', identity: { color: '#E9113C', badges: [{ type: 'moderator', text: 'Moderator' }] } },
};

test('normalizes the observed Kick publication without interpreting viewer markup', () => {
  const result = normalizeKickMessage(message, '668');
  assert.equal(result.platform, 'kick');
  assert.equal(result.userId, '1953305');
  assert.equal(result.text, message.content);
  assert.equal(result.createdAt, '2026-10-13T19:37:47.000Z');
  assert.deepEqual(result.badges, [{ type: 'moderator', text: 'Moderator' }]);
  assert.equal(normalizeKickMessage(message, '669'), null);
  assert.equal(normalizeKickMessage({ ...message, sender: { ...message.sender, id: null } }), null);
  assert.equal(normalizeKickMessage({ ...message, id: '<script>' }), null);
  assert.equal(normalizeNumericId(Number.MAX_SAFE_INTEGER + 1), null);
  assert.equal(normalizeNumericId('9007199254740992'), null);
  assert.equal(normalizeNumericId('-1'), null);
  const bounded = normalizeKickMessage({ ...message, content: 'a'.repeat(10000), sender: { ...message.sender, identity: { color: 'url(x)', badges: Array(40).fill({ type: 'a', text: 'b' }) } } });
  assert.equal(bounded.text.length, 4000);
  assert.equal(bounded.badges.length, 12);
  assert.equal(bounded.color, null);
});

test('decodes batches and accepts only known moderation payload shapes', () => {
  assert.deepEqual(parseKickFrames('{}\ninvalid\n{"id":2,"subscribe":{}}'), [{}, { id: 2, subscribe: {} }]);
  assert.deepEqual(parseKickFrames('x'.repeat(262145)), []);
  const application = { event: 'App\\Events\\ChatMessageEvent', data: JSON.stringify(message) };
  assert.equal(normalizeKickEvent(application, '668').message.id, message.id);
  assert.deepEqual(normalizeKickEvent({ event: 'App\\Events\\MessageDeletedEvent', data: { id: 'event-id', message: { id: message.id } } }), { type: 'delete', id: message.id });
  assert.equal(normalizeKickEvent({ event: 'App\\Events\\MessageDeletedEvent', data: { id: message.id } }), null);
  assert.deepEqual(normalizeKickEvent({ event: 'App\\Events\\UserBannedEvent', data: { user: { id: 1953305 } } }), { type: 'ban', userId: '1953305' });
  assert.deepEqual(normalizeKickEvent({ event: 'App\\Events\\ChatroomClearEvent', data: { id: 'clear-event-id' } }), { type: 'clear' });
  assert.equal(normalizeKickEvent({ event: 'App\\Events\\ChatroomClearEvent', data: {} }), null);
});

test('allows only the fixed Kick realtime websocket host pattern', () => {
  assert.equal(isKickRealtimeUrl(endpoint), true);
  for (const url of ['ws://realtime.us-west-2.platform.kick.com/connection/websocket', endpoint + '?token=x', endpoint.replace('kick.com', 'kick.com.evil.test'), 'wss://evil.test/connection/websocket', endpoint.replace('wss://', 'wss://user:password@')]) assert.equal(isKickRealtimeUrl(url), false);
});

function harness(t, options = {}) {
  const sockets = [];
  const requests = [];
  const statuses = [];
  const messages = [];
  const deleted = [];
  const banned = [];
  let clears = 0;
  class FakeSocket {
    constructor(url) { this.url = url; this.readyState = 0; this.sent = []; sockets.push(this); }
    send(raw) { this.sent.push(JSON.parse(raw)); }
    close() { this.readyState = 3; }
    open() { this.readyState = 1; this.onopen?.(); }
    receive(frame) { this.onmessage?.({ data: JSON.stringify(frame) }); }
  }
  const provider = new KickProvider({
    roomId: '668', random: () => 0, WebSocketImpl: FakeSocket,
    fetchImpl: async path => {
      requests.push(path);
      const data = path.includes('/channel?') ? { roomId: 668, channelId: 668 } : path.includes('/token?') ? { token: 'fresh-anonymous-token' } : { url: endpoint, token: 'anonymous-test-token' };
      return { ok: true, json: async () => data };
    },
    onStatus: status => statuses.push(status), onMessage: msg => messages.push(msg),
    onDelete: id => deleted.push(id), onBan: userId => banned.push(userId), onClear: () => clears++,
    ...options,
  });
  t.after(() => provider.disconnect());
  return { provider, sockets, requests, statuses, messages, deleted, banned, get clears() { return clears; } };
}

function acknowledge(socket, ttl = 2700) {
  socket.open();
  socket.receive({ id: 1, connect: { client: 'server-id', expires: true, ttl, ping: 25, pong: true } });
  socket.receive({ id: 2, subscribe: {} });
}

test('reports connected only after subscription acknowledgment; deduplicates and dispatches moderation', async t => {
  const h = harness(t);
  await h.provider.connect();
  assert.equal(h.requests.some(path => path.includes('/channel?')), false, 'manual room override skips resolution');
  const socket = h.sockets[0];
  socket.open();
  assert.equal(socket.sent[0].connect.token, 'anonymous-test-token');
  socket.receive({ id: 1, connect: { ping: 25, pong: true } });
  assert.equal(h.statuses.at(-1).state, 'connecting');
  assert.deepEqual(socket.sent[1].subscribe, { channel: 'chatrooms.668.v2' });
  socket.receive({ id: 2, subscribe: {} });
  assert.equal(h.statuses.at(-1).state, 'connected');
  const publication = (event, data, channel = 'chatrooms.668.v2') => socket.receive({ push: { channel, pub: { data: { event: `App\\Events\\${event}`, data: JSON.stringify(data) } } } });
  publication('ChatMessageEvent', message);
  publication('ChatMessageEvent', message);
  publication('ChatMessageEvent', { ...message, id: 'wrong-room' }, 'chatrooms.999.v2');
  assert.equal(h.messages.length, 1);
  publication('MessageDeletedEvent', { message: { id: message.id } });
  publication('UserBannedEvent', { user: { id: message.sender.id } });
  publication('ChatroomClearEvent', { id: 'clear-event' });
  assert.deepEqual(h.deleted, [message.id]);
  assert.deepEqual(h.banned, ['1953305']);
  assert.equal(h.clears, 1);
  socket.receive({});
  assert.deepEqual(socket.sent.at(-1), {}, 'responds to negotiated server heartbeat');
});

test('resolves slug with correct channel ID and resets stale IDs on reconnect', async t => {
  const h = harness(t, { roomId: null, channel: 'xqc' });
  await h.provider.connect();
  assert.match(h.requests[0], /channel\?slug=xqc/);
  assert.match(h.requests[1], /channelId=668/);
  h.provider.roomOverride = '669';
  await h.provider.connect();
  assert.doesNotMatch(h.requests.at(-1), /channelId=/);
  assert.equal(h.provider.roomId, '669');
});

test('refreshes anonymous token before expiry and stops timers after disconnect', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const h = harness(t);
  await h.provider.connect();
  const socket = h.sockets[0];
  acknowledge(socket, 3);
  t.mock.timers.tick(2800);
  await new Promise(resolve => setImmediate(resolve));
  assert.match(h.requests.at(-1), /\/api\/kick\/token\?clientId=/);
  assert.equal(socket.sent.at(-1).refresh.token, 'fresh-anonymous-token');
  socket.receive({ id: 3, refresh: { expires: true, ttl: 2700 } });
  h.provider.disconnect();
  const count = h.requests.length;
  t.mock.timers.tick(3600000);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.requests.length, count);
  assert.equal(h.statuses.at(-1).state, 'disconnected');
});

test('reconnects once with backoff after interruption and ignores stale socket events', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const h = harness(t);
  await h.provider.connect();
  const first = h.sockets[0];
  acknowledge(first);
  const staleOnMessage = first.onmessage;
  first.onerror();
  assert.equal(h.statuses.at(-1).state, 'reconnecting');
  assert.equal(h.sockets.length, 1);
  t.mock.timers.tick(1000);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.sockets.length, 2);
  assert.equal(h.sockets[1].readyState, 0);
  staleOnMessage({ data: '{"id":2,"subscribe":{}}' });
  assert.equal(h.statuses.at(-1).state, 'reconnecting');
  h.provider.disconnect();
  t.mock.timers.tick(100000);
  assert.equal(h.sockets.length, 2);
});

test('rejects untrusted transport URLs before opening a socket', async t => {
  const h = harness(t, { fetchImpl: async () => ({ ok: true, json: async () => ({ url: 'wss://evil.example/connection/websocket', token: 'test-token' }) }) });
  await h.provider.connect();
  assert.equal(h.sockets.length, 0);
  assert.equal(h.statuses.at(-1).state, 'error');
});
