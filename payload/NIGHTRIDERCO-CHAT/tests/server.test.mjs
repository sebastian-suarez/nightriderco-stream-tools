import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, rm, symlink, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { createServer, getAnonymousToken, getConnection, normalizeSlug, resolveChannel,
  validChannelId, validClientId } from '../server.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const token = `server-test-${process.pid}-${Date.now()}`;
const publicFile = resolve(root, 'public', `${token}.json`);
const privateFile = resolve(root, `${token}.json`);
const siblingDirectory = resolve(root, `public-${token}`);
const symlinkFile = resolve(root, 'public', `${token}-link.json`);
const payload = JSON.stringify({ test: 'public fixture' });
const secret = JSON.stringify({ secret: 'must never leave public root' });
let server;
const port = 3377;
let sequence = 0;
const clientId = 'a1b2c3d4-1234-4567-abcd-0123456789ab';
const socketUrl = 'wss://realtime.us-east-1.platform.kick.com/connection/websocket';
const connectionToken = 'anonymous-test-token';

function descriptor(url = socketUrl) {
  return { data: { connections: [{ provider: 'centrifugo', credentials: { url } }] } };
}

function jsonResponse(data) { return { ok: true, json: async () => data }; }

function nextSlug() { return `test_${process.pid}_${++sequence}`; }

// Exercise the real HTTP handler without listening on a socket or making network calls.
async function request(path, { method = 'GET', headers = {} } = {}) {
  const response = { status: 200, headers: {}, body: '' };
  const req = {
    method, url: path,
    headers: Object.fromEntries(Object.entries({ Host: `127.0.0.1:${port}`, ...headers })
      .map(([name, value]) => [name.toLowerCase(), value])),
  };
  const res = {
    setHeader(name, value) { response.headers[name.toLowerCase()] = String(value); },
    writeHead(status, headers = {}) {
      response.status = status;
      for (const [name, value] of Object.entries(headers)) this.setHeader(name, value);
      return this;
    },
    end(body = '') { response.body = String(body); },
  };
  await server.listeners('request')[0](req, res);
  return response;
}

before(async () => {
  await mkdir(resolve(root, 'public'), { recursive: true });
  await mkdir(siblingDirectory);
  await Promise.all([
    writeFile(publicFile, payload),
    writeFile(privateFile, secret),
    writeFile(resolve(siblingDirectory, 'secret.json'), secret),
  ]);
  await symlink(privateFile, symlinkFile);
  server = createServer();
});

after(async () => {
  await Promise.all([
    rm(publicFile, { force: true }),
    rm(privateFile, { force: true }),
    rm(symlinkFile, { force: true }),
    rm(siblingDirectory, { recursive: true, force: true }),
  ]);
});

test('normalizes valid channel names and rejects URL syntax and non-string input', () => {
  assert.equal(normalizeSlug('NightRiderCO'), 'nightriderco');
  assert.equal(normalizeSlug('Channel_123-Name'), 'channel_123-name');
  assert.equal(normalizeSlug('a'.repeat(60)), 'a'.repeat(60));
  for (const value of [null, undefined, 123, {}, [], '', 'a'.repeat(61), 'two words',
    'https://kick.com/channel', '../channel', 'channel?x=1', 'channel#fragment', 'café', ' channel ']) {
    assert.equal(normalizeSlug(value), null, `accepted ${JSON.stringify(value)}`);
  }
});

test('resolves upstream IDs and caches successful results without another lookup', async () => {
  const slug = nextSlug();
  let calls = 0;
  const fetcher = async (url, options) => {
    calls++;
    assert.equal(url, `https://kick.com/api/v2/channels/${slug}`);
    assert.equal(options.redirect, 'error');
    assert.ok(options.signal instanceof AbortSignal);
    return { ok: true, json: async () => ({ id: 4321, chatroom: { id: '123456' } }) };
  };
  const result = await resolveChannel(slug, fetcher);
  assert.equal(result.slug, slug);
  assert.equal(result.roomId, 123456);
  assert.equal(result.channelId, 4321);
  assert.deepEqual(await resolveChannel(slug, () => { throw new Error('cache missed'); }), result);
  assert.equal(calls, 1);
});

