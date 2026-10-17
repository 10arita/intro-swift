import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { handle } from './index.mjs';

const query = new URLSearchParams();
const authorization = profile => `Bearer ${profile.token}`;
function createProfile() {
  return handle('POST', '/profile', { id: randomUUID() }, query).body;
}
function profileQuery(profile) {
  return new URLSearchParams({ profileId: profile.id });
}

test('profile deletion authenticates ownership, supports retry, and refuses stale registration', () => {
  const profile = createProfile();
  assert.equal(handle('DELETE', '/profile', { id: profile.id }, query).status, 403);
  assert.equal(handle('DELETE', '/profile', { id: profile.id }, query, `Bearer ${randomUUID()}`).status, 403);
  assert.equal(handle('GET', '/profile', {}, new URLSearchParams({ id: profile.id }), authorization(profile)).status, 200);
  for (let attempt = 0; attempt < 2; attempt++) {
    assert.deepEqual(handle('DELETE', '/profile', { id: profile.id }, query, authorization(profile)),
      { status: 200, body: { deleted: true } });
  }
  assert.equal(handle('GET', '/profile', {}, new URLSearchParams({ id: profile.id }), authorization(profile)).status, 403);
  assert.equal(handle('POST', '/profile', { id: profile.id, registrationToken: profile.token }, query).status, 410);
  assert.equal(handle('DELETE', '/profile', { id: profile.id }, query, `Bearer ${randomUUID()}`).status, 403);
});

test('deletion clears friendships, pending requests, invites, room membership, and profile visibility', () => {
  const owner = createProfile();
  const friend = createProfile();
  const pending = createProfile();
  const room = handle('POST', '/rooms', { playerId: owner.id, name: 'Private deleted name',
    profileId: owner.id, profileToken: owner.token, settings: { questionCount: 1 } }, query).body;
  const guest = handle('POST', `/rooms/${room.id}/join`, { playerId: friend.id, name: 'Friend',
    profileId: friend.id, profileToken: friend.token }, query).body;
  handle('POST', `/rooms/${room.id}/friend-request`, { playerId: owner.id, targetId: friend.id }, query,
    `Bearer ${room.sessionToken}`);
  const request = handle('GET', '/friends', {}, profileQuery(friend), authorization(friend)).body.requests[0];
  handle('POST', '/friends/accept', { profileId: friend.id, requestId: request.id }, query, authorization(friend));
  handle('POST', `/rooms/${room.id}/leave`, { playerId: friend.id }, query, `Bearer ${guest.sessionToken}`);
  handle('POST', `/rooms/${room.id}/invite`, { playerId: owner.id, targetProfileId: friend.id }, query,
    `Bearer ${room.sessionToken}`);
  const other = handle('POST', `/rooms/${room.id}/join`, { playerId: pending.id, name: 'Pending',
    profileId: pending.id, profileToken: pending.token }, query).body;
  handle('POST', `/rooms/${room.id}/friend-request`, { playerId: owner.id, targetId: pending.id }, query,
    `Bearer ${room.sessionToken}`);
  assert.equal(handle('DELETE', '/profile', { id: owner.id }, query, authorization(owner)).status, 200);
  const friends = handle('GET', '/friends', {}, profileQuery(friend), authorization(friend)).body;
  assert.deepEqual(friends.friends, []);
  assert.deepEqual(friends.invites, []);
  assert.deepEqual(handle('GET', '/friends', {}, profileQuery(pending), authorization(pending)).body.requests, []);
  const remaining = handle('GET', `/rooms/${room.id}`, {}, new URLSearchParams({ playerId: pending.id }),
    `Bearer ${other.sessionToken}`).body;
  assert.equal(remaining.players.length, 1);
  assert.equal(remaining.hostId, pending.id);
  assert.ok(!JSON.stringify(remaining).includes('Private deleted name'));
  assert.equal(handle('GET', `/rooms/${room.id}`, {}, new URLSearchParams({ playerId: owner.id }),
    `Bearer ${room.sessionToken}`).status, 403);
});

test('deletion survives restart and persists only hashes for recreation prevention', () => {
  const directory = mkdtempSync(join(tmpdir(), 'intol-profile-deletion-'));
  const id = randomUUID();
  const credential = randomUUID();
  const run = source => JSON.parse(execFileSync(process.execPath, ['--input-type=module', '-e', source], {
    cwd: new URL('.', import.meta.url), encoding: 'utf8', env: { ...process.env, DATA_DIR: directory }
  }).trim());
  try {
    const deleted = run(`
      import { handle } from './index.mjs';
      const query = new URLSearchParams();
      handle('POST', '/profile', { id: '${id}', registrationToken: '${credential}' }, query);
      handle('PUT', '/profile', { id: '${id}', name: 'Deleted private name' }, query, 'Bearer ${credential}');
      console.log(JSON.stringify(handle('DELETE', '/profile', { id: '${id}' }, query, 'Bearer ${credential}')));
    `);
    assert.equal(deleted.status, 200);
    const saved = readFileSync(join(directory, 'state.json'), 'utf8');
    assert.ok(!saved.includes(id));
    assert.ok(!saved.includes(credential));
    assert.ok(!saved.includes('Deleted private name'));
    const restarted = run(`
      import { handle } from './index.mjs';
      const query = new URLSearchParams();
      console.log(JSON.stringify({
        registration: handle('POST', '/profile', { id: '${id}', registrationToken: '${credential}' }, query).status,
        retry: handle('DELETE', '/profile', { id: '${id}' }, query, 'Bearer ${credential}').status
      }));
    `);
    assert.deepEqual(restarted, { registration: 410, retry: 200 });
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test('deleting the active endless-mode answerer passes the answer to the next queued player', () => {
  const originalNow = Date.now;
  let now = originalNow();
  Date.now = () => now;
  try {
    const owner = createProfile();
    const friend = createProfile();
    const room = handle('POST', '/rooms', { playerId: owner.id, name: 'Owner', profileId: owner.id,
      profileToken: owner.token, settings: { questionCount: 1, endless: true } }, query).body;
    const guest = handle('POST', `/rooms/${room.id}/join`, { playerId: friend.id, name: 'Friend',
      profileId: friend.id, profileToken: friend.token }, query).body;
    const send = (player, token, action) => handle('POST', `/rooms/${room.id}/${action}`,
      { playerId: player.id }, query, `Bearer ${token}`);
    assert.equal(send(owner, room.sessionToken, 'assets-ready').status, 200);
    assert.equal(send(friend, guest.sessionToken, 'assets-ready').status, 200);
    assert.equal(send(owner, room.sessionToken, 'start').status, 200);
    assert.equal(send(owner, room.sessionToken, 'ready').status, 200);
    assert.equal(send(friend, guest.sessionToken, 'ready').status, 200);
    now += 6000;
    assert.equal(send(owner, room.sessionToken, 'push').status, 200);
    send(friend, guest.sessionToken, 'push');
    assert.equal(handle('DELETE', '/profile', { id: owner.id }, query, authorization(owner)).status, 200);
    const state = handle('GET', `/rooms/${room.id}`, {}, new URLSearchParams({ playerId: friend.id }),
      `Bearer ${guest.sessionToken}`).body;
    assert.equal(state.phase, 'answering');
    assert.deepEqual(state.activeAnswers.map(answer => answer.playerId), [friend.id]);
    assert.ok(!JSON.stringify(state).includes(owner.id));
  } finally { Date.now = originalNow; }
});
