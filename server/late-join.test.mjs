import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { handle } from './index.mjs';

const query = new URLSearchParams();

function withClock(run) {
  const original = Date.now;
  let now = original();
  Date.now = () => now;
  try { run(milliseconds => { now += milliseconds; }); }
  finally { Date.now = original; }
}

function game({ startImmediately = true, ...options } = {}) {
  const hostID = randomUUID();
  const created = handle('POST', '/rooms', {
    playerId: hostID, name: 'Host', mode: 'applemusic',
    songs: [1, 2].map(id => ({ id: `applemusic:100000000${id}`, title: '青', artist: 'Artist' })),
    ...options,
    settings: { questionCount: 2, targetScore: 0, answerSlots: 2, lives: 2, ...options.settings }
  }, query);
  assert.equal(created.status, 201);
  const room = created.body;
  const path = `/rooms/${room.id}`;
  const tokens = new Map([[hostID, room.sessionToken]]);
  const send = (action, playerId = hostID, payload = {}) => handle('POST', `${path}/${action}`,
    { playerId, ...payload }, query, `Bearer ${tokens.get(playerId)}`);
  const join = (playerId = randomUUID()) => {
    const result = handle('POST', `${path}/join`, { playerId, name: 'Late guest' }, query);
    if (result.status === 200) tokens.set(playerId, result.body.sessionToken);
    return { ...result, playerId };
  };
  const state = (playerId = hostID) => handle('GET', path, {},
    new URLSearchParams({ playerId }), `Bearer ${tokens.get(playerId)}`).body;
  send('assets-ready');
  if (startImmediately) assert.equal(send('start').body.phase, 'preparing');
  return { room, path, hostID, tokens, send, join, state };
}

test('joining during preparation waits for the new player; countdown keeps its original timing', () => withClock(advance => {
  const g = game();
  const guest = g.join();
  assert.equal(guest.status, 200);
  assert.equal(g.send('ready').body.phase, 'preparing');
  const countdown = g.send('ready', guest.playerId).body;
  assert.equal(countdown.phase, 'countdown');
  advance(2_000);
  const third = g.join();
  assert.equal(third.body.phase, 'countdown');
  assert.equal(third.body.startAt, countdown.startAt);
  assert.equal(third.body.roundDeadline, countdown.roundDeadline);
  advance(3_100);
  const fourth = g.join();
  assert.equal(fourth.body.phase, 'listening');
  assert.equal(fourth.body.startAt, countdown.startAt);
  assert.equal(fourth.body.players.length, 4);
  assert.equal(g.join().status, 409);
  assert.equal(g.send('join', guest.playerId).status, 200, 'authenticated members can reconnect to a full room');
  assert.equal(handle('POST', `${g.path}/join`, { playerId: guest.playerId }, query).status, 403);
}));

test('all audio modes allow joining a running round without exposing the answer', () => withClock(advance => {
  for (const mode of ['shared', 'applemusic', 'sabitro']) {
    const options = mode === 'sabitro' ? { songs: [1, 2].map(id => ({
      id: `itunes:${id}`, title: '青', artist: 'Artist', previewURL: `https://example.test/${id}.m4a`
    })) } : {};
    const g = game({ mode, ...options });
    g.send('ready');
    advance(9_000);
    const before = g.state();
    const guest = g.join();
    assert.equal(guest.status, 200, mode);
    assert.equal(guest.body.phase, 'listening');
    assert.equal(guest.body.startAt, before.startAt);
    assert.equal(guest.body.roundDeadline, before.roundDeadline);
    assert.equal(guest.body.current.title, undefined);
    assert.equal(guest.body.current.artist, undefined);
    assert.deepEqual(guest.body.options, []);
    const player = guest.body.players.find(player => player.id === guest.playerId);
    assert.equal(player.score, 0);
    assert.equal(player.lives, 2);
    assert.equal(player.disqualified, false);
    assert.equal(player.correctCount, 0);
    assert.equal(player.wrongCount, 0);
    assert.deepEqual(player.roundResults, []);
    assert.equal(g.state(guest.playerId).id, g.room.id, 'new session credentials authorize state reads');
    assert.equal(handle('GET', g.path, {}, new URLSearchParams({ playerId: guest.playerId }),
      `Bearer ${g.room.sessionToken}`).status, 403);
  }
}));

test('a late player can answer the current question and participates in subsequent skip votes', () => withClock(advance => {
  const g = game();
  g.send('ready');
  advance(5_100);
  const guest = g.join();
  assert.equal(g.send('push', guest.playerId).status, 200);
  assert.equal(g.send('choose', guest.playerId, { choice: '青' }).body.phase, 'listening');
  const revealed = g.send('skip').body;
  assert.equal(revealed.phase, 'reveal');
  assert.equal(revealed.players.find(player => player.id === guest.playerId).score, 20);
  const later = g.join();
  assert.equal(later.body.phase, 'reveal');
  assert.equal(later.body.players.find(player => player.id === later.playerId).currentResult, null);
  assert.equal(g.send('next').body.round, 1);
  for (const id of [g.hostID, guest.playerId, later.playerId]) g.send('ready', id);
  advance(5_100);
  assert.equal(g.send('skip').body.phase, 'listening');
  assert.equal(g.send('skip', guest.playerId).body.phase, 'listening');
  assert.equal(g.send('skip', later.playerId).body.phase, 'reveal');
}));

