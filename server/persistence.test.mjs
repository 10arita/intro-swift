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
