import test from 'node:test';
import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { handle, normalize, choices, server } from './index.mjs';

test('title normalization and distractor priorities', () => {
  assert.equal(normalize('新時代 (ウタ from ONE PIECE) feat. A'), '新時代');
  assert.equal(normalize('Subtitle - Live Version'), 'SUBTITLE');
  assert.equal(normalize('Bling-Bang-Bang-Born'), 'BLING-BANG-BANG-BORN');
  assert.equal(normalize('さよーならまたいつか！-Sayonara'), 'さよーならまたいつか');
  assert.equal(normalize('青い空♪- Live Version'), '青い空');
  assert.equal(normalize('青い空（Live）'), '青い空');
  assert.equal(normalize('青い空 feat. 歌手'), '青い空');
  assert.equal(normalize('青い空~Live'), '青い空');
  assert.equal(normalize('青い空〜Live'), '青い空');
  assert.equal(normalize('青い空～Live'), '青い空');
  assert.equal(normalize('Defeat'), 'DEFEAT');
  assert.equal(normalize('スーパー・スター☆'), 'スーパースター');
  assert.equal(normalize('ﾏｰ'), 'マー');
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
  const topSix = choices('花', '', [], ['花火', '青空', '新時代', '夜に駆ける', '空', '月', '星'], '花火');
  assert.equal(topSix.length, 4);
  assert.ok(topSix.every(char => ['花', '青', '新', '夜', '空', '月'].includes(char)));
  assert.ok(!topSix.includes('星'));
  assert.deepEqual(new Set(choices('ボ', 'シンデレラ', [
    'シンデレラボーイ', 'シンデレラガール', 'シンデレラストーリー', 'シンデレラナイト'
  ])), new Set(['ボ', 'ガ', 'ス', 'ナ']));
  assert.deepEqual(new Set(choices('星', 'の', [
    'の星', 'の中', '君の君', '夜の君', '僕の日', '夏の日'
  ])), new Set(['星', '中', '君', '日']));
  const fallback = choices('C', 'ZZ', []);
  assert.equal(fallback.length, 4);
  assert.ok(fallback.every(char => /^[A-Z]$/.test(char)));
});

test('a long vowel mark is required in the answer', () => {
  const originalNow = Date.now;
  let now = originalNow();
  Date.now = () => now;
  try {
    const created = handle('POST', '/rooms', {
      playerId: 'long-vowel-host', name: 'Host', mode: 'applemusic',
      songs: [{ id: 'applemusic:1000000001', title: 'マー', artist: 'Artist' }],
      settings: { questionCount: 1 }
    }, new URLSearchParams());
    assert.equal(created.status, 201);
    const path = `/rooms/${created.body.id}`;
    const auth = `Bearer ${created.body.sessionToken}`;
    const send = (action, payload = {}) => handle('POST', `${path}/${action}`,
      { playerId: 'long-vowel-host', ...payload }, new URLSearchParams(), auth);
    send('assets-ready');
    send('start');
    send('ready');
    now += 5100;
    assert.equal(send('push').status, 200);
    const first = send('choose', { choice: 'マ' });
    assert.equal(first.body.answerProgress, 'マ');
    assert.ok(first.body.options.includes('ー'));
    const completed = send('choose', { choice: 'ー' });
    assert.equal(completed.body.phase, 'reveal');
    assert.equal(completed.body.current.title, 'マー');
    assert.equal(completed.body.players[0].currentResult, 'correct');
  } finally {
    Date.now = originalNow;
  }
});

test('answers finish before tilde suffixes while revealing the full title', () => {
  const originalNow = Date.now;
  let now = originalNow();
  Date.now = () => now;
  try {
    for (const [index, separator] of ['~', '〜', '～'].entries()) {
      const title = `青い空${separator}Live`;
      const playerId = `tilde-host-${index}`;
      const created = handle('POST', '/rooms', {
        playerId, name: 'Host', mode: 'applemusic',
        songs: [{ id: `applemusic:100000001${index}`, title, artist: 'Artist' }],
        settings: { questionCount: 1 }
      }, new URLSearchParams());
      assert.equal(created.status, 201);
      const path = `/rooms/${created.body.id}`;
      const auth = `Bearer ${created.body.sessionToken}`;
      const send = (action, payload = {}) => handle('POST', `${path}/${action}`,
        { playerId, ...payload }, new URLSearchParams(), auth);
      send('assets-ready');
      send('start');
      send('ready');
      now += 5100;
      assert.equal(send('push').status, 200);
      for (const choice of '青い空') {
        const result = send('choose', { choice });
        assert.equal(result.status, 200);
        if (choice === '空') {
          assert.equal(result.body.phase, 'reveal');
          assert.equal(result.body.current.title, title);
          assert.equal(result.body.players[0].currentResult, 'correct');
        }
      }
    }
  } finally { Date.now = originalNow; }
});

test('a hyphen within an English song title is required in the answer', () => {
  const created = handle('POST', '/rooms', {
    playerId: 'hyphen-host', name: 'Host', mode: 'applemusic',
    songs: [{ id: 'applemusic:1000000002', title: 'Bling-Bang-Bang-Born', artist: 'Artist' }],
    settings: { questionCount: 1 }
  }, new URLSearchParams());
  assert.equal(created.status, 201);
  const path = `/rooms/${created.body.id}`;
  const auth = `Bearer ${created.body.sessionToken}`;
  const send = (action, payload = {}) => handle('POST', `${path}/${action}`,
    { playerId: 'hyphen-host', ...payload }, new URLSearchParams(), auth);
  send('assets-ready');
  send('start');
  send('ready');
  const originalNow = Date.now;
  const now = Date.now() + 5100;
  Date.now = () => now;
  try {
    assert.equal(send('push').status, 200);
    for (const character of normalize('Bling-Bang-Bang-Born')) {
      const result = send('choose', { choice: character });
      assert.equal(result.status, 200);
    }
    const state = handle('GET', path, {},
      new URLSearchParams({ playerId: 'hyphen-host' }), auth);
    assert.equal(state.body.phase, 'reveal');
    assert.equal(state.body.players[0].currentResult, 'correct');
  } finally { Date.now = originalNow; }
});