test('joining during an answer respects closed slots and the endless pause and PUSH queue', () => withClock(advance => {
  for (const endless of [false, true]) {
    const g = game({ settings: { endless, answerSlots: 1 } });
    g.send('ready');
    advance(5_100);
    const answering = g.send('push').body;
    const guest = g.join();
    assert.equal(guest.body.phase, 'answering');
    assert.equal(guest.body.startAt, answering.startAt);
    assert.equal(guest.body.pausedAt, answering.pausedAt);
    assert.equal(guest.body.pushClosed, answering.pushClosed);
    assert.deepEqual(guest.body.options, []);
    const push = g.send('push', guest.playerId);
    assert.equal(push.status, 409);
    const afterWrong = g.send('choose', g.hostID, { choice: '間違い' }).body;
    if (endless) {
      assert.equal(afterWrong.phase, 'answering');
      assert.deepEqual(afterWrong.activeAnswers.map(answer => answer.playerId), [guest.playerId]);
      assert.equal(afterWrong.pausedAt, answering.pausedAt);
      assert.equal(g.send('choose', guest.playerId, { choice: '青' }).body.phase, 'reveal');
    } else {
      assert.equal(afterWrong.phase, 'reveal', 'joining must not reopen closed answer slots');
      assert.deepEqual(afterWrong.correctPlayerIDs, []);
    }
  }
}));

test('a late player can take a free answer slot while another player answers', () => withClock(advance => {
  const g = game();
  const waiting = g.join();
  g.send('ready');
  g.send('ready', waiting.playerId);
  advance(5_100);
  assert.equal(g.send('push').body.pushClosed, false);
  const late = g.join();
  assert.equal(late.body.phase, 'answering');
  assert.equal(late.body.current.title, undefined);
  const answering = g.send('push', late.playerId);
  assert.equal(answering.status, 200);
  assert.equal(answering.body.phase, 'answering');
  assert.equal(answering.body.pushClosed, true);
  assert.equal(g.send('choose', late.playerId, { choice: '青' }).body.phase, 'answering');
  const revealed = g.send('choose', g.hostID, { choice: '青' }).body;
  assert.equal(revealed.phase, 'reveal');
  assert.deepEqual(revealed.correctPlayerIDs, [g.hostID, late.playerId]);
  assert.equal(revealed.players.find(player => player.id === late.playerId).score, 10);
}));

test('invitations stay visible after start and friends can be invited during play', () => withClock(advance => {
  const a = handle('POST', '/profile', { id: randomUUID() }, query).body;
  const b = handle('POST', '/profile', { id: randomUUID() }, query).body;
  const g = game({ profileId: a.id, profileToken: a.token, startImmediately: false });
  const friendID = randomUUID();
  const friend = handle('POST', `${g.path}/join`, { playerId: friendID, name: 'Friend',
    profileId: b.id, profileToken: b.token }, query).body;
  g.tokens.set(friendID, friend.sessionToken);
  assert.equal(g.send('friend-request', g.hostID, { targetId: friendID }).status, 200);
  const friends = profile => handle('GET', '/friends', {}, new URLSearchParams({ profileId: profile.id }),
    `Bearer ${profile.token}`).body;
  const request = friends(b).requests[0];
  assert.equal(handle('POST', '/friends/accept', { profileId: b.id, requestId: request.id }, query,
    `Bearer ${b.token}`).status, 200);
  g.send('leave', friendID);
  const invite = () => g.send('invite', g.hostID, { targetProfileId: b.id });
  assert.equal(invite().status, 200);
  assert.equal(g.send('start').body.phase, 'preparing');
  g.send('ready');
  advance(5_100);
  const invitation = friends(b).invites[0];
  assert.ok(invitation, 'an invitation sent before start remains visible');
  assert.deepEqual(friends(a).sentInvites, [{ roomId: g.room.id, targetId: b.id }]);
  const accept = inviteId => handle('POST', '/friends/invites/join', {
    profileId: b.id, inviteId, playerId: friendID, name: 'Friend'
  }, query, `Bearer ${b.token}`);
  const joined = accept(invitation.id);
  assert.equal(joined.status, 200);
  assert.equal(joined.body.phase, 'listening');
  g.tokens.set(friendID, joined.body.sessionToken);
  assert.equal(g.send('leave', friendID).status, 200);
  assert.equal(invite().status, 200, 'a new invitation can be sent during play');
  const ongoingInvite = friends(b).invites[0];
  assert.ok(ongoingInvite);
  // A full room must reject invite acceptance without consuming the invitation.
  for (let i = 0; i < 3; i++) assert.equal(g.join().status, 200);
  assert.equal(accept(ongoingInvite.id).status, 409);
  assert.equal(friends(b).invites[0].id, ongoingInvite.id);
  advance(30_000);
  assert.equal(g.state().phase, 'reveal');
  g.send('next');
  for (const id of g.tokens.keys()) {
    if (id !== friendID) g.send('ready', id);
  }
  advance(36_000);
  assert.equal(g.state().phase, 'reveal');
  assert.equal(g.send('next').body.phase, 'finished');
  assert.deepEqual(friends(b).invites, []);
  assert.deepEqual(friends(a).sentInvites, []);
  assert.equal(accept(ongoingInvite.id).status, 409);
  assert.equal(invite().status, 409);
}));

test('finished games reject new players while existing sessions and the next lobby remain usable', () => withClock(advance => {
  const g = game({ settings: { questionCount: 1 } });
  g.send('ready');
  advance(36_000);
  assert.equal(g.state().phase, 'reveal');
  assert.equal(g.send('next').body.phase, 'finished');
  assert.equal(g.join().status, 409);
  assert.equal(g.send('join').status, 200);
  assert.equal(g.send('rematch').body.phase, 'lobby');
  assert.equal(g.join().status, 200);
}));