test('simultaneous requests share one lookup and settle to the same result', async () => {
  const slug = nextSlug();
  let release;
  let calls = 0;
  const gate = new Promise(resolveGate => { release = resolveGate; });
  const fetcher = async () => {
    calls++;
    await gate;
    return { ok: true, json: async () => ({ id: 4322, chatroom: { id: 234567 } }) };
  };
  const first = resolveChannel(slug, fetcher);
  const second = resolveChannel(slug, fetcher);
  assert.equal(calls, 1);
  release();
  const results = await Promise.all([first, second]);
  assert.deepEqual(results[0], results[1]);
  assert.equal(results[0].roomId, 234567);
});

test('upstream errors give a useful message and do not poison retries', async () => {
  for (const status of [404, 403, 500]) {
    const slug = nextSlug();
    await assert.rejects(resolveChannel(slug, async () => ({ ok: false, status })),
      status === 404 ? /channel not found/i : /chat-room ID/i);
    assert.equal((await resolveChannel(slug, async () => ({
      ok: true, json: async () => ({ id: 4323, chatroom: { id: 345678 } }),
    }))).roomId, 345678);
  }
});

test('invalid upstream room IDs are rejected instead of cached', async () => {
  for (const id of [undefined, null, '', 0, -1, 1.5, 'not-an-id', Number.MAX_SAFE_INTEGER + 1]) {
    await assert.rejects(resolveChannel(nextSlug(), async () => ({
      ok: true, json: async () => ({ id: 4324, chatroom: { id } }),
    })), /valid chat room/i);
  }
});

test('invalid upstream channel IDs are rejected before caching', async () => {
  for (const id of [undefined, null, '', 0, -1, 1.5, 'not-an-id', Number.MAX_SAFE_INTEGER + 1]) {
    await assert.rejects(resolveChannel(nextSlug(), async () => jsonResponse({
      id, chatroom: { id: 567890 },
    })), /valid channel ID/i);
  }
});

test('a failed JSON response is cleared so the next request can succeed', async () => {
  const slug = nextSlug();
  await assert.rejects(resolveChannel(slug, async () => ({
    ok: true, json: async () => { throw new SyntaxError('malformed upstream JSON'); },
  })), /malformed upstream JSON/);
  assert.equal((await resolveChannel(slug, async () => ({
    ok: true, json: async () => ({ id: 4325, chatroom: { id: 456789 } }),
  }))).roomId, 456789);
});

test('serves public assets with safety headers and correct HEAD behavior', async () => {
  const path = `/${token}.json`;
  const get = await request(path);
  assert.equal(get.status, 200);
  assert.equal(get.body, payload);
  assert.match(get.headers['content-type'], /^application\/json/);
  assert.equal(Number(get.headers['content-length']), Buffer.byteLength(payload));
  assert.equal(get.headers['x-content-type-options'], 'nosniff');
  assert.equal(get.headers['referrer-policy'], 'no-referrer');
  assert.equal(get.headers['cache-control'], 'no-store');
  assert.match(get.headers['content-security-policy'], /object-src 'none'/);
  const head = await request(path, { method: 'HEAD' });
  assert.equal(head.status, 200);
  assert.equal(head.body, '');
  assert.equal(head.headers['content-length'], get.headers['content-length']);
});

test('accepts only loopback Host names and matching origins', async () => {
  const path = `/${token}.json`;
  for (const host of [`127.0.0.1:${port}`, `localhost:${port}`]) {
    assert.equal((await request(path, { headers: { Host: host, Origin: `http://${host}` } })).status, 200);
  }
  for (const host of ['example.com', '127.0.0.1.example.com', 'localhost.example.com',
    '0.0.0.0', '192.168.1.2']) {
    const response = await request(path, { headers: { Host: host } });
    assert.equal(response.status, 403, `allowed Host ${host}`);
  }
  for (const origin of ['https://example.com', 'null', `http://localhost:${port}`, 'http://127.0.0.1']) {
    assert.equal((await request(path, { headers: { Origin: origin } })).status, 403, `allowed Origin ${origin}`);
  }
});

test('rejects write methods and reports the supported methods', async () => {
  for (const method of ['POST', 'PUT', 'DELETE', 'PATCH']) {
    const response = await request(`/${token}.json`, { method });
    assert.equal(response.status, 405);
    assert.equal(response.headers.allow, 'GET, HEAD');
  }
});

