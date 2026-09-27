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
    const body = { playerId: 'spotify-room-test', name: 'Host', mode: 'spotify',
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
  const created = handle('POST', '/rooms', { playerId: 'amHost', name: 'Host', mode: 'applemusic', songs: [song] }, new URLSearchParams());
  assert.equal(created.status, 201);
  assert.equal(created.body.mode, 'applemusic');
  const token = created.body.sessionToken;
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
    assert.equal((await call(`/rooms/${id}?playerId=p1`, null, null, 'GET')).status, 403);
    assert.equal((await call(`/rooms/${id}/start`, { playerId: 'p2' }, guestToken)).status, 403);
    assert.equal((await call(`/rooms/${id}/start`, { playerId: 'p1' }, hostToken)).value.phase, 'preparing');
    await call(`/rooms/${id}/ready`, { playerId: 'p1' }, hostToken);
    assert.equal((await call(`/rooms/${id}/ready`, { playerId: 'p2' }, guestToken)).value.phase, 'countdown');
    now += 3100;
    const state = (await call(`/rooms/${id}?playerId=p1`, null, hostToken, 'GET')).value;
    assert.equal(state.phase, 'listening');
    assert.equal(state.current.title, undefined);
    const answer = normalize(songs.find(song => song.id === state.current.id).title);
    const pushed = await call(`/rooms/${id}/push`, { playerId: 'p1' }, hostToken);
    assert.equal(pushed.value.phase, 'answering');
    assert.equal((await call(`/rooms/${id}/push`, { playerId: 'p2' }, guestToken)).status, 409);
    for (const char of answer) {
      const step = await call(`/rooms/${id}/choose`, { playerId: 'p1', choice: char }, hostToken);
      assert.equal(step.status, 200);
    }
    const revealed = (await call(`/rooms/${id}?playerId=p1`, null, hostToken, 'GET')).value;
    assert.equal(revealed.phase, 'reveal');
    assert.equal(revealed.players.find(p => p.id === 'p1').score, 20);
    assert.equal(revealed.current.title, songs.find(song => song.id === state.current.id).title);
    const next = (await call(`/rooms/${id}/next`, { playerId: 'p1' }, hostToken)).value;
    assert.equal(next.phase, 'preparing');
    await call(`/rooms/${id}/ready`, { playerId: 'p1' }, hostToken);
    await call(`/rooms/${id}/ready`, { playerId: 'p2' }, guestToken);
    now += 3100;
    const wrong = await call(`/rooms/${id}/push`, { playerId: 'p1' }, hostToken);
    assert.equal(wrong.value.phase, 'answering');
    const failed = await call(`/rooms/${id}/choose`, { playerId: 'p1', choice: 'X' }, hostToken);
    assert.equal(failed.value.phase, 'listening');
    assert.equal(failed.value.players.find(p => p.id === 'p1').score, 0);
    assert.equal(failed.value.players.find(p => p.id === 'p1').lives, 2);
    const second = await call(`/rooms/${id}/push`, { playerId: 'p2' }, guestToken);
    assert.equal(second.value.phase, 'answering');
    const answer2 = normalize(songs.find(song => song.id === second.value.current.id).title);
    for (const char of answer2) await call(`/rooms/${id}/choose`, { playerId: 'p2', choice: char }, guestToken);
    const final = (await call(`/rooms/${id}?playerId=p2`, null, guestToken, 'GET')).value;
    assert.equal(final.players.find(p => p.id === 'p2').score, 10);
    assert.equal((await call(`/rooms/${id}/next`, { playerId: 'p1' }, hostToken)).value.phase, 'finished');
  } finally {
    Date.now = realNow;
  }
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
    const host = dispatch('/rooms', { playerId: 'skipHost', name: 'Host' }, undefined);
    const guest = dispatch(`/rooms/${host.id}/join`, { playerId: 'skipGuest', name: 'Guest' }, undefined);
    dispatch(`/rooms/${host.id}/start`, { playerId: 'skipHost' }, host.sessionToken);
    dispatch(`/rooms/${host.id}/ready`, { playerId: 'skipHost' }, host.sessionToken);
    dispatch(`/rooms/${host.id}/ready`, { playerId: 'skipGuest' }, guest.sessionToken);
    now += 3100;
    assert.equal(dispatch(`/rooms/${host.id}/skip`, { playerId: 'skipHost' }, host.sessionToken).phase, 'listening');
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
  const host = handle('POST', '/rooms', { playerId: 'spHost', name: 'Host', mode: 'spotify', songs: [song] }, new URLSearchParams()).body;
  assert.equal(host.mode, 'spotify');
  assert.equal(host.current, null);
  const guest = handle('POST', `/rooms/${host.id}/join`, { playerId: 'spGuest', name: 'Guest' }, new URLSearchParams()).body;
  const call = (action, playerId, token, extra = {}) => handle('POST', `/rooms/${host.id}/${action}`,
    { playerId, ...extra }, new URLSearchParams(), `Bearer ${token}`).body;
  call('transfer', 'spHost', host.sessionToken, { targetId: 'spGuest' });
  assert.equal(call('start', 'spGuest', guest.sessionToken).phase, 'preparing');
  assert.equal(call('ready', 'spHost', host.sessionToken).phase, 'preparing');
  const countdown = call('ready', 'spGuest', guest.sessionToken);
  assert.equal(countdown.phase, 'countdown');
  assert.equal(countdown.current.id, song.id);
  assert.equal(countdown.current.title, undefined);
});

test('sabitro rooms accept only matched HTTPS previews', () => {
  const invalid = handle('POST', '/rooms', { playerId: 'badPreview', name: 'Host', mode: 'sabitro',
    songs: [{ id: 'itunes:1', title: '夜に駆ける', artist: 'YOASOBI', previewURL: 'http://unsafe.example/a.m4a' }] }, new URLSearchParams());
  assert.equal(invalid.status, 400);
  const valid = handle('POST', '/rooms', { playerId: 'goodPreview', name: 'Host', mode: 'sabitro',
    songs: [{ id: 'itunes:1', title: '夜に駆ける', artist: 'YOASOBI', previewURL: 'https://audio.example/a.m4a',
      durationMS: 30000, genre: 'J-Pop' }] }, new URLSearchParams());
  assert.equal(valid.status, 201);
  assert.equal(valid.body.mode, 'sabitro');
});
