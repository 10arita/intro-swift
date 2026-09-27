import test from 'node:test';
import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { handle, normalize, choices, server } from './index.mjs';

test('title normalization and distractors preserve the character class', () => {
  assert.equal(normalize('新時代 (ウタ from ONE PIECE) feat. A'), '新時代');
  assert.equal(normalize('Subtitle - Live Version'), 'SUBTITLE');
  const option = choices('花', '青', ['青花', '青空', '花火', '春風']);
  assert.equal(option.length, 4);
  assert.equal(new Set(option).size, 4);
  assert.ok(option.includes('花'));
  assert.ok(option.every(value => /[\u3400-\u9fff]/u.test(value)));
  assert.ok(!choices('ー', 'マ', ['マー', 'ママ']).filter(value => value !== 'ー').includes('ッ'));
  const famous = choices('花', '', ['花火', '春風'], ['青空', '新時代', '夜に駆ける', '花火', '空']);
  assert.equal(famous.length, 4);
  assert.ok(famous.includes('花'));
  assert.ok(famous.filter(char => char !== '花').every(char => ['青', '新', '夜', '空'].includes(char)));
  const short = choices('花', '', ['花火', '春風'], ['青空', '青い鳥']);
  assert.equal(short.length, 4);
  assert.ok(short.includes('青'));
});

test('catalog exposes only configured original audio', () => {
  const response = handle('GET', '/catalog', {}, new URLSearchParams(), undefined, 'https://quiz.example.com');
  assert.equal(response.status, 200);
  assert.equal(response.body.songs.length, 6);
  assert.ok(response.body.songs.every(song => song.previewURL.startsWith('https://quiz.example.com/media/')));
});