test('does not expose server files, siblings, encoded traversal, or symlink targets', async () => {
  for (const path of ['/server.mjs', '/package.json', `/${token}-link.json`,
    `/..%2f${token}.json`, `/%2e%2e%2f${token}.json`,
    `/assets/..%2f..%2f${token}.json`,
    `/..%2fpublic-${token}%2fsecret.json`,
    `/%252e%252e%252f${token}.json`]) {
    const response = await request(path);
    assert.equal(response.status, 404, `exposed ${path}`);
    assert.ok(!response.body.includes('must never leave public root'));
  }
});

test('returns a client error for malformed path encoding and a 404 for missing assets', async () => {
  assert.equal((await request('/%FF')).status, 400);
  assert.equal((await request('/%')).status, 400);
  assert.equal((await request(`/${token}-missing.json`)).status, 404);
  assert.equal((await request('/http', { headers: { Host: 'localhost:65536' } })).status, 400);
  assert.equal((await request('http://[invalid')).status, 400);
});

test('channel endpoint validates before any network lookup', async t => {
  const fetcher = t.mock.method(globalThis, 'fetch', async () => { throw new Error('Unexpected network lookup'); });
  for (const query of ['', '?slug=', '?slug=../../secret', '?slug=two%20words', '?slug=https%3A%2F%2Fkick.com%2Fname']) {
    const response = await request(`/api/kick/channel${query}`);
    assert.equal(response.status, 400);
    assert.match(JSON.parse(response.body).error, /valid Kick channel name/i);
  }
  assert.equal(fetcher.mock.callCount(), 0);
});

test('channel endpoint resolves the configured channel from cache without network access', async t => {
  const fetcher = t.mock.method(globalThis, 'fetch', async () => { throw new Error('Unexpected network lookup'); });
  const response = await request('/api/kick/channel?slug=NIGHTRIDERCO');
  assert.equal(response.status, 200);
  assert.match(response.headers['content-type'], /^application\/json/);
  const data = JSON.parse(response.body);
  assert.equal(data.slug, 'nightriderco');
  assert.equal(data.roomId, 132926621);
  assert.equal(data.channelId, 133224609);
  assert.equal(fetcher.mock.callCount(), 0);
});

test('connection identifiers reject missing, malformed, and unsafe values', () => {
  assert.equal(validClientId(clientId), true);
  assert.equal(validClientId(clientId.toUpperCase()), true);
  for (const value of [null, undefined, '', 'client', clientId + '-extra', {}, []]) {
    assert.equal(validClientId(value), false);
  }
  for (const value of [1, '1', 133224609, '133224609', Number.MAX_SAFE_INTEGER]) {
    assert.equal(validChannelId(value), true);
  }
  for (const value of [null, undefined, '', ' ', 0, -1, 1.5, '1e3', '1/connection',
    Number.MAX_SAFE_INTEGER + 1, '99999999999999999', {}, [], [123]]) {
    assert.equal(validChannelId(value), false, `accepted ${JSON.stringify(value)}`);
  }
});

test('connection discovery requests the channel transport then an anonymous token', async () => {
  const calls = [];
  const result = await getConnection(clientId, '133224609', async (url, options) => {
    calls.push({ url, options });
    return jsonResponse(calls.length === 1 ? descriptor() : { data: { token: connectionToken } });
  });
  assert.deepEqual(result, { url: socketUrl, token: connectionToken });
  assert.equal(calls.length, 2);
  assert.equal(calls[0].url, 'https://web.kick.com/api/v1/realtime/channels/133224609/chat/connection');
  assert.deepEqual(JSON.parse(calls[0].options.body), {
    client: { id: clientId, type: 'web' },
    capabilities: { accepted_providers: [{ provider: 'centrifugo' }] },
  });
  assert.equal(calls[1].url, 'https://web.kick.com/api/v1/realtime/auth/connection');
  assert.deepEqual(JSON.parse(calls[1].options.body), { client_id: clientId });
  for (const { options } of calls) {
    assert.equal(options.method, 'POST');
    assert.equal(options.redirect, 'error');
    assert.ok(options.signal instanceof AbortSignal);
  }
});

test('connection discovery supports the generic transport when no channel ID is supplied', async () => {
  const urls = [];
  const result = await getConnection(clientId, null, async url => {
    urls.push(url);
    return jsonResponse(urls.length === 1 ? descriptor() : { data: { token: connectionToken } });
  });
  assert.equal(urls[0], 'https://web.kick.com/api/v1/realtime/connection');
  assert.equal(result.url, socketUrl);
});

