import test from 'node:test';
import assert from 'node:assert/strict';
import { handle } from './index.mjs';
function lobby(prefix) {
  const q = new URLSearchParams();
  const hostID = `${prefix}-host`, guestID = `${prefix}-guest`;
  const created = handle('POST', '/rooms', { playerId: hostID, name: 'Host', mode: 'applemusic', deferQuestions: true }, q);
  assert.equal(created.status, 201);
  const path = `/rooms/${created.body.id}`;
  const joined = handle('POST', `${path}/join`, { playerId: guestID, name: 'Guest' }, q);
  assert.equal(joined.status, 200);
  const send = (id, token, action, payload = {}) => handle('POST', `${path}/${action}`,
    { playerId: id, ...payload }, q, `Bearer ${token}`);
  return {
    host: (action, payload) => send(hostID, created.body.sessionToken, action, payload),
    guest: (action, payload) => send(guestID, joined.body.sessionToken, action, payload),
    state: () => handle('GET', path, {}, new URLSearchParams({ playerId: guestID }), `Bearer ${joined.body.sessionToken}`),
    hostID, guestID
  };
}
const rules = { questionCount: 2, answerSlots: 1, targetScore: 100, correctPoints: 20,
  firstBonus: 10, wrongPenalty: 10, firstWrongPenalty: 0, lives: 5, endless: true };
const playlist = { name: '夜に聴く曲', songCount: 32 };

test('current app rooms cannot start alone, including after a guest leaves', () => {
  const query = new URLSearchParams();
  const created = handle('POST', '/rooms', { playerId: 'minimum-host', name: 'Host',
    mode: 'applemusic', deferQuestions: true, minimumPlayers: 2 }, query);
  assert.equal(created.status, 201);
  const path = `/rooms/${created.body.id}`;
  const send = payload => handle('POST', `${path}/start`, { playerId: 'minimum-host',
    settings: { questionCount: 1 }, songs: [{ id: 'applemusic:1000000001', title: '青空', artist: 'Artist' }],
    ...payload }, query, `Bearer ${created.body.sessionToken}`);
  assert.equal(send().status, 409);
  const guest = handle('POST', `${path}/join`, { playerId: 'minimum-guest', name: 'Guest' }, query);
  assert.equal(guest.status, 200);
  assert.equal(handle('POST', `${path}/leave`, { playerId: 'minimum-guest' }, query,
    `Bearer ${guest.body.sessionToken}`).status, 200);
  assert.equal(send().status, 409);
  assert.equal(handle('POST', `${path}/join`, { playerId: 'minimum-guest', name: 'Guest' }, query).status, 200);
  assert.equal(send().body.phase, 'preparing');
});

test('host settings and playlist reach guests while handicaps survive changes', () => {
  const room = lobby('display-sync');
  assert.equal(room.host('handicaps', { handicaps: { [room.guestID]: 4 } }).status, 200);
  assert.equal(room.host('lobby-config', { settings: rules, playlist }).status, 200);
  const state = room.state().body;
  assert.equal(state.supportsLobbyConfiguration, true);
  assert.deepEqual(state.playlist, playlist);
  for (const [key, value] of Object.entries(rules)) assert.equal(state.settings[key], value);
  assert.equal(state.settings.handicaps[room.guestID], 4);
  assert.deepEqual(state.roundSongs, []);
  assert.equal(state.current, null);
  assert.equal(room.host('lobby-config', { settings: rules, playlist: null }).status, 200);
  assert.equal(room.state().body.playlist, null);
});

test('guests cannot edit and invalid metadata cannot partially apply', () => {
  const room = lobby('display-auth');
  room.host('lobby-config', { settings: rules, playlist });
  assert.equal(room.guest('lobby-config', { settings: { lives: 1 }, playlist: null }).status, 403);
  for (const invalid of [[], { name: '', songCount: 1 }, { name: 'X', songCount: -1 },
    { name: 'X', songCount: 1.5 }, { name: 'X'.repeat(121), songCount: 1 }]) {
    assert.equal(room.host('lobby-config', { settings: { lives: 1 }, playlist: invalid }).status, 400);
    assert.equal(room.state().body.settings.lives, rules.lives);
    assert.deepEqual(room.state().body.playlist, playlist);
  }
  assert.equal(room.host('lobby-config', { settings: [], playlist }).status, 400);
});

test('host transfer clears the previous library and moves edit permission', () => {
  const room = lobby('display-transfer');
  room.host('lobby-config', { settings: rules, playlist });
  assert.equal(room.host('transfer', { targetId: room.guestID }).status, 200);
  assert.equal(room.state().body.playlist, null);
  assert.equal(room.host('lobby-config', { settings: rules, playlist }).status, 403);
  assert.equal(room.guest('lobby-config', { settings: rules, playlist }).status, 200);
});

test('history discloses only revealed songs and lobby editing stops after start', () => {
  const originalNow = Date.now;
  let now = originalNow(); Date.now = () => now;
  try {
    const room = lobby('display-history');
    room.host('lobby-config', { settings: { ...rules, endless: false }, playlist });
    const songs = [
      { id: 'applemusic:1000000001', title: '青空', artist: 'Artist A' },
      { id: 'applemusic:1000000002', title: '春風', artist: 'Artist B' }
    ];
    const started = room.host('start', { settings: { ...rules, endless: false }, songs, playlist });
    assert.equal(started.status, 200);
    assert.deepEqual(started.body.roundSongs, []);
    assert.equal(started.body.current.title, undefined);
    assert.equal(room.host('lobby-config', { settings: rules, playlist: null }).status, 403);
    room.host('ready'); room.guest('ready'); now += 5100;
    assert.deepEqual(room.state().body.roundSongs, []);
    room.host('skip'); const revealed = room.guest('skip');
    assert.equal(revealed.body.phase, 'reveal');
    assert.equal(revealed.body.roundSongs.length, 1);
    assert.equal(revealed.body.roundSongs[0].title, revealed.body.current.title);
    assert.equal(revealed.body.roundSongs[0].previewURL, undefined);
    const next = room.host('next');
    assert.equal(next.status, 200);
    assert.equal(next.body.roundSongs.length, 1);
    assert.equal(next.body.current.title, undefined);
    assert.notEqual(next.body.current.id, next.body.roundSongs[0].id);
  } finally { Date.now = originalNow; }
});
