import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { EventEmitter } from 'node:events';
import { Readable } from 'node:stream';
import { createChorusReportHandler, normalizeReport } from './chorus-reports.mjs';
import { server } from './index.mjs';

const webhook = 'https://discord.com/api/webhooks/123456/fake-token';
const makeReport = () => ({ id: '12345678-1234-1234-1234-123456789abc',
  song: { id: 'applemusic:123', title: '青い空', artist: '歌手', durationMS: 180000,
    genre: 'J-Pop', trackURL: 'https://music.apple.com/jp/song/123?tracking=private' },
  playback: { source: 'manual_database', audioSource: 'apple_music', startPositionMS: 48681 },
  playMode: 'solo', appVersion: '1.0', appBuild: '7' });
const confirmation = () => new Response(JSON.stringify({ id: 'discord-message-1' }), { status: 200 });

test('reports contain track and actual playback details and discard identity fields', async () => {
  const input = makeReport();
  input.nickname = 'PRIVATE-NAME'; input.profileId = 'PRIVATE-ID'; input.roomId = 'ABCDEF';
  input.song.account = 'PRIVATE-ACCOUNT'; input.playback.deviceID = 'PRIVATE-DEVICE';
  let call;
  const report = createChorusReportHandler({ webhookURL: () => webhook, fetchImpl: async (url, options) => {
    call = { url, options }; return confirmation();
  } });
  assert.equal((await report(input)).body.delivered, true);
  assert.equal(call.url.searchParams.get('wait'), 'true');
  assert.equal(call.options.redirect, 'error');
  assert.deepEqual(JSON.parse(call.options.body).allowed_mentions, { parse: [] });
  const payload = call.options.body;
  for (const privateValue of ['PRIVATE-', 'ABCDEF', 'tracking=private']) assert.ok(!payload.includes(privateValue));
  for (const detail of ['青い空', '歌手', 'applemusic:123', 'サビDB', 'Apple Music', '48.681秒', '180.000秒']) assert.ok(payload.includes(detail));
  assert.equal(normalizeReport(input).song.trackURL, 'https://music.apple.com/jp/song/123');
});

test('all successful playback routes have distinct Discord labels', async () => {
  for (const [source, label] of [['manual_database', 'サビDB'], ['song_metadata', '曲データ'],
    ['songle', 'Songle'], ['itunes_preview', 'プレビュー音源の冒頭'], ['duration_estimate', '推定']]) {
    const input = makeReport();
    input.playback.source = source;
    if (source === 'itunes_preview') input.playback = { source, audioSource: source, startPositionMS: 0 };
    const report = createChorusReportHandler({ webhookURL: () => webhook, fetchImpl: async (_, options) => {
      assert.ok(options.body.includes(label)); return confirmation();
    } });
    assert.equal((await report(input)).status, 200);
  }
});

test('invalid payloads and missing or unsafe webhook configuration never send', async () => {
  let calls = 0;
  const report = createChorusReportHandler({ webhookURL: () => webhook, fetchImpl: async () => { calls++; return confirmation(); } });
  for (const mutate of [r => { r.id = 'invalid'; }, r => { r.playback.source = 'invented'; },
    r => { r.playback.startPositionMS = -1; }, r => { r.playback.startPositionMS = 1.5; },
    r => { r.song.durationMS = Infinity; }, r => { r.song.title = ''; },
    r => { r.song.trackURL = 'http://localhost/private'; }, r => { r.playback.audioSource = 'itunes_preview'; },
    r => { r.playMode = 'ABCDEF'; }]) {
    const input = makeReport(); mutate(input);
    assert.equal((await report(input)).status, 400);
  }
  for (const address of [undefined, 'https://evil.test/api/webhooks/123/token', 'http://discord.com/api/webhooks/123/token']) {
    const unavailable = createChorusReportHandler({ webhookURL: () => address, fetchImpl: async () => { calls++; return confirmation(); } });
    assert.equal((await unavailable(makeReport())).status, 503);
  }
  assert.equal(calls, 0);
});

test('Discord failures never become successful reports and the same report can retry', async () => {
  for (const failed of [() => { throw new Error('fake-token-private'); },
    () => new Response('', { status: 500 }), () => new Response('', { status: 429 }),
    () => new Response(null, { status: 204 }), () => new Response('{}', { status: 200 })]) {
    let calls = 0;
    const report = createChorusReportHandler({ webhookURL: () => webhook, fetchImpl: async () => ++calls === 1 ? failed() : confirmation() });
    const first = await report(makeReport());
    assert.ok([429, 502].includes(first.status));
    assert.ok(!JSON.stringify(first).includes('fake-token-private'));
    assert.equal((await report(makeReport())).body.delivered, true);
    assert.equal(calls, 2);
  }
});

test('retries, simultaneous taps, and restarts reuse the anonymous receipt', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'intol-chorus-reports-'));
  try {
    let release, calls = 0;
    const options = { dataDir: directory, webhookURL: () => webhook,
      fetchImpl: async () => { calls++; await new Promise(resolve => { release = resolve; }); return confirmation(); } };
    const report = createChorusReportHandler(options);
    const first = report(makeReport());
    const simultaneous = report(makeReport());
    release();
    assert.equal((await first).status, 200); assert.equal((await simultaneous).status, 200);
    assert.equal((await report(makeReport())).status, 200);
    const restarted = createChorusReportHandler(options);
    assert.equal((await restarted(makeReport())).status, 200);
    assert.equal(calls, 1);
    const changed = makeReport(); changed.song.title = '別の曲';
    assert.equal((await report(changed)).status, 409);
    const saved = readFileSync(join(directory, 'chorus-reports.json'), 'utf8');
    assert.ok(saved.includes('青い空')); assert.ok(!saved.includes('fake-token'));
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test('anonymous intake is bounded and returns a retryable rate limit', async () => {
  const report = createChorusReportHandler({ webhookURL: () => webhook, fetchImpl: async () => confirmation() });
  for (let index = 0; index < 31; index++) {
    const input = makeReport(); input.id = `12345678-1234-1234-1234-${String(index).padStart(12, '0')}`;
    assert.equal((await report(input)).status, index < 30 ? 200 : 429);
  }
});

class TestResponse extends EventEmitter {
  constructor() { super(); this.completed = new Promise(resolve => { this.resolve = resolve; }); }
  writeHead(status) { this.status = status; }
  end(body) { this.body = JSON.parse(body); this.resolve(); }
}

test('POST /chorus-reports works without player or profile authentication', async () => {
  const previousURL = process.env.DISCORD_CHORUS_WEBHOOK_URL;
  const originalFetch = globalThis.fetch;
  process.env.DISCORD_CHORUS_WEBHOOK_URL = webhook;
  globalThis.fetch = async () => confirmation();
  try {
    const request = Readable.from([Buffer.from(JSON.stringify(makeReport()))]);
    request.method = 'POST'; request.url = '/chorus-reports'; request.headers = { host: 'localhost' };
    const response = new TestResponse(); server.emit('request', request, response);
    await response.completed;
    assert.equal(response.status, 200); assert.equal(response.body.delivered, true);
  } finally {
    globalThis.fetch = originalFetch;
    if (previousURL === undefined) delete process.env.DISCORD_CHORUS_WEBHOOK_URL;
    else process.env.DISCORD_CHORUS_WEBHOOK_URL = previousURL;
  }
});
