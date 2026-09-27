import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { Readable } from 'node:stream';
import { server } from './index.mjs';

class TestResponse extends EventEmitter {
  frames = [];
  destroyed = false;
  constructor() {
    super();
    this.completed = new Promise(resolve => { this.resolve = resolve; });
  }
  writeHead(status, headers) { this.status = status; this.headers = headers; }
  flushHeaders() {}
  write(frame) { this.frames.push(frame); this.emit('frame'); return true; }
  end(body = '') {
    if (this.destroyed) return;
    this.destroyed = true;
    this.body = body;
    this.emit('close');
    this.resolve();
  }
}

function dispatch(method, path, body, token) {
  const request = Readable.from(body ? [Buffer.from(JSON.stringify(body))] : []);
  request.method = method;
  request.url = path;
  request.headers = { host: 'localhost', ...(token ? { authorization: `Bearer ${token}` } : {}) };
  const response = new TestResponse();
  server.emit('request', request, response);
  return response;
}

async function post(path, playerId, token, extra = {}) {
  const response = dispatch('POST', path, { playerId, ...extra }, token);
  await response.completed;
  return { status: response.status, body: JSON.parse(response.body) };
}

function eventReader(response) {
  let index = 0;
  return async (predicate, timeoutMS = 2_000) => {
    const deadline = Date.now() + timeoutMS;
    while (Date.now() < deadline) {
      while (index < response.frames.length) {
        const frame = response.frames[index++];
        const data = frame.split('\n').find(line => line.startsWith('data: '));
        if (data) {
          const state = JSON.parse(data.slice(6));
          if (predicate(state)) return state;
        }
      }
      await new Promise((resolve, reject) => {
        const timeout = setTimeout(() => reject(new Error('SSE update timed out')), deadline - Date.now());
        response.once('frame', () => { clearTimeout(timeout); resolve(); });
      });
    }
    throw new Error('SSE update timed out');
  };
}

test('authenticated room streams push private state and timed phase changes', async () => {
  const responses = [];
  try {
    const created = await post('/rooms', 'stream-host', null,
      { name: 'Host', settings: { questionCount: 1, targetScore: 0 } });
    assert.equal(created.status, 201);
    const id = created.body.id;
    const hostToken = created.body.sessionToken;
    const joined = await post(`/rooms/${id}/join`, 'stream-guest', null, { name: 'Guest' });
    assert.equal(joined.status, 200);
    const guestToken = joined.body.sessionToken;
    const unauthorized = dispatch('GET', `/rooms/${id}/events?playerId=stream-guest`, null, hostToken);
    await unauthorized.completed;
    assert.equal(unauthorized.status, 403);

    const hostStream = dispatch('GET', `/rooms/${id}/events?playerId=stream-host`, null, hostToken);
    const guestStream = dispatch('GET', `/rooms/${id}/events?playerId=stream-guest`, null, guestToken);
    responses.push(hostStream, guestStream);
    assert.equal(hostStream.status, 200);
    assert.match(hostStream.headers['Content-Type'], /^text\/event-stream/);
    const host = eventReader(hostStream);
    let guest = eventReader(guestStream);
    await host(state => state.id === id);
    await guest(state => state.id === id);
    const reconnected = dispatch('GET', `/rooms/${id}/events?playerId=stream-guest`, null, guestToken);
    responses.push(reconnected);
    assert.equal(guestStream.destroyed, true);
    guest = eventReader(reconnected);
    await guest(state => state.id === id);

    await post(`/rooms/${id}/assets-ready`, 'stream-host', hostToken);
    const ready = await guest(state => state.assetsReadyIds.includes('stream-host'));
    assert.equal(ready.sessionToken, undefined);
    await post(`/rooms/${id}/assets-ready`, 'stream-guest', guestToken);
    await post(`/rooms/${id}/start`, 'stream-host', hostToken);
    await post(`/rooms/${id}/ready`, 'stream-host', hostToken);
    await post(`/rooms/${id}/ready`, 'stream-guest', guestToken);
    const countdown = await guest(state => state.phase === 'countdown');
    assert.equal(countdown.current.title, undefined);
    const listening = await guest(state => state.phase === 'listening', 6_000);
    assert.ok(listening.sequence > countdown.sequence);

    await post(`/rooms/${id}/push`, 'stream-host', hostToken);
    const hostAnswer = await host(state => state.phase === 'answering');
    const guestAnswer = await guest(state => state.phase === 'answering');
    assert.equal(hostAnswer.options.length, 4);
    assert.deepEqual(guestAnswer.options, []);
    assert.equal(guestAnswer.current.title, undefined);
  } finally {
    responses.forEach(response => response.end());
  }
});
