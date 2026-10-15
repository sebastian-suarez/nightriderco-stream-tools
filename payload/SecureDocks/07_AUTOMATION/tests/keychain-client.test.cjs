'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { KeychainClient, ConnectionCredentials, ORIGIN, PORT_KEY } = require('../../shared/keychain-client.js');
const { DockClient } = require('../desktop-dock.js');
const { LayoutClient } = require('../../08_LAYOUT_DOCK/layout-core.js');
const AUTH = 'A'.repeat(43) + '=';
const pending = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };
const tick = () => new Promise(resolve => setImmediate(resolve));
function fakeClient() { return { connections: [], disconnected: 0, connect(value) { this.connections.push(value); }, disconnect() { ++this.disconnected; } }; }
function apiFixture(overrides = {}) {
  return { available: true, status: async () => true, save: async () => {}, authentication: async () => AUTH, forget: async () => {}, ...overrides };
}
function mockSocket() {
  const sockets = [];
  class Socket {
    constructor() { this.readyState = 1; this.sent = []; sockets.push(this); }
    send(raw) { this.sent.push(JSON.parse(raw)); }
    close() { this.readyState = 3; }
    hello(authentication = { salt: 'salt', challenge: 'challenge' }) { this.onmessage({ data: JSON.stringify({ op: 0, d: { rpcVersion: 1, authentication } }) }); }
  }
  return { Socket, sockets };
}

test('Only the exact local helper origin is accepted; file URLs never fetch', async () => {
  for (const origin of ['null', 'http://localhost:17642', 'https://127.0.0.1:17642', 'http://127.0.0.1:4455', 'https://example.com']) {
    const api = new KeychainClient({ location: { origin }, fetch: () => { throw new Error('must not fetch'); } });
    assert.equal(api.available, false);
    await assert.rejects(api.status(4455), /Start the Keychain helper/);
  }
});

test('API uses same-origin POST with required headers and returns only authentication', async () => {
  const calls = [];
  const api = new KeychainClient({ location: { origin: ORIGIN }, fetch: async (url, options) => {
    calls.push({ url, ...options, data: JSON.parse(options.body) });
    return { ok: true, json: async () => url.endsWith('/auth') ? { authentication: AUTH } : { saved: !url.endsWith('/forget') } };
  } });
  assert.equal(await api.status(4455), true);
  await api.save(4455, 'once-only-secret');
  assert.equal(await api.authentication(4455, 'salt', 'challenge'), AUTH);
  await api.forget(4455);
  assert.deepEqual(calls.map(call => call.url), ['/api/status', '/api/save', '/api/auth', '/api/forget']);
  for (const call of calls) {
    assert.equal(call.method, 'POST');
    assert.deepEqual(call.headers, { 'Content-Type': 'application/json', 'X-NRC-Dock': '1' });
    assert.equal(call.credentials, 'omit'); assert.equal(call.cache, 'no-store'); assert.equal(call.redirect, 'error');
  }
  assert.deepEqual(calls[2].data, { port: 4455, salt: 'salt', challenge: 'challenge' });
  assert.equal(calls.filter(call => call.body.includes('once-only-secret')).length, 1);
  assert.equal(Object.values(api).includes('once-only-secret'), false);
});

test('Ports and malformed helper authentication fail before OBS identification', async () => {
  let fetches = 0;
  const api = new KeychainClient({ location: { origin: ORIGIN }, fetch: async () => { ++fetches; return { ok: true, json: async () => ({ authentication: 'plaintext' }) }; } });
  for (const port of [0, 65536, '4455/other', ' 4455', 1.5]) await assert.rejects(api.status(port), /port/);
  assert.equal(fetches, 0);
  await assert.rejects(api.authentication(4455, 's', 'c'), /invalid authentication/);
  await assert.rejects(api.authentication(4455, '', 'c'), /challenge/);
});

test('Helper requests time out even when response headers arrive but the body stalls', async () => {
  let signal;
  const api = new KeychainClient({ location: { origin: ORIGIN }, timeoutMs: 5, fetch: async (url, options) => {
    signal = options.signal;
    return { ok: true, json: () => new Promise(() => {}) };
  } });
  await assert.rejects(api.status(4455), /timed out/);
  assert.equal(signal.aborted, true);
});

test('Save clears the input immediately, then connects with a provider containing no password', async () => {
  const gate = pending(), input = { value: 'one-use-secret' }, client = fakeClient(), writes = [];
  const credentials = new ConnectionCredentials({ api: apiFixture({ save: async (port, secret) => {
    assert.equal(input.value, ''); assert.equal(secret, 'one-use-secret'); assert.equal(port, 4455); await gate.promise;
  } }), storage: { setItem: (...args) => writes.push(args) } });
  const operation = credentials.connect(client, 4455, input);
  assert.equal(input.value, ''); assert.equal(client.connections.length, 0);
  gate.resolve(); await operation;
  assert.equal(client.connections.length, 1);
  assert.equal('password' in client.connections[0], false);
  assert.equal(await client.connections[0].authenticate('s', 'c'), AUTH);
  assert.equal(credentials.state.saved, true);
  assert.deepEqual(writes, [[PORT_KEY, '4455']]);
});

test('Blank input reuses Keychain without saving; initial saved status auto-connects', async () => {
  const api = apiFixture({ save: async () => assert.fail('must not save') }), client = fakeClient();
  const credentials = new ConnectionCredentials({ api, storage: null });
  await credentials.check(client, 4455, true);
  await credentials.connect(client, 4455, { value: '' });
  assert.equal(client.connections.length, 2);
  assert.equal(client.connections.every(connection => typeof connection.authenticate === 'function' && !('password' in connection)), true);
  const empty = new ConnectionCredentials({ api: apiFixture({ status: async () => false }), storage: null });
  await empty.check(client, 4455, true);
  assert.equal(client.connections.length, 2);
});