test('Spotify room creation does not wait for external metadata services', async () => {
  const originalFetch = globalThis.fetch;
  let externalCalls = 0;
  globalThis.fetch = () => {
    externalCalls++;
    return new Promise(() => {});
  };
  try {
    const body = { playerId: 'spotify-room-test', name: 'Host', mode: 'spotify', settings: { questionCount: 1 },
      songs: [{ id: 'spotify:AAAAAAAAAAAAAAAAAAAAAA', title: 'Test Song', artist: 'Test Artist' }] };
    const request = Readable.from([Buffer.from(JSON.stringify(body))]);
    request.method = 'POST'; request.url = '/rooms'; request.headers = { host: 'localhost' };
    const result = await new Promise(resolve => {
      const response = {
        writeHead(status) { this.status = status; },
        end(data) { resolve({ status: this.status, body: JSON.parse(data) }); }
      };
      server.emit('request', request, response);
    });
    assert.equal(result.status, 201, JSON.stringify(result.body));
    assert.equal(result.body.mode, 'spotify');
    assert.equal(externalCalls, 1);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('Apple Music rooms accept catalog IDs and keep answers hidden until reveal', () => {
  const song = { id: 'applemusic:1234567890', title: '青い空', artist: 'Artist',
    previewURL: 'https://example.com/should-not-play.mp3' };
  const created = handle('POST', '/rooms', { playerId: 'amHost', name: 'Host', mode: 'applemusic', songs: [song], settings: { questionCount: 1 } }, new URLSearchParams());
  assert.equal(created.status, 201);
  assert.equal(created.body.mode, 'applemusic');
  const token = created.body.sessionToken;
  assert.equal(created.body.preload.length, 1);
  assert.equal(created.body.preload[0].previewURL, null);
  assert.equal(handle('POST', `/rooms/${created.body.id}/start`, { playerId: 'amHost' }, new URLSearchParams(), `Bearer ${token}`).status, 409);
  handle('POST', `/rooms/${created.body.id}/assets-ready`, { playerId: 'amHost' }, new URLSearchParams(), `Bearer ${token}`);
  const started = handle('POST', `/rooms/${created.body.id}/start`, { playerId: 'amHost' }, new URLSearchParams(), `Bearer ${token}`);
  assert.equal(started.body.current.id, song.id);
  assert.equal(started.body.current.title, undefined);
  assert.equal(started.body.current.previewURL, null);
  const invalid = handle('POST', '/rooms', { playerId: 'amInvalid', name: 'Host', mode: 'applemusic',
    songs: [{ ...song, id: 'applemusic:i.12345' }] }, new URLSearchParams());
  assert.equal(invalid.status, 400);
});

test('room API arbitrates PUSH, validates answers, scores, and protects sessions', async () => {
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  const songs = handle('GET', '/catalog', {}, new URLSearchParams(), undefined, 'https://quiz.example.com').body.songs;
  const call = async (path, body, token, method = 'POST') => {
    const url = new URL(path, 'http://localhost');
    const result = handle(method, url.pathname, body || {}, url.searchParams, token ? `Bearer ${token}` : undefined);
    return { status: result.status, value: result.body };
  };
  try {
    const created = await call('/rooms', { playerId: 'p1', name: 'Host',
      settings: { questionCount: 2, answerSlots: 2, targetScore: 0 } });
    assert.equal(created.status, 201);
    const id = created.value.id;
    const hostToken = created.value.sessionToken;
    assert.match(id, /^[A-Z]{6}$/);
    const joined = await call(`/rooms/${id}/join`, { playerId: 'p2', name: 'Guest' });
    assert.equal(joined.status, 200);
    const guestToken = joined.value.sessionToken;
    assert.equal(joined.value.preload.length, 2);
    assert.ok(joined.value.preload.every(asset => !('title' in asset)));
    assert.equal((await call(`/rooms/${id}?playerId=p1`, null, null, 'GET')).status, 403);
    assert.equal((await call(`/rooms/${id}/start`, { playerId: 'p2' }, guestToken)).status, 403);
    assert.equal((await call(`/rooms/${id}/start`, { playerId: 'p1' }, hostToken)).status, 409);
    await call(`/rooms/${id}/assets-ready`, { playerId: 'p1' }, hostToken);
    await call(`/rooms/${id}/assets-ready`, { playerId: 'p2' }, guestToken);
    await call(`/rooms/${id}/assets-unready`, { playerId: 'p2' }, guestToken);
    assert.equal((await call(`/rooms/${id}/start`, { playerId: 'p1' }, hostToken)).status, 409);
    await call(`/rooms/${id}/assets-ready`, { playerId: 'p2' }, guestToken);
    assert.equal((await call(`/rooms/${id}/start`, { playerId: 'p1' }, hostToken)).value.phase, 'preparing');
    await call(`/rooms/${id}/ready`, { playerId: 'p1' }, hostToken);
    now += 9000;
    assert.equal((await call(`/rooms/${id}?playerId=p1`, null, hostToken, 'GET')).value.phase, 'preparing');
    assert.equal((await call(`/rooms/${id}/ready`, { playerId: 'p2' }, guestToken)).value.phase, 'countdown');
    now += 5100;
    const state = (await call(`/rooms/${id}?playerId=p1`, null, hostToken, 'GET')).value;
    assert.equal(state.phase, 'listening');
    assert.equal(state.current.title, undefined);
    assert.equal(state.players.find(p => p.id === 'p1').correctCount, 0);
    assert.equal(state.players.find(p => p.id === 'p1').wrongCount, 0);
    assert.equal(state.players.find(p => p.id === 'p1').pushTimeMS, null);
    const answer = normalize(songs.find(song => song.id === state.current.id).title);
    now += 1200;
    const pushed = await call(`/rooms/${id}/push`, { playerId: 'p1' }, hostToken);
    assert.equal(pushed.value.phase, 'answering');
    assert.equal(pushed.value.players.find(p => p.id === 'p1').pushTimeMS, 1300);
    assert.equal((await call(`/rooms/${id}/push`, { playerId: 'p2' }, guestToken)).status, 200);
    for (const char of answer) {
      const step = await call(`/rooms/${id}/choose`, { playerId: 'p1', choice: char }, hostToken);
      assert.equal(step.status, 200);
    }
    assert.equal((await call(`/rooms/${id}?playerId=p1`, null, hostToken, 'GET')).value.phase, 'answering');
    await call(`/rooms/${id}/choose`, { playerId: 'p2', choice: 'X' }, guestToken);
    const revealed = (await call(`/rooms/${id}?playerId=p1`, null, hostToken, 'GET')).value;
    assert.equal(revealed.phase, 'reveal');
    assert.equal(revealed.players.find(p => p.id === 'p1').score, 20);
    assert.equal(revealed.players.find(p => p.id === 'p1').correctCount, 1);
    assert.equal(revealed.players.find(p => p.id === 'p2').wrongCount, 1);
    assert.deepEqual(revealed.players.find(p => p.id === 'p1').roundResults, ['correct']);
    assert.deepEqual(revealed.players.find(p => p.id === 'p2').roundResults, ['wrong']);
    assert.equal(revealed.current.title, songs.find(song => song.id === state.current.id).title);
    const next = (await call(`/rooms/${id}/next`, { playerId: 'p1' }, hostToken)).value;
    assert.equal(next.phase, 'preparing');
    assert.equal(next.players.find(p => p.id === 'p1').pushTimeMS, null);
    assert.equal(next.players.find(p => p.id === 'p1').correctCount, 1);
    await call(`/rooms/${id}/ready`, { playerId: 'p1' }, hostToken);
    await call(`/rooms/${id}/ready`, { playerId: 'p2' }, guestToken);
    now += 5100;
    const wrong = await call(`/rooms/${id}/push`, { playerId: 'p1' }, hostToken);
    assert.equal(wrong.value.phase, 'answering');
    const failed = await call(`/rooms/${id}/choose`, { playerId: 'p1', choice: 'X' }, hostToken);
    assert.equal(failed.value.phase, 'listening');
    assert.equal(failed.value.players.find(p => p.id === 'p1').score, 0);
    assert.equal(failed.value.players.find(p => p.id === 'p1').lives, 2);
    assert.equal(failed.value.players.find(p => p.id === 'p1').wrongCount, 1);
    const second = await call(`/rooms/${id}/push`, { playerId: 'p2' }, guestToken);
    assert.equal(second.value.phase, 'answering');
    const answer2 = normalize(songs.find(song => song.id === second.value.current.id).title);
    for (const char of answer2) await call(`/rooms/${id}/choose`, { playerId: 'p2', choice: char }, guestToken);
    const final = (await call(`/rooms/${id}?playerId=p2`, null, guestToken, 'GET')).value;
    assert.equal(final.players.find(p => p.id === 'p2').score, 20);
    assert.equal(final.players.find(p => p.id === 'p2').correctCount, 1);
    assert.deepEqual(final.players.find(p => p.id === 'p1').roundResults, ['correct', 'wrong']);
    assert.deepEqual(final.players.find(p => p.id === 'p2').roundResults, ['wrong', 'correct']);
    assert.equal((await call(`/rooms/${id}/next`, { playerId: 'p1' }, hostToken)).value.phase, 'finished');
  } finally {
    Date.now = realNow;
  }
});

function startedThreePlayerRoom(endless, settings = {}) {
  const song = { id: 'spotify:ABCDEFGHIJKLMNOPQRSTUV', title: '花火', artist: 'Artist' };
  const host = handle('POST', '/rooms', { playerId: 'relayA', name: 'A', mode: 'spotify', songs: [song],
    settings: { questionCount: 1, answerSlots: 2, endless, targetScore: 0, ...settings } }, new URLSearchParams()).body;
  const guests = ['relayB', 'relayC'].map((id, index) => handle('POST', `/rooms/${host.id}/join`,
    { playerId: id, name: index ? 'C' : 'B' }, new URLSearchParams()).body);
  const tokens = Object.fromEntries([['relayA', host], ['relayB', guests[0]], ['relayC', guests[1]]]
    .map(([id, state]) => [id, state.sessionToken]));
  const action = (name, id, extra = {}) => handle('POST', `/rooms/${host.id}/${name}`,
    { playerId: id, ...extra }, new URLSearchParams(), `Bearer ${tokens[id]}`);
  const state = id => handle('GET', `/rooms/${host.id}`, {}, new URLSearchParams({ playerId: id }), `Bearer ${tokens[id]}`).body;
  for (const id of Object.keys(tokens)) action('assets-ready', id);
  action('start', 'relayA');
  for (const id of Object.keys(tokens)) action('ready', id);
  return { action, state };
}

test('a rejected simultaneous PUSH keeps the losing player in the room', () => {
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  try {
    const { action, state } = startedThreePlayerRoom(true);
    now += 6000;
    assert.equal(action('push', 'relayA').status, 200);
    const rejected = action('push', 'relayB');
    assert.equal(rejected.status, 409);
    assert.equal(rejected.body.state.players.length, 3);
    assert.deepEqual(rejected.body.state.options, []);
    const loser = state('relayB');
    assert.equal(loser.players.length, 3);
    assert.ok(loser.players.some(player => player.id === 'relayB'));
    assert.equal(loser.answerStatus, null);
    action('choose', 'relayA', { choice: '花' });
    action('choose', 'relayA', { choice: '火' });
    const revealed = state('relayB');
    assert.deepEqual(revealed.players.find(player => player.id === 'relayA').roundResults, ['correct']);
    assert.deepEqual(revealed.players.find(player => player.id === 'relayB').roundResults, [null]);
  } finally { Date.now = realNow; }
});

test('normal mode admits two parallel answers and reveals progress only after slots fill', () => {
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  try {
    const { action, state } = startedThreePlayerRoom(false);
    now += 6000;
    assert.equal(action('push', 'relayA').body.phase, 'answering');
    assert.equal(state('relayB').activeAnswers[0].progress, '');
    action('choose', 'relayA', { choice: '花' });
    assert.equal(state('relayB').activeAnswers[0].progress, '');
    assert.equal(action('push', 'relayB').status, 200);
    assert.equal(action('push', 'relayC').status, 409);
    assert.deepEqual(state('relayC').activeAnswers.map(a => a.progress), ['花', '']);
    action('choose', 'relayA', { choice: 'X' });
    assert.equal(state('relayC').phase, 'answering');
    assert.equal(action('push', 'relayA').status, 409);
    action('choose', 'relayB', { choice: '花' });
    action('choose', 'relayB', { choice: '火' });
    assert.equal(state('relayC').phase, 'reveal');
    assert.equal(state('relayC').correctPlayerID, 'relayB');
  } finally { Date.now = realNow; }
});

test('normal mode keeps accepting PUSH after an early correct answer and ranks both correct players', () => {
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  try {
    const { action, state } = startedThreePlayerRoom(false);
    now += 6000;
    action('push', 'relayA');
    action('choose', 'relayA', { choice: '花' });
    action('choose', 'relayA', { choice: '火' });
    const stillOpen = state('relayB');
    assert.equal(stillOpen.phase, 'listening');
    assert.equal(stillOpen.pushClosed, false);
    assert.equal(stillOpen.current.title, undefined);
    assert.equal(stillOpen.correctPlayerIDs.length, 0);
    assert.equal(stillOpen.players.find(p => p.id === 'relayA').score, 0);
    assert.equal(state('relayA').answerStatus, 'correct');
    assert.equal(action('push', 'relayB').status, 200);
    assert.equal(state('relayC').phase, 'answering');
    assert.equal(state('relayC').pushClosed, true);
    assert.equal(state('relayC').correctPlayerIDs.length, 0);
    action('choose', 'relayB', { choice: '花' });
    action('choose', 'relayB', { choice: '火' });
    const revealed = state('relayC');
    assert.equal(revealed.phase, 'reveal');
    assert.deepEqual(revealed.correctPlayerIDs, ['relayA', 'relayB']);
    assert.equal(revealed.players.find(p => p.id === 'relayA').score, 20);
    assert.equal(revealed.players.find(p => p.id === 'relayB').score, 10);
  } finally { Date.now = realNow; }
});

test('normal mode ranks correct answers by PUSH order even when completion order differs', () => {
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  try {
    const { action, state } = startedThreePlayerRoom(false);
    now += 6000;
    action('push', 'relayA');
    action('push', 'relayB');
    action('choose', 'relayB', { choice: '花' });
    action('choose', 'relayB', { choice: '火' });
    assert.equal(state('relayC').phase, 'answering');
    assert.equal(state('relayC').activeAnswers.length, 1);
    action('choose', 'relayA', { choice: '花' });
    action('choose', 'relayA', { choice: '火' });
    assert.deepEqual(state('relayC').correctPlayerIDs, ['relayA', 'relayB']);
    assert.equal(state('relayC').players.find(p => p.id === 'relayA').score, 20);
    assert.equal(state('relayC').players.find(p => p.id === 'relayB').score, 10);
  } finally { Date.now = realNow; }
});

test('normal mode closes PUSH when no eligible player remains, even with unused slots', () => {
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  try {
    const { action, state } = startedThreePlayerRoom(false, { answerSlots: 4 });
    now += 6000;
    for (const id of ['relayA', 'relayB', 'relayC']) action('push', id);
    assert.equal(state('relayA').pushClosed, true);
    assert.equal(state('relayA').phase, 'answering');
    action('choose', 'relayA', { choice: '花' });
    action('choose', 'relayA', { choice: '火' });
    assert.equal(state('relayA').phase, 'answering');
    action('choose', 'relayB', { choice: 'X' });
    action('choose', 'relayC', { choice: 'X' });
    assert.equal(state('relayA').phase, 'reveal');
  } finally { Date.now = realNow; }
});

test('normal mode lets active answers finish after the 30-second PUSH deadline', () => {
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  try {
    const { action, state } = startedThreePlayerRoom(false);
    now += 6000;
    action('push', 'relayA');
    action('choose', 'relayA', { choice: 'X' });
    assert.equal(state('relayC').phase, 'listening');
    assert.equal(state('relayC').pushedIds.length, 1);
    assert.equal(action('push', 'relayA').status, 409);
    now += 28_000;
    assert.equal(action('push', 'relayB').status, 200);
    now += 1000;
    const closed = state('relayC');
    assert.equal(closed.phase, 'answering');
    assert.equal(closed.pushClosed, true);
    assert.ok(closed.audioStoppedAt);
    assert.equal(action('push', 'relayC').status, 409);
    action('choose', 'relayB', { choice: '花' });
    now += 3000;
    action('choose', 'relayB', { choice: '火' });
    assert.equal(state('relayC').phase, 'reveal');
    assert.equal(state('relayC').correctPlayerID, 'relayB');
  } finally { Date.now = realNow; }
});

test('endless mode freezes the round clock and resumes from each paused position', () => {
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  try {
    const { action, state } = startedThreePlayerRoom(true);
    now += 6000;
    const first = action('push', 'relayA').body;
    assert.equal(first.pausedPositionMS, 1000);
    assert.equal(action('push', 'relayB').status, 409);
    action('choose', 'relayA', { choice: '花' });
    assert.equal(state('relayC').activeAnswers[0].progress, '花');
    now += 4000;
    action('choose', 'relayA', { choice: 'X' });
    const resumed = state('relayC');
    assert.equal(resumed.phase, 'listening');
    assert.equal(resumed.pausedAt, null);
    assert.equal(resumed.startAt, first.startAt + 4000);
    assert.equal(resumed.roundDeadline, first.roundDeadline + 4000);
    now += 2000;
    const second = action('push', 'relayB').body;
    assert.equal(second.pausedPositionMS, 3000);
    assert.equal(state('relayA').activeAnswers[0].progress, '');
    now += 5000;
    assert.equal(state('relayA').phase, 'listening');
    assert.equal(state('relayA').roundDeadline, second.roundDeadline + 5000);
    assert.equal(action('push', 'relayB').status, 409);
    assert.equal(action('push', 'relayC').status, 200);
    action('choose', 'relayC', { choice: 'X' });
    assert.equal(state('relayA').phase, 'reveal');
  } finally { Date.now = realNow; }
});

test('endless relay resumes when the answering player leaves', () => {
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  try {
    const { action, state } = startedThreePlayerRoom(true);
    now += 6000;
    action('push', 'relayA');
    action('leave', 'relayA');
    assert.equal(state('relayB').phase, 'listening');
    assert.equal(state('relayB').pausedAt, null);
    assert.equal(action('push', 'relayB').status, 200);
    action('choose', 'relayB', { choice: 'X' });
    assert.equal(action('push', 'relayC').status, 200);
  } finally { Date.now = realNow; }
});

test('all wrong answers reveal the song even when every player loses their last life', () => {
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  try {
    const { action, state } = startedThreePlayerRoom(true, { lives: 1 });
    now += 6000;
    for (const id of ['relayA', 'relayB', 'relayC']) {
      action('push', id);
      action('choose', id, { choice: 'X' });
    }
    assert.equal(state('relayA').phase, 'reveal');
    assert.equal(state('relayA').current.title, '花火');
  } finally { Date.now = realNow; }
});

test('unanimous skip reveals and host role transfers on leave', () => {
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  const dispatch = (path, body, token) => {
    const result = handle('POST', path, body, new URLSearchParams(), token ? `Bearer ${token}` : undefined);
    return result.body;
  };
  try {
    const host = dispatch('/rooms', { playerId: 'skipHost', name: 'Host', settings: { questionCount: 1 } }, undefined);
    const guest = dispatch(`/rooms/${host.id}/join`, { playerId: 'skipGuest', name: 'Guest' }, undefined);
    dispatch(`/rooms/${host.id}/assets-ready`, { playerId: 'skipHost' }, host.sessionToken);
    dispatch(`/rooms/${host.id}/assets-ready`, { playerId: 'skipGuest' }, guest.sessionToken);
    dispatch(`/rooms/${host.id}/start`, { playerId: 'skipHost' }, host.sessionToken);
    dispatch(`/rooms/${host.id}/ready`, { playerId: 'skipHost' }, host.sessionToken);
    dispatch(`/rooms/${host.id}/ready`, { playerId: 'skipGuest' }, guest.sessionToken);
    now += 5100;
    const skipped = dispatch(`/rooms/${host.id}/skip`, { playerId: 'skipHost' }, host.sessionToken);
    assert.equal(skipped.phase, 'listening');
    assert.deepEqual(skipped.skippedIds, ['skipHost']);
    assert.equal(dispatch(`/rooms/${host.id}/skip`, { playerId: 'skipGuest' }, guest.sessionToken).phase, 'reveal');
    dispatch(`/rooms/${host.id}/leave`, { playerId: 'skipHost' }, host.sessionToken);
    const state = handle('GET', `/rooms/${host.id}`, {}, new URLSearchParams({ playerId: 'skipGuest' }), `Bearer ${guest.sessionToken}`).body;
    assert.equal(state.hostId, 'skipGuest');
    assert.equal(state.players.length, 1);
  } finally { Date.now = realNow; }
});

test('profile needs its secret and stores five results', () => {
  const id = `profile-${Date.now()}`;
  const register = handle('POST', '/profile', { id }, new URLSearchParams());
  assert.equal(register.status, 201);
  assert.ok(register.body.token);
  const auth = `Bearer ${register.body.token}`;
  assert.equal(handle('GET', '/profile', {}, new URLSearchParams({ id })).status, 403);
  const history = Array.from({ length: 8 }, (_, index) => ({ id: index }));
  assert.equal(handle('PUT', '/profile', { id, history, stats: { games: 8 } }, new URLSearchParams(), auth).status, 200);
  const loaded = handle('GET', '/profile', {}, new URLSearchParams({ id }), auth);
  assert.equal(loaded.body.history.length, 5);
  assert.equal(loaded.body.stats.games, 8);
  assert.equal(loaded.body.secret, undefined);
});

test('Spotify rooms hide the title, accept readiness, and allow a lobby host transfer', () => {
  const song = { id: 'spotify:1234567890123456789012', title: '怪獣の花唄', artist: 'Vaundy',
    previewURL: null, durationMS: 220000, genre: 'Pop' };
  const host = handle('POST', '/rooms', { playerId: 'spHost', name: 'Host', mode: 'spotify', songs: [song], settings: { questionCount: 1 } }, new URLSearchParams()).body;
  assert.equal(host.mode, 'spotify');
  assert.equal(host.current, null);
  const guest = handle('POST', `/rooms/${host.id}/join`, { playerId: 'spGuest', name: 'Guest' }, new URLSearchParams()).body;
  const call = (action, playerId, token, extra = {}) => handle('POST', `/rooms/${host.id}/${action}`,
    { playerId, ...extra }, new URLSearchParams(), `Bearer ${token}`).body;
  call('transfer', 'spHost', host.sessionToken, { targetId: 'spGuest' });
  call('assets-ready', 'spHost', host.sessionToken);
  call('assets-ready', 'spGuest', guest.sessionToken);
  assert.equal(call('start', 'spGuest', guest.sessionToken).phase, 'preparing');
  assert.equal(call('ready', 'spHost', host.sessionToken).phase, 'preparing');
  const countdown = call('ready', 'spGuest', guest.sessionToken);
  assert.equal(countdown.phase, 'countdown');
  assert.equal(countdown.current.id, song.id);
  assert.equal(countdown.current.title, undefined);
});

test('first room letter prefers the current artist top songs', () => {
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  try {
    const song = { id: 'spotify:ABCDEFGHIJKLMNOPQRSTUV', title: '花火', artist: 'Artist',
      artistTopTitles: ['青空', '新時代', '夜に駆ける', '花火'] };
    const created = handle('POST', '/rooms', { playerId: 'topHost', name: 'Host', mode: 'spotify',
      songs: [song], settings: { questionCount: 1 } }, new URLSearchParams()).body;
    const post = action => handle('POST', `/rooms/${created.id}/${action}`, { playerId: 'topHost' },
      new URLSearchParams(), `Bearer ${created.sessionToken}`).body;
    post('assets-ready'); post('start'); post('ready');
    now += 5100;
    assert.deepEqual(new Set(post('push').options), new Set(['花', '青', '新', '夜']));
  } finally { Date.now = realNow; }
});

test('sabitro rooms accept only matched HTTPS previews', () => {
  const invalid = handle('POST', '/rooms', { playerId: 'badPreview', name: 'Host', mode: 'sabitro',
    songs: [{ id: 'itunes:1', title: '夜に駆ける', artist: 'YOASOBI', previewURL: 'http://unsafe.example/a.m4a' }] }, new URLSearchParams());
  assert.equal(invalid.status, 400);
  const valid = handle('POST', '/rooms', { playerId: 'goodPreview', name: 'Host', mode: 'sabitro',
    songs: [{ id: 'itunes:1', title: '夜に駆ける', artist: 'YOASOBI', previewURL: 'https://audio.example/a.m4a',
      durationMS: 30000, genre: 'J-Pop' }], settings: { questionCount: 1 } }, new URLSearchParams());
  assert.equal(valid.status, 201);
  assert.equal(valid.body.mode, 'sabitro');
});
