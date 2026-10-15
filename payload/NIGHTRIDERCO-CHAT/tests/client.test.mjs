import test from 'node:test';
import assert from 'node:assert/strict';
import { KickProvider } from '../public/providers/kick.js';

function harness(t, options = {}) {
  const sources = [];
  const statuses = [];
  const messages = [];
  const deleted = [];
  const banned = [];
  let clears = 0;
  class FakeEventSource {
    constructor(url) { this.url = url; this.closeCount = 0; sources.push(this); }
    close() { this.closeCount++; }
    receive(value) { this.onmessage?.({ data: JSON.stringify(value) }); }
  }
  const provider = new KickProvider({
    channel: 'nightriderco', EventSourceImpl: FakeEventSource,
    onStatus: value => statuses.push(value), onMessage: value => messages.push(value),
    onDelete: value => deleted.push(value), onBan: value => banned.push(value), onClear: () => clears++,
    ...options,
  });
  t.after(() => provider.disconnect());
  return { provider, sources, statuses, messages, deleted, banned, get clears() { return clears; } };
}

test('opens a same-origin stream with normalized channel and optional room override', t => {
  const h = harness(t, { channel: '  NightRiderCO  ', roomId: '132926621' });
  h.provider.connect();
  assert.equal(h.sources.length, 1);
  assert.equal(h.sources[0].url, '/api/kick/events?slug=nightriderco&room=132926621');
  assert.equal(h.statuses.at(-1).state, 'connecting');
  h.provider.roomId = null;
  h.provider.connect();
  assert.equal(h.sources[0].closeCount, 1);
  assert.equal(h.sources[1].url, '/api/kick/events?slug=nightriderco');
});

test('reports connected only when the companion confirms the upstream subscription', t => {
  const h = harness(t);
  h.provider.connect();
  const source = h.sources[0];
  source.onopen?.();
  assert.deepEqual(h.statuses.map(status => status.state), ['connecting']);
  source.receive({ type: 'status', value: { state: 'resolving', detail: 'Finding channel' } });
  source.receive({ type: 'status', value: { state: 'connecting', detail: 'Waiting for Kick' } });
  assert.equal(h.statuses.some(status => status.state === 'connected'), false);
  source.receive({ type: 'status', value: { state: 'connected', detail: 'Kick chat connected', roomId: '132926621' } });
  assert.equal(h.statuses.at(-1).state, 'connected');
  assert.equal(h.statuses.at(-1).roomId, '132926621');
});

test('dispatches normalized chat messages and moderation events', t => {
  const h = harness(t);
  h.provider.connect();
  const source = h.sources[0];
  const message = { id: 'message-1', platform: 'kick', userId: '99', username: 'rider', text: '<b>Literal chat text</b>' };
  source.receive({ type: 'message', value: message });
  source.receive({ type: 'delete', value: 'message-1' });
  source.receive({ type: 'ban', value: 99 });
  source.receive({ type: 'ban', value: '100' });
  source.receive({ type: 'clear' });
  assert.deepEqual(h.messages, [message]);
  assert.deepEqual(h.deleted, ['message-1']);
  assert.deepEqual(h.banned, ['99', '100']);
  assert.equal(h.clears, 1);
});

test('ignores malformed, unknown, wrongly typed and oversized input', t => {
  const h = harness(t);
  h.provider.connect();
  const source = h.sources[0];
  const originalStatuses = h.statuses.length;
  for (const value of [null, [], 'text', 42, {}, { type: 'unknown' },
    { type: 'message', value: null }, { type: 'message', value: { text: 1 } },
    { type: 'delete', value: 123 }, { type: 'ban', value: {} },
    { type: 'status', value: null }, { type: 'status', value: { state: 'made-up' } }]) {
    source.receive(value);
  }
  source.onmessage({ data: '{invalid-json' });
  source.onmessage({ data: { type: 'message', value: { text: 'not a serialized frame' } } });
  source.onmessage({ data: JSON.stringify({ type: 'message', value: { text: 'a'.repeat(262145) } }) });
  assert.equal(h.statuses.length, originalStatuses);
  assert.deepEqual(h.messages, []);
  assert.deepEqual(h.deleted, []);
  assert.deepEqual(h.banned, []);
  assert.equal(h.clears, 0);
});