test('Cancel during a save prevents a delayed result from reconnecting', async () => {
  const gate = pending(), client = fakeClient();
  const credentials = new ConnectionCredentials({ api: apiFixture({ save: async () => gate.promise }), storage: null });
  const operation = credentials.connect(client, 4455, { value: 'save-me' });
  credentials.cancel(); gate.resolve(); await operation;
  assert.equal(client.connections.length, 0); assert.equal(credentials.state.busy, false);
});

test('Out-of-order status responses cannot switch ports or revive an old connection', async () => {
  const first = pending(), second = pending(), client = fakeClient();
  const credentials = new ConnectionCredentials({ api: apiFixture({ status: port => port === 4455 ? first.promise : second.promise }), storage: null });
  const old = credentials.check(client, 4455, true), current = credentials.check(client, 4456, false);
  second.resolve(false); await current; first.resolve(true); await old;
  assert.equal(credentials.state.saved, false); assert.equal(client.connections.length, 0);
});

test('A failed save clears the input and never falls back to plaintext client authentication', async () => {
  const input = { value: 'secret' }, client = fakeClient();
  const credentials = new ConnectionCredentials({ api: apiFixture({ save: async () => { throw new Error('Keychain locked'); } }), storage: null });
  await assert.rejects(credentials.connect(client, 4455, input), /locked/);
  assert.equal(input.value, ''); assert.equal(client.connections.length, 0); assert.equal(credentials.state.busy, false);
});

test('Forget disconnects and removes the current port credential', async () => {
  const forgotten = [], client = fakeClient();
  const credentials = new ConnectionCredentials({ api: apiFixture({ forget: async port => forgotten.push(port) }), storage: null });
  await credentials.check(client, 4455); await credentials.forget(client, 4455);
  assert.equal(client.disconnected, 1); assert.deepEqual(forgotten, [4455]); assert.equal(credentials.state.saved, false);
});

for (const [name, Client] of [['Desktop Switch', DockClient], ['Scene Layout', LayoutClient]]) {
  test(name + ' delegates the challenge and retains no password property', async () => {
    const { Socket, sockets } = mockSocket(), challenges = [];
    const client = new Client({ WebSocket: Socket });
    try {
      client.connect({ authenticate: async (...args) => { challenges.push(args); return AUTH; } });
      assert.equal(Object.prototype.hasOwnProperty.call(client, 'password'), false);
      sockets[0].hello(); await tick();
      assert.deepEqual(challenges, [['salt', 'challenge']]);
      assert.deepEqual(sockets[0].sent, [{ op: 1, d: { rpcVersion: 1, eventSubscriptions: 0, authentication: AUTH } }]);
      assert.equal(client.authenticate, null); assert.equal(client.releaseAuthentication, null);
    } finally { client.disconnect(); }
  });

  test(name + ' ignores an old authentication result and preserves a new connection provider', async () => {
    const { Socket, sockets } = mockSocket(), oldAuth = pending();
    const client = new Client({ WebSocket: Socket });
    try {
      client.connect({ authenticate: () => oldAuth.promise }); sockets[0].hello();
      const currentProvider = async () => AUTH;
      client.connect({ authenticate: currentProvider });
      oldAuth.resolve(AUTH); await tick();
      assert.equal(sockets[0].sent.length, 0); assert.equal(client.authenticate, currentProvider);
      sockets[1].hello(); await tick(); assert.equal(sockets[1].sent.length, 1);
    } finally { client.disconnect(); }
  });

  test(name + ' ignores an old provider failure after disconnect', async () => {
    const { Socket, sockets } = mockSocket(), oldAuth = pending();
    const client = new Client({ WebSocket: Socket });
    try {
      client.connect({ authenticate: () => oldAuth.promise }); sockets[0].hello();
      client.disconnect(); oldAuth.reject(new Error('Old helper error')); await tick();
      assert.equal(client.state.connection, 'offline'); assert.equal(client.state.error, ''); assert.equal(sockets[0].sent.length, 0);
    } finally { client.disconnect(); }
  });
}

test('Both production pages use the shared provider and forbid browser credential persistence', () => {
  const base = path.resolve(__dirname, '../..');
  const shared = fs.readFileSync(path.join(base, 'shared/keychain-client.js'), 'utf8');
  assert.equal((shared.match(/\.setItem\(/g) || []).length, 1);
  assert.match(shared, /setItem\(PORT_KEY, String\(validPort\(port\)\)\)/);
  assert.doesNotMatch(shared, /sessionStorage|indexedDB|document\.cookie/);
  for (const [dir, stem, script] of [['07_AUTOMATION', 'desktop-dock', 'desktop-dock.js'], ['08_LAYOUT_DOCK', 'layout-dock', 'layout-ui.js']]) {
    const html = fs.readFileSync(path.join(base, dir, stem + '.html'), 'utf8');
    const js = fs.readFileSync(path.join(base, dir, script), 'utf8');
    assert.match(html, /\.\.\/shared\/keychain-client\.js/); assert.match(html, /connect-src 'self' ws:\/\/127\.0\.0\.1:\*/);
    assert.match(html, /Forget saved password/); assert.match(html, /macOS Keychain/); assert.match(html, /id="keychain-setup"/);
    assert.doesNotMatch(html, /stays in memory|panel’s memory/);
    assert.doesNotMatch(js, /client\.connect\(\{[^}]*password:/);
    assert.doesNotMatch(js, /localStorage|sessionStorage|indexedDB|document\.cookie/);
  }
});
