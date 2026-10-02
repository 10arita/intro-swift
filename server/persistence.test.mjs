import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

function run(code, directory) {
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', code], {
    cwd: import.meta.dirname, env: { ...process.env, DATA_DIR: directory }, encoding: 'utf8'
  });
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}

test('profile and active room are restored from DATA_DIR', () => {
  const directory = mkdtempSync(join(tmpdir(), 'intol-state-'));
  try {
    const first = run(`
      import { handle, saveStateNow } from './index.mjs';
      const profile = handle('POST', '/profile', { id: 'persistent-player' }, new URLSearchParams()).body;
      const room = handle('POST', '/rooms', { playerId: 'persistent-player', name: 'Tester', settings: { questionCount: 1 } }, new URLSearchParams()).body;
      saveStateNow();
      console.log(JSON.stringify({ profileToken: profile.token, roomToken: room.sessionToken, roomID: room.id }));
    `, directory);
    const second = run(`
      import { handle } from './index.mjs';
      const profile = handle('GET', '/profile', {}, new URLSearchParams({ id: 'persistent-player' }), 'Bearer ${first.profileToken}');
      const room = handle('GET', '/rooms/${first.roomID}', {}, new URLSearchParams({ playerId: 'persistent-player' }), 'Bearer ${first.roomToken}');
      console.log(JSON.stringify({ profile: profile.status, room: room.status, roomID: room.body.id }));
    `, directory);
    assert.deepEqual(second, { profile: 200, room: 200, roomID: first.roomID });
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test('approved friends and room invitations survive a server restart', () => {
  const directory = mkdtempSync(join(tmpdir(), 'intol-friends-'));
  try {
    const first = run(`
      import { handle, saveStateNow } from './index.mjs';
      const q = new URLSearchParams();
      const a = handle('POST', '/profile', { id: 'saved-friend-a' }, q).body;
      const b = handle('POST', '/profile', { id: 'saved-friend-b' }, q).body;
      const room = handle('POST', '/rooms', { playerId: 'saved-friend-a', name: 'A',
        profileId: a.id, profileToken: a.token, settings: { questionCount: 1 } }, q).body;
      const guest = handle('POST', '/rooms/' + room.id + '/join', { playerId: 'saved-friend-b',
        name: 'B', profileId: b.id, profileToken: b.token }, q).body;
      handle('POST', '/rooms/' + room.id + '/friend-request', { playerId: a.id,
        targetId: b.id }, q, 'Bearer ' + room.sessionToken);
      const request = handle('GET', '/friends', {}, new URLSearchParams({ profileId: b.id }),
        'Bearer ' + b.token).body.requests[0];
      handle('POST', '/friends/accept', { profileId: b.id, requestId: request.id }, q,
        'Bearer ' + b.token);
      handle('POST', '/rooms/' + room.id + '/leave', { playerId: b.id }, q,
        'Bearer ' + guest.sessionToken);
      handle('POST', '/rooms/' + room.id + '/invite', { playerId: a.id,
        targetProfileId: b.id }, q, 'Bearer ' + room.sessionToken);
      saveStateNow();
      console.log(JSON.stringify({ token: b.token }));
    `, directory);
    const second = run(`
      import { handle } from './index.mjs';
      const result = handle('GET', '/friends', {}, new URLSearchParams({ profileId: 'saved-friend-b' }),
        'Bearer ${first.token}');
      console.log(JSON.stringify({ status: result.status, friends: result.body.friends.length,
        invites: result.body.invites.length }));
    `, directory);
    assert.deepEqual(second, { status: 200, friends: 1, invites: 1 });
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test('registration retry credentials survive a server restart after a lost acknowledgement', () => {
  const directory = mkdtempSync(join(tmpdir(), 'intol-registration-'));
  const registrationToken = 'a13c43fa-3204-4b86-bba2-e6d6c411c0c6';
  try {
    run(`
      import { handle, saveStateNow } from './index.mjs';
      const created = handle('POST', '/profile', { id: 'registration-restart', registrationToken: '${registrationToken}' }, new URLSearchParams());
      saveStateNow();
      console.log(JSON.stringify({ status: created.status }));
    `, directory);
    const restored = run(`
      import { handle } from './index.mjs';
      const retried = handle('POST', '/profile', { id: 'registration-restart', registrationToken: '${registrationToken}' }, new URLSearchParams());
      console.log(JSON.stringify({ status: retried.status, token: retried.body.token }));
    `, directory);
    assert.deepEqual(restored, { status: 200, token: registrationToken });
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
