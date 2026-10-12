import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { handle, server } from './index.mjs';

function withClock(run) {
  const original = Date.now;
  let now = original();
  Date.now = () => now;
  try { run(ms => { now += ms; }); }
  finally { Date.now = original; }
}

function lobby({ deferred = false } = {}) {
  const query = new URLSearchParams();
  const host = randomUUID();
  const created = handle('POST', '/rooms', { playerId: host, name: 'Host', mode: 'applemusic',
    deferQuestions: deferred, settings: { questionCount: 1, targetScore: 0 },
    songs: [{ id: 'applemusic:123', title: '青', artist: 'Artist' }] }, query);
  assert.equal(created.status, 201);
  const path = `/rooms/${created.body.id}`;
  const tokens = new Map([[host, created.body.sessionToken]]);
  const join = (id = randomUUID()) => {
    const result = handle('POST', `${path}/join`, { playerId: id, name: 'Guest' }, query);
    assert.equal(result.status, 200);
    tokens.set(id, result.body.sessionToken);
    return { id, state: result.body };
  };
  const send = (id, action, payload = {}) => handle('POST', `${path}/${action}`,
    { playerId: id, ...payload }, query, `Bearer ${tokens.get(id)}`);
  const state = id => handle('GET', path, {}, new URLSearchParams({ playerId: id }),
    `Bearer ${tokens.get(id)}`);
  return { host, join, send, state, path, tokens };
}

test('host sessions expire after the same grace period as guest sessions', () => withClock(advance => {
  const room = lobby();
  const guest = room.join().id;
  advance(299_999);
  assert.equal(room.state(guest).status, 200);
  advance(2);
  assert.equal(room.state(room.host).status, 403, 'An expired host must not revive its old membership');
  const state = room.state(guest).body;
  assert.equal(state.hostId, guest);
  assert.deepEqual(state.players.map(player => player.id), [guest]);
}));

test('a host can still restore its session within the grace period', () => withClock(advance => {
  const room = lobby();
  advance(299_999);
  assert.equal(room.state(room.host).status, 200);
}));

test('leaving and rejoining a lobby requires preparing assets again', () => {
  const room = lobby();
  const guest = room.join().id;
  room.send(room.host, 'assets-ready');
  room.send(guest, 'assets-ready');
  assert.equal(room.send(guest, 'leave').status, 200);
  const rejoined = room.join(guest).state;
  assert.ok(!rejoined.assetsReadyIds.includes(guest));
  assert.equal(room.send(room.host, 'start').status, 409);
  room.send(guest, 'assets-ready');
  assert.equal(room.send(room.host, 'start').body.phase, 'preparing');
});

test('leaving and rejoining during preparation does not reuse old readiness', () => {
  const room = lobby();
  room.send(room.host, 'assets-ready');
  assert.equal(room.send(room.host, 'start').body.phase, 'preparing');
  const guest = room.join().id;
  const third = room.join().id;
  room.send(guest, 'ready');
  room.send(guest, 'leave');
  const rejoined = room.join(guest).state;
  assert.ok(!rejoined.readyIds.includes(guest));
  room.send(room.host, 'ready');
  assert.equal(room.send(third, 'ready').body.phase, 'preparing');
  assert.equal(room.send(guest, 'ready').body.phase, 'countdown');
});

for (const cause of ['leave', 'expiry']) {
  test(`automatic host transfer clears the previous library after ${cause}`, () => withClock(advance => {
    const room = lobby({ deferred: true });
    const guest = room.join().id;
    room.send(room.host, 'lobby-config', {
      settings: { questionCount: 1 }, playlist: { name: 'Previous host library', songCount: 10 }
    });
    if (cause === 'leave') room.send(room.host, 'leave');
    else {
      advance(299_999);
      room.state(guest);
      advance(2);
    }
    const state = room.state(guest).body;
    assert.equal(state.hostId, guest);
    assert.equal(state.playlist, null);
  }));
}

test('GET requests cannot start a game or remove a member', () => {
  const room = lobby();
  room.send(room.host, 'assets-ready');
  for (const action of ['start', 'leave']) {
    const result = handle('GET', `${room.path}/${action}`, {},
      new URLSearchParams({ playerId: room.host }), `Bearer ${room.tokens.get(room.host)}`);
    assert.equal(result.status, 405);
    assert.equal(room.state(room.host).body.phase, 'lobby');
  }
});

test('malformed request URLs return 400 without rejecting the HTTP handler', async () => {
  for (const url of ['http://[invalid', 'http://%']) {
    let status, body;
    await server.listeners('request')[0]({ url, method: 'GET' }, {
      writeHead(value) { status = value; },
      end(value) { body = JSON.parse(value); }
    });
    assert.equal(status, 400);
    assert.equal(body.error, 'Bad request');
  }
});