test('connection discovery rejects hostile WebSocket descriptors before requesting a token', async () => {
  for (const url of ['ws://realtime.us-east-1.platform.kick.com/connection/websocket',
    'wss://evil.example/connection/websocket',
    'wss://realtime.us-east-1.platform.kick.com.evil.example/connection/websocket',
    'wss://evil.realtime.us-east-1.platform.kick.com/connection/websocket',
    'wss://127.0.0.1/connection/websocket',
    'wss://user:password@realtime.us-east-1.platform.kick.com/connection/websocket',
    'wss://realtime.us-east-1.platform.kick.com:444/connection/websocket',
    `${socketUrl}?token=untrusted`, `${socketUrl}#fragment`, `${socketUrl}/extra`]) {
    let calls = 0;
    await assert.rejects(getConnection(clientId, 133224609, async () => {
      calls++;
      return jsonResponse(descriptor(url));
    }), /unrecognized chat transport/i);
    assert.equal(calls, 1, `requested credentials for ${url}`);
  }
});

test('missing or malformed supported transport produces an actionable error', async () => {
  for (const data of [null, {}, { data: {} }, { data: { connections: [] } },
    { data: { connections: {} } }, { data: { connections: [{ provider: 'unknown' }] } },
    { data: { connections: [{ provider: 'centrifugo', credentials: {} }] } }]) {
    await assert.rejects(getConnection(clientId, null, async () => jsonResponse(data)), /no supported chat transport/i);
  }
});

test('connection and token requests reject invalid identifiers without calling upstream', async () => {
  let calls = 0;
  const fetcher = async () => { calls++; throw new Error('Unexpected upstream call'); };
  await assert.rejects(getConnection('not-a-client', null, fetcher), /invalid connection request/i);
  await assert.rejects(getConnection(clientId, '../123', fetcher), /invalid connection request/i);
  await assert.rejects(getAnonymousToken('not-a-client', fetcher), /invalid client ID/i);
  assert.equal(calls, 0);
});

test('backend failures and invalid anonymous tokens are rejected', async () => {
  await assert.rejects(getConnection(clientId, null, async () => ({ ok: false, status: 503 })), /returned 503.*reconnect/i);
  await assert.rejects(getAnonymousToken(clientId, async () => ({ ok: false, status: 403 })), /returned 403.*reconnect/i);
  for (const token of [null, undefined, {}, [], '', 'short', 'a'.repeat(20_001)]) {
    await assert.rejects(getAnonymousToken(clientId, async () => jsonResponse({ data: { token } })),
      /anonymous connection token/i);
  }
});

test('realtime routes reject malformed identifiers without calling upstream', async t => {
  const fetcher = t.mock.method(globalThis, 'fetch', async () => { throw new Error('Unexpected network lookup'); });
  for (const path of ['/api/kick/connection', '/api/kick/token?clientId=bad',
    `/api/kick/connection?clientId=${clientId}&channelId=bad`,
    `/api/kick/connection?clientId=${clientId}&channelId=9007199254740992`]) {
    const response = await request(path);
    assert.equal(response.status, 400);
    assert.match(JSON.parse(response.body).error, /invalid connection request/i);
  }
  assert.equal(fetcher.mock.callCount(), 0);
});

test('realtime routes return validated connection data and make token renewal available', async t => {
  t.mock.method(globalThis, 'fetch', async url => jsonResponse(
    url.endsWith('/auth/connection') ? { data: { token: connectionToken } } : descriptor()));
  const connection = await request(`/api/kick/connection?clientId=${clientId}&channelId=133224609`);
  assert.equal(connection.status, 200);
  assert.deepEqual(JSON.parse(connection.body), { url: socketUrl, token: connectionToken });
  const token = await request(`/api/kick/token?clientId=${clientId}`);
  assert.equal(token.status, 200);
  assert.deepEqual(JSON.parse(token.body), { token: connectionToken });
  assert.equal(token.headers['cache-control'], 'no-store');
});

test('realtime routes turn timeouts into a reconnect message', async t => {
  t.mock.method(globalThis, 'fetch', async () => { throw new DOMException('timed out', 'TimeoutError'); });
  const response = await request(`/api/kick/connection?clientId=${clientId}`);
  assert.equal(response.status, 502);
  assert.match(JSON.parse(response.body).error, /too long.*reconnect/i);
});
