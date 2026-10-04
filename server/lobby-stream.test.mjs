import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';
import WebSocket from 'ws';
import { server } from './index.mjs';

function feed(socket) {
  const messages = [];
  let wake;
  socket.on('message', data => { messages.push(JSON.parse(data.toString())); wake?.(); });
  return async predicate => {
    const deadline = Date.now() + 3000;
    while (Date.now() < deadline) {
      const index = messages.findIndex(predicate);
      if (index >= 0) return messages.splice(index, 1)[0];
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('Lobby update timed out')), Math.max(1, deadline - Date.now()));
        wake = () => { clearTimeout(timer); wake = null; resolve(); };
      });
    }
    throw new Error('Lobby update timed out');
  };
}

test('lobby configuration broadcasts to a connected guest over WebSocket', async () => {
  const sockets = [];
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const base = `http://127.0.0.1:${server.address().port}`;
  const post = async (path, body) => {
    const response = await fetch(`${base}${path}`, { method: 'POST',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    assert.ok(response.ok); return response.json();
  };
  try {
    const room = await post('/rooms', { playerId: 'lobby-stream-host', name: 'Host', mode: 'applemusic', deferQuestions: true });
    const guest = await post(`/rooms/${room.id}/join`, { playerId: 'lobby-stream-guest', name: 'Guest' });
    const connect = async (playerId, token) => {
      const socket = new WebSocket(`${base.replace('http:', 'ws:')}/rooms/${room.id}/socket?playerId=${playerId}`,
        { headers: { Authorization: `Bearer ${token}` } });
      sockets.push(socket); const next = feed(socket);
      await once(socket, 'open'); await next(message => message.type === 'state');
      return { socket, next };
    };
    const host = await connect('lobby-stream-host', room.sessionToken);
    const visitor = await connect('lobby-stream-guest', guest.sessionToken);
    const payload = { settings: { questionCount: 3, lives: 5 }, playlist: { name: '夜の音楽', songCount: 24 } };
    const deniedID = randomUUID();
    visitor.socket.send(JSON.stringify({ type: 'action', id: deniedID, action: 'lobby-config', payload }));
    assert.equal((await visitor.next(message => message.id === deniedID)).status, 403);
    const actionID = randomUUID();
    host.socket.send(JSON.stringify({ type: 'action', id: actionID, action: 'lobby-config', payload }));
    assert.equal((await host.next(message => message.id === actionID)).type, 'result');
    const update = await visitor.next(message => message.type === 'state' && message.state.playlist?.name === '夜の音楽');
    assert.equal(update.state.settings.questionCount, 3);
    assert.equal(update.state.settings.lives, 5);
    assert.deepEqual(update.state.roundSongs, []);
  } finally {
    for (const socket of sockets) socket.terminate();
    await new Promise(resolve => server.close(resolve));
  }
});