test('room friends require approval and invitations join without entering a code', () => {
  const query = new URLSearchParams();
  const alice = handle('POST', '/profile', { id: 'friend-alice' }, query).body;
  const bob = handle('POST', '/profile', { id: 'friend-bob' }, query).body;
  const charlie = handle('POST', '/profile', { id: 'friend-charlie' }, query).body;
  const room = handle('POST', '/rooms', { playerId: 'friend-alice', profileId: alice.id,
    profileToken: alice.token, name: 'Alice', settings: { questionCount: 1 } }, query).body;
  const roomPath = `/rooms/${room.id}`;
  const guest = handle('POST', `${roomPath}/join`, { playerId: 'friend-bob', profileId: bob.id,
    profileToken: bob.token, name: 'Bob' }, query).body;
  const asAlice = (action, payload = {}) => handle('POST', `${roomPath}/${action}`,
    { playerId: 'friend-alice', ...payload }, query, `Bearer ${room.sessionToken}`);
  const asBob = (action, payload = {}) => handle('POST', `${roomPath}/${action}`,
    { playerId: 'friend-bob', ...payload }, query, `Bearer ${guest.sessionToken}`);
  assert.equal(asAlice('invite', { targetProfileId: bob.id }).status, 403);
  assert.equal(asAlice('friend-request', { targetId: 'friend-charlie' }).status, 400);
  assert.equal(asAlice('friend-request', { targetId: 'friend-bob' }).status, 200);
  assert.equal(asAlice('friend-request', { targetId: 'friend-bob' }).status, 409);
  const bobList = handle('GET', '/friends', {}, new URLSearchParams({ profileId: bob.id }), `Bearer ${bob.token}`);
  assert.equal(bobList.body.requests.length, 1);
  assert.equal(handle('GET', '/friends', {}, new URLSearchParams({ profileId: bob.id }), `Bearer ${charlie.token}`).status, 403);
  assert.equal(handle('POST', '/friends/accept', { profileId: bob.id,
    requestId: bobList.body.requests[0].id }, query, `Bearer ${bob.token}`).status, 200);
  assert.equal(handle('PUT', '/profile', { id: bob.id,
    stats: { games: 2, attempts: 8, correct: 5, privateNote: 'do not share' } },
  query, `Bearer ${bob.token}`).status, 200);
  const friendProfile = handle('GET', '/player-profile', {},
    new URLSearchParams({ profileId: alice.id, friendId: bob.id }), `Bearer ${alice.token}`);
  assert.equal(friendProfile.status, 200);
  assert.equal(friendProfile.body.name, 'Bob');
  assert.equal(friendProfile.body.secret, undefined);
  assert.equal(friendProfile.body.stats.correct, 5);
  assert.equal(friendProfile.body.stats.privateNote, undefined);
  assert.equal(handle('GET', '/player-profile', {},
    new URLSearchParams({ profileId: charlie.id, friendId: bob.id }), `Bearer ${charlie.token}`).status, 404);
  const roomProfile = handle('GET', '/player-profile', {},
    new URLSearchParams({ roomId: room.id, playerId: alice.id, targetPlayerId: bob.id }),
    `Bearer ${room.sessionToken}`);
  assert.equal(roomProfile.status, 200);
  assert.equal(roomProfile.body.name, 'Bob');
  assert.equal(roomProfile.body.roomScore, 0);
  assert.equal(handle('GET', '/player-profile', {},
    new URLSearchParams({ roomId: room.id, playerId: alice.id, targetPlayerId: bob.id }),
    `Bearer ${charlie.token}`).status, 403);
  assert.equal(asAlice('invite', { targetProfileId: bob.id }).status, 409);
  assert.equal(asBob('leave').status, 200);
  assert.equal(asAlice('invite', { targetProfileId: bob.id }).status, 200);
  assert.deepEqual(handle('GET', '/friends', {},
    new URLSearchParams({ profileId: alice.id }), `Bearer ${alice.token}`).body.sentInvites,
  [{ roomId: room.id, targetId: bob.id }]);
  assert.equal(asAlice('invite', { targetProfileId: bob.id }).status, 409);
  const afterInvite = handle('GET', roomPath, {},
    new URLSearchParams({ playerId: 'friend-alice' }), `Bearer ${room.sessionToken}`);
  assert.ok(afterInvite.body.players.some(player => player.id === 'friend-alice'));
  const invitation = handle('GET', '/friends', {}, new URLSearchParams({ profileId: bob.id }), `Bearer ${bob.token}`).body.invites[0];
  assert.ok(invitation.id);
  const accepted = handle('POST', '/friends/invites/join', { profileId: bob.id,
    inviteId: invitation.id, playerId: 'friend-bob', name: 'Bob' }, query, `Bearer ${bob.token}`);
  assert.equal(accepted.status, 200);
  assert.equal(accepted.body.id, room.id);
  assert.ok(accepted.body.sessionToken);
  assert.equal(accepted.body.players.find(player => player.id === 'friend-alice').friendStatus, 'friend');
  assert.equal(accepted.body.players.find(player => player.id === 'friend-alice').friendProfileId, alice.id);
  assert.equal(handle('GET', '/friends', {}, new URLSearchParams({ profileId: bob.id }), `Bearer ${bob.token}`).body.invites.length, 0);
  assert.deepEqual(handle('GET', '/friends', {},
    new URLSearchParams({ profileId: alice.id }), `Bearer ${alice.token}`).body.sentInvites, []);
});