test('rejects invalid channel and room inputs before opening EventSource', t => {
  for (const channel of [null, {}, [], '', 'a'.repeat(61), 'two words', '../channel',
    'https://kick.com/channel', 'café']) {
    const h = harness(t, { channel });
    h.provider.connect();
    assert.equal(h.sources.length, 0, `opened channel ${JSON.stringify(channel)}`);
    assert.equal(h.statuses.at(-1).state, 'error');
  }
  for (const roomId of [0, -1, 1.5, Number.MAX_SAFE_INTEGER + 1, '9007199254740992',
    '001', '1e3', '../123', '123&other=1', {}, [], [123]]) {
    const h = harness(t, { roomId });
    h.provider.connect();
    assert.equal(h.sources.length, 0, `opened room ${JSON.stringify(roomId)}`);
    assert.equal(h.statuses.at(-1).state, 'error');
  }
});

test('reports unsupported browser or constructor failure as an error', t => {
  const missing = harness(t, { EventSourceImpl: null });
  missing.provider.connect();
  assert.equal(missing.statuses.at(-1).state, 'error');
  const broken = harness(t, { EventSourceImpl: class { constructor() { throw new Error('cannot open'); } } });
  assert.doesNotThrow(() => broken.provider.connect());
  assert.equal(broken.statuses.at(-1).state, 'error');
});

test('EventSource errors report reconnecting without duplicating its automatic retry', t => {
  const h = harness(t);
  h.provider.connect();
  const source = h.sources[0];
  source.onerror();
  source.onerror();
  assert.equal(h.statuses.at(-1).state, 'reconnecting');
  assert.equal(h.sources.length, 1);
  assert.equal(source.closeCount, 0);
  source.receive({ type: 'status', value: { state: 'connected', detail: 'Back online' } });
  assert.equal(h.statuses.at(-1).state, 'connected');
});

test('replacement connection closes the old source and ignores its captured callbacks', t => {
  const h = harness(t);
  h.provider.connect();
  const first = h.sources[0];
  const staleMessage = first.onmessage;
  const staleError = first.onerror;
  h.provider.connect();
  assert.equal(first.closeCount, 1);
  assert.equal(first.onmessage, null);
  assert.equal(first.onerror, null);
  const count = h.statuses.length;
  staleMessage({ data: JSON.stringify({ type: 'status', value: { state: 'connected' } }) });
  staleMessage({ data: JSON.stringify({ type: 'message', value: { text: 'old connection' } }) });
  staleError();
  assert.equal(h.statuses.length, count);
  assert.deepEqual(h.messages, []);
  h.sources[1].receive({ type: 'message', value: { text: 'current connection' } });
  assert.equal(h.messages.length, 1);
});

test('disconnect closes the stream, ignores stale events and leaves no later reconnect', t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const h = harness(t);
  h.provider.connect();
  const source = h.sources[0];
  const staleMessage = source.onmessage;
  const staleError = source.onerror;
  source.onerror();
  h.provider.disconnect();
  assert.equal(source.closeCount, 1);
  assert.equal(h.provider.source, null);
  assert.equal(h.statuses.at(-1).state, 'disconnected');
  const count = h.statuses.length;
  staleMessage({ data: JSON.stringify({ type: 'clear' }) });
  staleError();
  t.mock.timers.tick(3600000);
  assert.equal(h.sources.length, 1);
  assert.equal(h.statuses.length, count);
  assert.equal(h.clears, 0);
});

test('a UI callback failure does not interrupt later messages', t => {
  const h = harness(t, { onMessage: () => { throw new Error('UI callback failed'); } });
  h.provider.connect();
  assert.doesNotThrow(() => h.sources[0].receive({ type: 'message', value: { text: 'hello' } }));
  h.sources[0].receive({ type: 'clear' });
  assert.equal(h.clears, 1);
});
