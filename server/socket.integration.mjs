import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';
import WebSocket from 'ws';
import { server } from './index.mjs';

function feed(socket) {
  const messages = [];
  const waiting = [];
  socket.on('message', data => {
    const message = JSON.parse(data.toString());
    messages.push(message);
    for (const notify of waiting.splice(0)) notify();
  });
  return async (predicate, timeoutMS = 2_000) => {
    const deadline = Date.now() + timeoutMS;
    while (Date.now() < deadline) {
      const index = messages.findIndex(predicate);
      if (index >= 0) return messages.splice(index, 1)[0];
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('WebSocket update timed out')), deadline - Date.now());
        waiting.push(() => { clearTimeout(timer); resolve(); });
      });
    }
    throw new Error('WebSocket update timed out');
  };
}

test('WebSocket actions and state broadcasts share one authenticated connection', async () => {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const base = `http://127.0.0.1:${server.address().port}`;
  const sockets = [];
  const post = async (path, body, token) => {
    const response = await fetch(`${base}${path}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: JSON.stringify(body)
    });
    assert.ok(response.ok, `${path}: ${response.status}`);
    return response.json();
  };
  try {
    const hostProfile = await post('/profile', { id: 'socket-host' });
    const guestProfile = await post('/profile', { id: 'socket-guest' });
    const room = await post('/rooms', { playerId: 'socket-host', name: 'Host',
      profileId: hostProfile.id, profileToken: hostProfile.token,
      settings: { questionCount: 1, answerSlots: 1, targetScore: 0 } });
    const guest = await post(`/rooms/${room.id}/join`, { playerId: 'socket-guest', name: 'Guest',
      profileId: guestProfile.id, profileToken: guestProfile.token });
    const denied = new WebSocket(`${base.replace('http:', 'ws:')}/rooms/${room.id}/socket?playerId=socket-guest`,
      { headers: { Authorization: `Bearer ${room.sessionToken}` } });
    denied.on('error', () => {});
    const deniedStatus = await new Promise(resolve => denied.on('unexpected-response', (_, response) => {
      response.resume();
      resolve(response.statusCode);
    }));
    assert.equal(deniedStatus, 403);
    const connect = async (playerId, token) => {
      const socket = new WebSocket(`${base.replace('http:', 'ws:')}/rooms/${room.id}/socket?playerId=${playerId}`,
        { headers: { Authorization: `Bearer ${token}` }, perMessageDeflate: false });
      sockets.push(socket);
      const next = feed(socket);
      await once(socket, 'open');
      const initial = await next(message => message.type === 'state');
      assert.equal(initial.state.id, room.id);
      assert.equal(initial.state.sessionToken, undefined);
      return { socket, next };
    };
    const host = await connect('socket-host', room.sessionToken);
    const visitor = await connect('socket-guest', guest.sessionToken);
    const action = (client, name, payload = {}) => {
      const id = randomUUID();
      client.socket.send(JSON.stringify({ type: 'action', id, action: name, payload }));
      return client.next(message => message.id === id && ['result', 'error'].includes(message.type));
    };

    const request = await action(host, 'friend-request', { targetId: 'socket-guest' });
    assert.equal(request.type, 'result');
    const pending = await fetch(`${base}/friends?profileId=${guestProfile.id}`, {
      headers: { Authorization: `Bearer ${guestProfile.token}` }
    }).then(response => response.json());
    assert.equal(pending.requests.length, 1);
    await post('/friends/accept', { profileId: guestProfile.id,
      requestId: pending.requests[0].id }, guestProfile.token);
    const invite = await action(host, 'invite', { targetProfileId: guestProfile.id });
    assert.equal(invite.status, 409); // This friend is already in the room.

    const ready = await action(host, 'assets-ready');
    assert.equal(ready.type, 'result');
    await visitor.next(message => message.type === 'state' && message.state.assetsReadyIds.includes('socket-host'));
    assert.equal((await action(visitor, 'assets-ready')).type, 'result');
    assert.equal((await action(host, 'start')).type, 'result');
    assert.equal((await action(host, 'ready')).type, 'result');
    const countdown = await action(visitor, 'ready');
    assert.equal(countdown.state.phase, 'countdown');
    await visitor.next(message => message.type === 'state' && message.state.phase === 'listening', 6_000);

    const first = action(host, 'push');
    const second = action(visitor, 'push');
    const answers = await Promise.all([first, second]);
    assert.deepEqual(answers.map(answer => answer.type).sort(), ['error', 'result']);
    const rejected = answers.find(answer => answer.type === 'error');
    assert.equal(rejected.status, 409);
    assert.equal(rejected.state.players.length, 2);
    assert.deepEqual(rejected.state.options, []);
    assert.equal(rejected.state.pushOrderIds.length, 2);
    const rejectedPlayerID = answers[0].type === 'error' ? 'socket-host' : 'socket-guest';
    assert.notEqual(rejected.state.players.find(player => player.id === rejectedPlayerID).pushTimeMS, null);
    const winner = answers[0].type === 'result' ? host : visitor;
    const loser = winner === host ? visitor : host;
    const winnerID = winner === host ? 'socket-host' : 'socket-guest';
    const pushedState = await loser.next(message => message.type === 'state' &&
      message.state.pushedIds.includes(winnerID));
    assert.equal(pushedState.state.players.length, 2);
    const recorded = await winner.next(message => message.type === 'state' &&
      message.state.pushOrderIds.length === 2);
    assert.ok(recorded.state.pushOrderIds.includes(rejectedPlayerID));
    const malformedChoice = await action(winner, 'choose', { choice: { toString: 'invalid' } });
    assert.equal(malformedChoice.status, 400);
    const actionId = randomUUID();
    const stillConnected = await action(winner, 'choose', { choice: '間違い', actionId });
    assert.equal(stillConnected.type, 'result');
    const winnerToken = winner === host ? room.sessionToken : guest.sessionToken;
    const duplicate = await post(`/rooms/${room.id}/choose`,
      { playerId: winnerID, choice: '間違い', actionId }, winnerToken);
    assert.equal(duplicate.players.find(player => player.id === winnerID).wrongCount, 1);
  } finally {
    for (const socket of sockets) socket.terminate();
    await new Promise(resolve => server.close(resolve));
  }
});