test('room player profile is available before a profile is linked', () => {
  const query = new URLSearchParams();
  const room = handle('POST', '/rooms', {
    playerId: 'profile-view-host', name: 'Host', settings: { questionCount: 1 }
  }, query).body;
  const guest = handle('POST', `/rooms/${room.id}/join`, {
    playerId: 'profile-view-guest', name: 'Guest'
  }, query).body;
  const result = handle('GET', '/player-profile', {}, new URLSearchParams({
    roomId: room.id, playerId: 'profile-view-host', targetPlayerId: 'profile-view-guest'
  }), `Bearer ${room.sessionToken}`);
  assert.equal(result.status, 200);
  assert.equal(result.body.name, 'Guest');
  assert.equal(result.body.stats, null);
  assert.equal(result.body.roomScore, 0);
  assert.equal(handle('GET', '/player-profile', {}, new URLSearchParams({
    roomId: room.id, playerId: 'profile-view-guest', targetPlayerId: 'profile-view-host'
  }), `Bearer ${guest.sessionToken}`).status, 200);
});

test('catalog exposes only configured original audio', () => {
  const response = handle('GET', '/catalog', {}, new URLSearchParams(), undefined, 'https://quiz.example.com');
  assert.equal(response.status, 200);
  assert.equal(response.body.songs.length, 6);
  assert.ok(response.body.songs.every(song => song.previewURL.startsWith('https://quiz.example.com/media/')));
});

test('room snapshots share bounded player icons with other players', () => {
  const avatar = Buffer.from([0xff, 0xd8, 0xff, 0xd9]).toString('base64');
  const created = handle('POST', '/rooms', { playerId: 'avatar-host', name: 'Host', avatar,
    settings: { questionCount: 1 } }, new URLSearchParams());
  assert.equal(created.status, 201);
  const joined = handle('POST', `/rooms/${created.body.id}/join`,
    { playerId: 'avatar-guest', name: 'Guest', avatar: 'not-an-image' }, new URLSearchParams());
  assert.equal(joined.status, 200);
  assert.equal(joined.body.players.find(player => player.id === 'avatar-host').avatar, avatar);
  assert.equal(joined.body.players.find(player => player.id === 'avatar-guest').avatar, null);
  const detailed = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff]), Buffer.alloc(30_000)]).toString('base64');
  const detailedPlayer = handle('POST', `/rooms/${created.body.id}/join`,
    { playerId: 'avatar-detailed', name: 'Detailed', avatar: detailed }, new URLSearchParams());
  assert.equal(detailedPlayer.body.players.find(player => player.id === 'avatar-detailed').avatar, detailed);
  const oversized = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff]), Buffer.alloc(64_001)]).toString('base64');
  const another = handle('POST', `/rooms/${created.body.id}/join`,
    { playerId: 'avatar-third', name: 'Third', avatar: oversized }, new URLSearchParams());
  assert.equal(another.body.players.find(player => player.id === 'avatar-third').avatar, null);
});

test('Apple Music room creation does not wait for external metadata services', async () => {
  const originalFetch = globalThis.fetch;
  let externalCalls = 0;
  globalThis.fetch = () => {
    externalCalls++;
    return new Promise(() => {});
  };
  try {
    const body = { playerId: 'applemusic-room-test', name: 'Host', mode: 'applemusic', settings: { questionCount: 1 },
      songs: [{ id: 'applemusic:1000000003', title: 'Test Song', artist: 'Test Artist' }] };
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
    assert.equal(result.body.mode, 'applemusic');
    assert.equal(externalCalls, 0);
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

test('unsupported music providers cannot create rooms', () => {
  const result = handle('POST', '/rooms', {
    playerId: 'old-provider', name: 'Host', mode: 'spotify',
    songs: [{ id: 'spotify:1234567890123456789012', title: '花火', artist: 'Artist' }]
  }, new URLSearchParams());
  assert.equal(result.status, 400);
});

for (const chorusMS of [56494.88, 0]) test(`a retried Apple Music choice is applied once and retains chorus ${chorusMS}`, () => {
  const originalNow = Date.now;
  let now = originalNow();
  Date.now = () => now;
  try {
    const created = handle('POST', '/rooms', {
      playerId: 'retry-host', name: 'Host', mode: 'applemusic',
      songs: [{ id: 'applemusic:1234567890', title: '青い空', artist: 'Artist',
        durationMS: 181234, chorusMS }],
      settings: { questionCount: 1 }
    }, new URLSearchParams());
    const path = `/rooms/${created.body.id}`;
    const auth = `Bearer ${created.body.sessionToken}`;
    const send = (action, payload = {}) => handle('POST', `${path}/${action}`,
      { playerId: 'retry-host', ...payload }, new URLSearchParams(), auth);
    send('assets-ready');
    send('start');
    send('ready');
    now += 5100;
    assert.equal(send('push').status, 200);
    const actionId = 'first-letter-retry';
    const first = send('choose', { choice: '青', actionId });
    assert.equal(first.body.answerProgress, '青');
    const duplicate = send('choose', { choice: '青', actionId });
    assert.equal(duplicate.status, 200);
    assert.equal(duplicate.body.answerProgress, '青');
    assert.equal(duplicate.body.players[0].wrongCount, 0);
    assert.equal(send('choose', { choice: 'い', actionId: 'second-letter' }).body.answerProgress, '青い');
    const completed = send('choose', { choice: '空', actionId: 'final-letter' });
    assert.equal(completed.body.phase, 'reveal');
    assert.equal(completed.body.current.chorusMS, Math.round(chorusMS));
  } finally {
    Date.now = originalNow;
  }
});

for (const mode of ['applemusic', 'shared']) test(`${mode} room reveals the Songle chorus position`, async () => {
  const originalFetch = globalThis.fetch;
  const originalNow = Date.now;
  let now = originalNow();
  Date.now = () => now;
  const requests = [];
  const songs = mode === 'applemusic'
    ? [{ id: 'applemusic:1234567890', title: '青い空', artist: '歌手', durationMS: 180000 }]
    : handle('GET', '/catalog', {}, new URLSearchParams()).body.songs;
  const chorusStart = mode === 'applemusic' ? 65000 : 20000;
  globalThis.fetch = async url => {
    const address = new URL(url);
    requests.push(address);
    if (address.pathname.endsWith('/songs/search.json')) return new Response(JSON.stringify(songs.map(song => ({
      title: song.title, artist: { name: song.artist }, duration: song.durationMS,
      permalink: `http://www.youtube.com/watch?v=${mode}-chorus-test`
    }))), { status: 200 });
    if (address.pathname.endsWith('/song/chorus.json')) return new Response(JSON.stringify({
      chorusSegments: [{ isChorus: true, repeats: [{ start: chorusStart }] }]
    }), { status: 200 });
    throw new Error(`Unexpected URL: ${address}`);
  };
  try {
    const playerId = `${mode}-chorus-host`;
    const created = handle('POST', '/rooms', { playerId, name: 'Host', mode,
      songs, settings: { questionCount: 1 } }, new URLSearchParams());
    assert.equal(created.status, 201);
    const id = created.body.id;
    const authorization = `Bearer ${created.body.sessionToken}`;
    assert.equal(handle('POST', `/rooms/${id}/assets-ready`, { playerId },
      new URLSearchParams(), authorization).status, 200);
    const request = Readable.from([Buffer.from(JSON.stringify({ playerId }))]);
    request.method = 'POST'; request.url = `/rooms/${id}/start`;
    request.headers = { host: 'localhost', authorization };
    const started = await new Promise(resolve => {
      const response = {
        writeHead(status) { this.status = status; },
        end(data) { resolve({ status: this.status, body: JSON.parse(data) }); }
      };
      server.emit('request', request, response);
    });
    assert.equal(started.status, 200);
    assert.equal(started.body.current.chorusMS, undefined, 'Do not disclose chorus metadata before reveal');
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(requests.length, 2);
    assert.equal(requests[1].searchParams.get('url'), `www.youtube.com/watch?v=${mode}-chorus-test`);
    const ready = handle('POST', `/rooms/${id}/ready`, { playerId },
      new URLSearchParams(), authorization);
    assert.equal(ready.body.phase, 'countdown');
    now += 5100;
    const revealed = handle('POST', `/rooms/${id}/skip`, { playerId },
      new URLSearchParams(), authorization);
    assert.equal(revealed.body.phase, 'reveal');
    assert.equal(revealed.body.current.chorusMS, chorusStart - 1500);
  } finally {
    globalThis.fetch = originalFetch;
    Date.now = originalNow;
  }
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
    assert.deepEqual(pushed.value.pushOrderIds, ['p1']);
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
    assert.equal(revealed.players.find(p => p.id === 'p1').currentResult, 'correct');
    assert.equal(revealed.players.find(p => p.id === 'p2').currentResult, 'wrong');
    assert.equal(revealed.current.title, songs.find(song => song.id === state.current.id).title);
    const next = (await call(`/rooms/${id}/next`, { playerId: 'p1' }, hostToken)).value;
    assert.equal(next.phase, 'preparing');
    assert.equal(next.players.find(p => p.id === 'p1').pushTimeMS, null);
    assert.equal(next.players.find(p => p.id === 'p1').currentResult, null);
    assert.deepEqual(next.pushOrderIds, []);
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
    assert.equal(failed.value.players.find(p => p.id === 'p1').currentResult, 'wrong');
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

function startedThreePlayerRoom(endless, settings = {}, extraGuestIDs = []) {
  const songs = Array.from({ length: settings.questionCount ?? 1 }, (_, index) => ({
    id: `applemusic:${1000000010 + index}`, title: '花火', artist: 'Artist' }));
  const host = handle('POST', '/rooms', { playerId: 'relayA', name: 'A', mode: 'applemusic', songs,
    settings: { questionCount: 1, answerSlots: 2, endless, targetScore: 0, ...settings } }, new URLSearchParams()).body;
  const guestIDs = ['relayB', 'relayC', ...extraGuestIDs];
  const guests = guestIDs.map(id => handle('POST', `/rooms/${host.id}/join`,
    { playerId: id, name: id.at(-1) }, new URLSearchParams()).body);
  const tokens = Object.fromEntries([['relayA', host], ...guestIDs.map((id, index) => [id, guests[index]])]
    .map(([id, state]) => [id, state.sessionToken]));
  const action = (name, id, extra = {}) => handle('POST', `/rooms/${host.id}/${name}`,
    { playerId: id, ...extra }, new URLSearchParams(), `Bearer ${tokens[id]}`);
  const state = id => handle('GET', `/rooms/${host.id}`, {}, new URLSearchParams({ playerId: id }), `Bearer ${tokens[id]}`).body;
  for (const id of Object.keys(tokens)) action('assets-ready', id);
  action('start', 'relayA');
  for (const id of Object.keys(tokens)) action('ready', id);
  return { action, state };
}

test('lobby handicap blocks selected players at the start of every round', () => {
  const originalNow = Date.now;
  let now = originalNow();
  Date.now = () => now;
  try {
    const songs = ['A', 'B'].map(letter => ({
      id: `applemusic:${1000000000 + letter.charCodeAt(0)}`, title: '花火', artist: 'Artist' }));
    const host = handle('POST', '/rooms', { playerId: 'handicap-host', name: 'Host',
      mode: 'applemusic', songs, settings: { questionCount: 2, targetScore: 0 } }, new URLSearchParams()).body;
    const path = `/rooms/${host.id}`;
    const guest = handle('POST', `${path}/join`, { playerId: 'handicap-guest', name: 'Guest' }, new URLSearchParams()).body;
    const act = (who, action, payload = {}) => handle('POST', `${path}/${action}`,
      { playerId: who, ...payload }, new URLSearchParams(),
      `Bearer ${who === 'handicap-host' ? host.sessionToken : guest.sessionToken}`);
    const state = who => handle('GET', path, {}, new URLSearchParams({ playerId: who }),
      `Bearer ${who === 'handicap-host' ? host.sessionToken : guest.sessionToken}`).body;
    const values = { 'handicap-guest': 4 };
    assert.equal(act('handicap-guest', 'handicaps', { handicaps: values }).status, 403);
    assert.equal(act('handicap-host', 'handicaps', { handicaps: { stranger: 4 } }).status, 400);
    assert.equal(act('handicap-host', 'handicaps', { handicaps: { 'handicap-guest': 31 } }).status, 400);
    assert.equal(act('handicap-host', 'handicaps', { handicaps: { 'handicap-guest': 0 } }).status, 200);
    assert.deepEqual(state('handicap-guest').settings.handicaps, {});
    assert.equal(act('handicap-host', 'handicaps', { handicaps: values }).status, 200);
    assert.deepEqual(state('handicap-guest').settings.handicaps, values);
    for (const who of ['handicap-host', 'handicap-guest']) act(who, 'assets-ready');
    act('handicap-host', 'start');
    assert.equal(act('handicap-host', 'handicaps', { handicaps: {} }).status, 403);
    for (const who of ['handicap-host', 'handicap-guest']) act(who, 'ready');
    now += 6000;
    assert.equal(act('handicap-guest', 'push').status, 409);
    assert.deepEqual(state('handicap-guest').pushOrderIds, []);
    assert.equal(act('handicap-host', 'push').status, 200);
    now += 2999;
    assert.equal(act('handicap-guest', 'push').status, 409);
    now += 1;
    assert.equal(act('handicap-guest', 'push').status, 200);
    now += 30000;
    assert.equal(state('handicap-host').phase, 'reveal');
    act('handicap-host', 'next');
    for (const who of ['handicap-host', 'handicap-guest']) act(who, 'ready');
    now += 6000;
    assert.equal(act('handicap-guest', 'push').status, 409);
    assert.equal(act('handicap-host', 'handicaps', { handicaps: {} }).status, 403);
  } finally {
    Date.now = originalNow;
  }
});

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
    assert.deepEqual(rejected.body.state.pushOrderIds, ['relayA', 'relayB']);
    assert.equal(rejected.body.state.players.find(player => player.id === 'relayB').pushTimeMS, 1000);
    const loser = state('relayB');
    assert.equal(loser.players.length, 3);
    assert.ok(loser.players.some(player => player.id === 'relayB'));
    assert.equal(loser.answerStatus, null);
    assert.deepEqual(loser.pushedIds, ['relayA']);
    action('choose', 'relayA', { choice: '花' });
    action('choose', 'relayA', { choice: '火' });
    const revealed = state('relayB');
    assert.deepEqual(revealed.players.find(player => player.id === 'relayA').roundResults, ['correct']);
    assert.deepEqual(revealed.players.find(player => player.id === 'relayB').roundResults, [null]);
  } finally { Date.now = realNow; }
});

test('PUSH order follows first press and leaves unpressed players in join order', () => {
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  try {
    const { action, state } = startedThreePlayerRoom(false, { answerSlots: 2 }, ['relayD']);
    now += 6000;
    action('push', 'relayB');
    now += 10;
    action('push', 'relayD');
    const after = state('relayA');
    assert.deepEqual(after.pushOrderIds, ['relayB', 'relayD']);
    assert.equal(after.players.find(player => player.id === 'relayB').pushTimeMS, 1000);
    assert.equal(after.players.find(player => player.id === 'relayD').pushTimeMS, 1010);
    const rejected = action('push', 'relayC');
    assert.equal(rejected.status, 409);
    assert.deepEqual(rejected.body.state.pushOrderIds, ['relayB', 'relayD', 'relayC']);
    assert.equal(rejected.body.state.players.find(player => player.id === 'relayC').pushTimeMS, 1010);
    assert.deepEqual(rejected.body.state.pushedIds, ['relayB', 'relayD']);
  } finally { Date.now = realNow; }
});

for (const endless of [false, true]) {
  test(`SKIP quorum is recalculated when an unvoted player leaves in ${endless ? 'endless' : 'normal'} mode`, () => {
    const realNow = Date.now;
    let now = realNow();
    Date.now = () => now;
    try {
      const { action, state } = startedThreePlayerRoom(endless);
      now += 6000;
      assert.equal(action('skip', 'relayA').body.phase, 'listening');
      assert.equal(action('skip', 'relayB').body.phase, 'listening');
      assert.equal(action('leave', 'relayC').status, 200);
      assert.equal(state('relayA').phase, 'reveal');
      assert.equal(state('relayA').players.length, 2);
    } finally { Date.now = realNow; }
  });

  test(`wrong player is excluded from SKIP quorum in ${endless ? 'endless' : 'normal'} mode`, () => {
    const realNow = Date.now;
    let now = realNow();
    Date.now = () => now;
    try {
      const { action, state } = startedThreePlayerRoom(endless);
      now += 6000;
      action('skip', 'relayB');
      action('skip', 'relayC');
      assert.equal(state('relayA').phase, 'listening');
      action('push', 'relayA');
      const wrong = action('choose', 'relayA', { choice: 'X' });
      assert.equal(wrong.status, 200);
      assert.equal(wrong.body.phase, 'reveal');
      assert.equal(wrong.body.players.find(player => player.id === 'relayA').currentResult, 'wrong');
    } finally { Date.now = realNow; }
  });
}

for (const votesFirst of [false, true]) {
  test(`correct players are excluded from SKIP quorum when votes arrive ${votesFirst ? 'before' : 'after'} the answer`, () => {
    const realNow = Date.now;
    let now = realNow();
    Date.now = () => now;
    try {
      const { action, state } = startedThreePlayerRoom(false, { answerSlots: 3 });
      now += 6000;
      if (votesFirst) {
        action('skip', 'relayB');
        action('skip', 'relayC');
      }
      action('push', 'relayA');
      action('choose', 'relayA', { choice: '花' });
      const correct = action('choose', 'relayA', { choice: '火' });
      assert.equal(correct.body.phase, votesFirst ? 'reveal' : 'listening');
      if (!votesFirst) {
        const unnecessary = action('skip', 'relayA');
        assert.equal(unnecessary.status, 409);
        assert.match(unnecessary.body.error, /解答済み/);
        assert.equal(action('skip', 'relayB').body.phase, 'listening');
        assert.equal(action('skip', 'relayC').body.phase, 'reveal');
      }
      assert.equal(state('relayB').phase, 'reveal');
      assert.deepEqual(state('relayB').skippedIds, ['relayB', 'relayC']);
      assert.deepEqual(state('relayB').correctPlayerIDs, ['relayA']);
    } finally { Date.now = realNow; }
  });
}

test('an active answer remains in the SKIP quorum and finishes after normal PUSH closes', () => {
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  try {
    const { action, state } = startedThreePlayerRoom(false, { answerSlots: 3 });
    now += 6000;
    action('push', 'relayA');
    action('skip', 'relayB');
    action('skip', 'relayC');
    assert.equal(state('relayA').pushClosed, false, 'An unfinished answer still needs a vote');
    const voted = action('skip', 'relayA');
    assert.equal(voted.body.pushClosed, true);
    assert.equal(voted.body.phase, 'answering');
    action('choose', 'relayA', { choice: '花' });
    assert.equal(action('choose', 'relayA', { choice: '火' }).body.phase, 'reveal');
  } finally { Date.now = realNow; }
});

test('SKIP is recalculated after the unvoted host leaves and ownership transfers', () => {
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  try {
    const { action, state } = startedThreePlayerRoom(false);
    now += 6000;
    action('skip', 'relayB');
    action('skip', 'relayC');
    action('leave', 'relayA');
    const remaining = state('relayB');
    assert.equal(remaining.phase, 'reveal');
    assert.equal(remaining.hostId, 'relayB');
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
    assert.equal(state('relayC').pushClosed, false);
    assert.equal(state('relayB').activeAnswers[0].progress, '');
    action('choose', 'relayA', { choice: '花' });
    assert.equal(state('relayB').activeAnswers[0].progress, '');
    assert.equal(action('push', 'relayB').status, 200);
    assert.equal(state('relayC').pushClosed, true);
    assert.equal(state('relayC').audioStoppedAt, null);
    assert.equal(action('push', 'relayC').status, 409);
    assert.deepEqual(state('relayC').activeAnswers.map(a => a.progress), ['花', '']);
    action('choose', 'relayA', { choice: 'X' });
    assert.equal(state('relayC').phase, 'answering');
    assert.equal(state('relayC').pushClosed, true);
    assert.equal(action('push', 'relayA').status, 409);
    action('choose', 'relayB', { choice: '花' });
    action('choose', 'relayB', { choice: '火' });
    assert.equal(state('relayC').phase, 'reveal');
    assert.equal(state('relayC').correctPlayerID, 'relayB');
  } finally { Date.now = realNow; }
});

test('normal mode closes PUSH when the last unpushed players leave', () => {
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  try {
    const { action, state } = startedThreePlayerRoom(false, { answerSlots: 4 });
    now += 6000;
    action('push', 'relayA');
    assert.equal(state('relayA').pushClosed, false);
    action('leave', 'relayB');
    assert.equal(state('relayA').pushClosed, false);
    action('leave', 'relayC');
    const closed = state('relayA');
    assert.equal(closed.phase, 'answering');
    assert.equal(closed.pushClosed, true);
    assert.equal(closed.audioStoppedAt, null);
    action('choose', 'relayA', { choice: 'X' });
    assert.equal(state('relayA').phase, 'reveal');
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
    assert.equal(stillOpen.players.find(p => p.id === 'relayA').currentResult, 'correct');
    assert.equal(stillOpen.players.find(p => p.id === 'relayB').currentResult, null);
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

test('1st correct follows the earliest correct PUSH while 1st wrong stays with the first PUSH', () => {
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  try {
    const { action, state } = startedThreePlayerRoom(false, {
      questionCount: 5, answerSlots: 2, targetScore: 0, wrongPenalty: 5, firstWrongPenalty: 10
    });
    const startNextRound = () => {
      action('next', 'relayA');
      for (const id of ['relayA', 'relayB', 'relayC']) action('ready', id);
      now += 6000;
    };
    const answerCorrectly = id => {
      action('choose', id, { choice: '花' });
      action('choose', id, { choice: '火' });
    };

    now += 6000;
    action('push', 'relayB');
    action('push', 'relayA');
    answerCorrectly('relayB');
    answerCorrectly('relayA');
    assert.equal(state('relayC').players.find(p => p.id === 'relayB').score, 20);
    assert.equal(state('relayC').players.find(p => p.id === 'relayA').score, 10);

    startNextRound();
    action('push', 'relayA');
    action('push', 'relayB');
    action('choose', 'relayB', { choice: 'X' });
    assert.equal(state('relayC').players.find(p => p.id === 'relayB').score, 15);
    answerCorrectly('relayA');
    assert.equal(state('relayC').players.find(p => p.id === 'relayA').score, 30);

    startNextRound();
    action('push', 'relayB');
    action('push', 'relayA');
    answerCorrectly('relayB');
    action('choose', 'relayA', { choice: 'X' });
    const revealed = state('relayC');
    assert.equal(revealed.players.find(p => p.id === 'relayB').score, 35);
    assert.equal(revealed.players.find(p => p.id === 'relayA').score, 25);

    startNextRound();
    action('push', 'relayA');
    action('push', 'relayB');
    action('choose', 'relayA', { choice: 'X' });
    assert.equal(state('relayC').players.find(p => p.id === 'relayA').score, 10);
    answerCorrectly('relayB');
    assert.deepEqual(state('relayC').correctPlayerIDs, ['relayB']);
    assert.equal(state('relayC').players.find(p => p.id === 'relayB').score, 55);

    startNextRound();
    action('push', 'relayA');
    action('push', 'relayB');
    action('choose', 'relayB', { choice: 'X' });
    assert.equal(state('relayC').players.find(p => p.id === 'relayB').score, 50);
    action('choose', 'relayA', { choice: 'X' });
    assert.equal(state('relayC').players.find(p => p.id === 'relayA').score, 0);
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

test('endless mode passes queued PUSHes in order before resuming the round clock', () => {
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  try {
    const { action, state } = startedThreePlayerRoom(true);
    now += 6000;
    const first = action('push', 'relayA').body;
    assert.equal(first.pausedPositionMS, 1000);
    now += 200;
    assert.equal(action('push', 'relayB').status, 409);
    assert.equal(state('relayB').players.find(p => p.id === 'relayB').pushTimeMS, 1000);
    action('choose', 'relayA', { choice: '花' });
    assert.equal(state('relayC').activeAnswers[0].progress, '花');
    now += 4000;
    action('choose', 'relayA', { choice: 'X' });
    const passed = state('relayB');
    assert.equal(passed.phase, 'answering');
    assert.equal(passed.answerStatus, 'active');
    assert.equal(passed.pausedPositionMS, 1000);
    assert.equal(passed.startAt, first.startAt);
    assert.deepEqual(passed.pushedIds, ['relayA', 'relayB']);
    now += 5000;
    const resumed = state('relayA');
    assert.equal(resumed.phase, 'listening');
    assert.equal(resumed.pausedAt, null);
    assert.equal(resumed.startAt, first.startAt + 9200);
    assert.equal(resumed.roundDeadline, first.roundDeadline + 9200);
    assert.equal(action('push', 'relayB').status, 409);
    assert.equal(action('push', 'relayC').status, 200);
    action('choose', 'relayC', { choice: 'X' });
    assert.equal(state('relayA').phase, 'reveal');
  } finally { Date.now = realNow; }
});

test('endless mode passes a second queued PUSH after the first queued player is wrong', () => {
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  try {
    const { action, state } = startedThreePlayerRoom(true);
    now += 6000;
    assert.equal(action('push', 'relayA').status, 200);
    now += 10;
    assert.equal(action('push', 'relayB').status, 409);
    now += 10;
    assert.equal(action('push', 'relayC').status, 409);
    assert.deepEqual(state('relayA').pushOrderIds, ['relayA', 'relayB', 'relayC']);
    assert.equal(action('choose', 'relayA', { choice: 'X' }).body.phase, 'answering');
    assert.equal(state('relayB').answerStatus, 'active');
    assert.equal(action('choose', 'relayB', { choice: 'X' }).body.phase, 'answering');
    assert.equal(state('relayC').answerStatus, 'active');
    assert.equal(action('choose', 'relayC', { choice: '花' }).body.phase, 'answering');
    const result = action('choose', 'relayC', { choice: '火' }).body;
    assert.equal(result.phase, 'reveal');
    assert.equal(result.correctPlayerID, 'relayC');
    assert.equal(result.players.find(p => p.id === 'relayC').score, 20);
  } finally { Date.now = realNow; }
});

test('returning to the lobby keeps played history across rule changes and resets scores', () => {
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  try {
    const songs = [1000000201, 1000000202, 1000000203].map(id => ({
      id: `applemusic:${id}`, title: '花火', artist: 'Artist' }));
    const host = handle('POST', '/rooms', { playerId: 'rematch-host', name: 'Host',
      mode: 'applemusic', deferQuestions: true }, new URLSearchParams()).body;
    const path = `/rooms/${host.id}`;
    const guest = handle('POST', `${path}/join`, { playerId: 'rematch-guest', name: 'Guest' }, new URLSearchParams()).body;
    const act = (id, action, payload = {}) => handle('POST', `${path}/${action}`,
      { playerId: id, ...payload }, new URLSearchParams(),
      `Bearer ${id === 'rematch-host' ? host.sessionToken : guest.sessionToken}`);
    assert.equal(host.phase, 'lobby');
    assert.equal(host.totalRounds, 0);
    assert.equal(act('rematch-host', 'handicaps', { handicaps: { 'rematch-guest': 2 } }).status, 200);
    assert.equal(act('rematch-host', 'start', { settings: { questionCount: 1, targetScore: 0 }, songs }).body.phase, 'preparing');
    for (const id of ['rematch-host', 'rematch-guest']) act(id, 'ready');
    now += 6000;
    act('rematch-host', 'push');
    act('rematch-host', 'choose', { choice: '花' });
    act('rematch-host', 'choose', { choice: '火' });
    now += 30000;
    const finished = act('rematch-host', 'next').body;
    assert.equal(finished.phase, 'finished');
    assert.equal(finished.players.find(p => p.id === 'rematch-host').score, 20);
    const firstSongID = finished.playedSongIDs[0];
    assert.equal(act('rematch-guest', 'rematch').status, 403);
    const rematched = act('rematch-host', 'rematch').body;
    assert.equal(rematched.id, host.id);
    assert.equal(rematched.phase, 'lobby');
    assert.equal(rematched.round, -1);
    assert.equal(rematched.gameNumber, 1);
    assert.equal(rematched.settings.questionCount, 1);
    assert.equal(rematched.settings.targetScore, 0);
    assert.equal(rematched.settings.handicaps['rematch-guest'], 2);
    assert.equal(rematched.preload.length, 0);
    assert.deepEqual(rematched.playedSongIDs, [firstSongID]);
    assert.deepEqual(rematched.players.map(p => [p.id, p.score, p.lives, p.roundResults]),
      [['rematch-host', 0, 3, []], ['rematch-guest', 0, 3, []]]);
    assert.deepEqual(rematched.assetsReadyIds, []);
    assert.equal(act('rematch-host', 'start').status, 409);
    const second = act('rematch-host', 'start', { settings: { questionCount: 2, lives: 5, targetScore: 0 }, songs }).body;
    assert.equal(second.phase, 'preparing');
    assert.equal(second.settings.lives, 5);
    assert.ok(second.players.every(player => player.lives === 5));
    assert.notEqual(second.current.id, firstSongID);
    for (const id of ['rematch-host', 'rematch-guest']) act(id, 'ready');
    now += 6000;
    for (const id of ['rematch-host', 'rematch-guest']) act(id, 'skip');
    const secondRound = act('rematch-host', 'next').body;
    assert.equal(secondRound.phase, 'preparing');
    assert.notEqual(secondRound.current.id, firstSongID);
    assert.notEqual(secondRound.current.id, second.current.id);
  } finally { Date.now = realNow; }
});

test('playlist questions use unique song IDs before random selection', () => {
  const songs = [1000000301, 1000000301, 1000000302, 1000000303].map(id => ({
    id: `applemusic:${id}`, title: '花火', artist: 'Artist' }));
  const query = new URLSearchParams();
  const insufficient = handle('POST', '/rooms', { playerId: 'unique-insufficient', name: 'Host',
    mode: 'applemusic', songs: songs.slice(0, 3), settings: { questionCount: 3 } }, query);
  assert.equal(insufficient.status, 400);

  const created = handle('POST', '/rooms', { playerId: 'unique-playlist-host', name: 'Host',
    mode: 'applemusic', songs, settings: { questionCount: 3 } }, query);
  assert.equal(created.status, 201);
  assert.equal(created.body.preload.length, 3);
  assert.deepEqual(new Set(created.body.preload.map(song => song.id)),
    new Set(['applemusic:1000000301', 'applemusic:1000000302', 'applemusic:1000000303']));
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

test('profile registration can be retried with its saved credential without exposing another profile', () => {
  const query = new URLSearchParams();
  const id = 'recoverable-profile';
  const registrationToken = '172a2b48-e04b-4ec7-b445-a963470e7d80';
  const otherToken = '172a2b48-e04b-4ec7-b445-a963470e7d81';
  const register = handle('POST', '/profile', { id, registrationToken }, query);
  assert.equal(register.status, 201);
  assert.equal(register.body.token, registrationToken);
  const auth = `Bearer ${registrationToken}`;
  handle('PUT', '/profile', { id, stats: { games: 7 } }, query, auth);
  const retry = handle('POST', '/profile', { id, registrationToken }, query);
  assert.equal(retry.status, 200);
  assert.equal(retry.body.token, registrationToken);
  assert.deepEqual(retry.body.stats, { games: 7 }, 'A registration retry must not overwrite existing data');
  assert.equal(retry.body.secret, undefined);
  assert.equal(handle('POST', '/profile', { id, registrationToken: otherToken }, query).status, 409);
  assert.equal(handle('POST', '/profile', { id }, query).status, 409);
  assert.equal(handle('GET', '/profile', {}, new URLSearchParams({ id }), `Bearer ${otherToken}`).status, 403);
  for (const value of ['short', '', null, 123]) {
    assert.equal(handle('POST', '/profile', { id: 'invalid-registration', registrationToken: value }, query).status, 400);
  }
});

test('expired guests receive a status that the client can use to clear restoration state', () => {
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  try {
    const query = new URLSearchParams();
    const created = handle('POST', '/rooms', { playerId: 'expiry-host', name: 'Host', settings: { questionCount: 1 } }, query);
    assert.equal(created.status, 201);
    const host = created.body;
    const path = `/rooms/${host.id}`;
    const guest = handle('POST', `${path}/join`, { playerId: 'expiry-guest', name: 'Guest' }, query).body;
    now += 299_000;
    handle('GET', path, {}, new URLSearchParams({ playerId: 'expiry-host' }), `Bearer ${host.sessionToken}`);
    now += 1_001;
    handle('GET', path, {}, new URLSearchParams({ playerId: 'expiry-host' }), `Bearer ${host.sessionToken}`);
    const expired = handle('GET', path, {}, new URLSearchParams({ playerId: 'expiry-guest' }), `Bearer ${guest.sessionToken}`);
    assert.equal(expired.status, 403);
    assert.equal(expired.body.error, '参加していません');
  } finally { Date.now = realNow; }
});

test('CloudKit public summary does not overwrite legacy personal data and is visible in the room profile', () => {
  const query = new URLSearchParams();
  const registered = handle('POST', '/profile', { id: 'cloudkit-summary-profile' }, query).body;
  const auth = `Bearer ${registered.token}`;
  const personal = { id: registered.id, reviews: [{ song: { id: 'personal-song' }, savedAt: 1 }],
    history: [{ id: 'personal-result' }], stats: { games: 7, totalPushSeconds: 123, genres: { Pop: { attempts: 3 } } } };
  handle('PUT', '/profile', personal, query, auth);
  const publication = { id: registered.id, name: 'Cloud player', avatar: '',
    publicStats: { games: 10, attempts: 20, correct: 15, selectedBadge: 'はじめの一歩',
      badges: ['はじめの一歩'], reviews: ['must-not-be-stored'], genres: { secret: true } } };
  assert.equal(handle('PUT', '/profile', publication, query).status, 403);
  assert.equal(handle('PUT', '/profile', publication, query, auth).status, 200);
  const stored = handle('GET', '/profile', {}, new URLSearchParams({ id: registered.id }), auth).body;
  assert.deepEqual(stored.reviews, personal.reviews);
  assert.deepEqual(stored.history, personal.history);
  assert.deepEqual(stored.stats, personal.stats);
  assert.equal(stored.publicStats.reviews, undefined);
  assert.equal(stored.publicStats.genres, undefined);
  const room = handle('POST', '/rooms', { playerId: 'cloudkit-summary-player', profileId: registered.id,
    profileToken: registered.token, name: 'Cloud player', settings: { questionCount: 1 } }, query).body;
  const visible = handle('GET', '/player-profile', {}, new URLSearchParams({ roomId: room.id,
    playerId: 'cloudkit-summary-player', targetPlayerId: 'cloudkit-summary-player' }), `Bearer ${room.sessionToken}`).body;
  assert.equal(visible.stats.games, 10);
  assert.equal(visible.badge, 'はじめの一歩');
  assert.equal(visible.reviews, undefined);
  assert.equal(visible.stats.totalPushSeconds, undefined);
});

test('Apple Music rooms hide the title, accept readiness, and allow a lobby host transfer', () => {
  const song = { id: 'applemusic:1000000004', title: '怪獣の花唄', artist: 'Vaundy',
    previewURL: null, durationMS: 220000, genre: 'Pop' };
  const host = handle('POST', '/rooms', { playerId: 'spHost', name: 'Host', mode: 'applemusic', songs: [song], settings: { questionCount: 1 } }, new URLSearchParams()).body;
  assert.equal(host.mode, 'applemusic');
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
    const song = { id: 'applemusic:1000000005', title: '花火', artist: 'Artist',
      artistTopTitles: ['青空', '新時代', '夜に駆ける', '花火'] };
    const created = handle('POST', '/rooms', { playerId: 'topHost', name: 'Host', mode: 'applemusic',
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
