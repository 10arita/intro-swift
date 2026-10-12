import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { EventEmitter } from 'node:events';
import { Readable } from 'node:stream';
import { createFeedbackHandler, normalizeFeedback, maximumMessageLength } from './feedback.mjs';
import { createChorusReportHandler } from './chorus-reports.mjs';
import { createReportRateLimit } from './anonymous-reports.mjs';
import { server } from './index.mjs';

const webhook = 'https://discord.com/api/webhooks/123456/fake-token';
const makeFeedback = () => ({ id: '12345678-1234-1234-1234-123456789abc',
  message: 'プレイリストの検索ができると嬉しいです。\n@everyone', appVersion: '1.0', appBuild: '7' });
const confirmation = () => new Response(JSON.stringify({ id: 'discord-message-1' }), { status: 200 });

test('feedback forwards only message and app version to its Discord webhook', async () => {
  const input = { ...makeFeedback(), nickname: 'PRIVATE-NAME', profileId: 'PRIVATE-ID', roomId: 'PRIVATE-ROOM',
    deviceID: 'PRIVATE-DEVICE', token: 'PRIVATE-TOKEN' };
  const feedback = createFeedbackHandler({ webhookURL: () => webhook, fetchImpl: async (url, options) => {
    assert.equal(url.searchParams.get('wait'), 'true');
    assert.equal(options.redirect, 'error');
    const payload = JSON.parse(options.body);
    assert.deepEqual(payload.allowed_mentions, { parse: [] });
    assert.equal(payload.embeds[0].title, '意見・お問い合わせ · 匿名送信');
    assert.equal(payload.embeds[0].description, input.message);
    assert.ok(options.body.includes('1.0 (7)'));
    assert.ok(!options.body.includes('PRIVATE-'));
    return confirmation();
  } });
  assert.deepEqual(Object.keys(normalizeFeedback(input)), ['id', 'message', 'appVersion', 'appBuild']);
  assert.equal((await feedback(input)).body.delivered, true);
});

test('feedback rejects empty, malformed, and oversized messages before sending', async () => {
  let calls = 0;
  const feedback = createFeedbackHandler({ webhookURL: () => webhook, fetchImpl: async () => { calls++; return confirmation(); } });
  for (const message of [undefined, null, 123, '', ' \n\t', 'あ'.repeat(maximumMessageLength + 1),
    '🎵'.repeat(maximumMessageLength / 2 + 1)]) {
    assert.equal((await feedback({ ...makeFeedback(), message })).status, 400);
  }
  for (const invalid of [null, [], { ...makeFeedback(), id: 'invalid' }, { ...makeFeedback(), appBuild: '' }]) {
    assert.equal((await feedback(invalid)).status, 400);
  }
  assert.equal(calls, 0);
  assert.equal((await feedback({ ...makeFeedback(), message: 'あ'.repeat(maximumMessageLength) })).status, 200);
  assert.equal(calls, 1);
});

test('feedback retains one receipt for simultaneous sends, retries, and server restarts', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'intol-feedback-'));
  try {
    let release, calls = 0;
    const options = { dataDir: directory, webhookURL: () => webhook, fetchImpl: async () => {
      calls++; await new Promise(resolve => { release = resolve; }); return confirmation();
    } };
    const feedback = createFeedbackHandler(options);
    const first = feedback(makeFeedback()), duplicate = feedback(makeFeedback());
    release();
    assert.equal((await first).status, 200); assert.equal((await duplicate).status, 200);
    assert.equal((await feedback(makeFeedback())).status, 200);
    assert.equal((await createFeedbackHandler(options)(makeFeedback())).status, 200);
    assert.equal(calls, 1);
    assert.equal((await feedback({ ...makeFeedback(), message: '変更した内容' })).status, 409);
    const saved = readFileSync(join(directory, 'feedback-reports.json'), 'utf8');
    assert.ok(saved.includes('プレイリスト')); assert.ok(!saved.includes('fake-token'));
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test('feedback shows configuration and delivery failures and allows the same message to retry', async () => {
  assert.equal((await createFeedbackHandler({ webhookURL: () => undefined })(makeFeedback())).status, 503);
  for (const failed of [() => { throw new Error('PRIVATE-TOKEN'); },
    () => new Response(null, { status: 204 }), () => new Response('{}', { status: 200 }),
    () => new Response('', { status: 429 }), () => new Response('', { status: 500 })]) {
    let calls = 0;
    const feedback = createFeedbackHandler({ webhookURL: () => webhook,
      fetchImpl: async () => ++calls === 1 ? failed() : confirmation() });
    const result = await feedback(makeFeedback());
    assert.ok([429, 502].includes(result.status));
    assert.ok(!JSON.stringify(result).includes('PRIVATE-TOKEN'));
    assert.equal((await feedback(makeFeedback())).body.delivered, true);
    assert.equal(calls, 2);
  }
});

test('feedback and chorus reports share the server intake limit and recover after a minute', async () => {
  let currentTime = 100_000;
  const now = () => currentTime;
  const options = { now, rateLimit: createReportRateLimit(now), webhookURL: () => webhook, fetchImpl: async () => confirmation() };
  const feedback = createFeedbackHandler(options), chorus = createChorusReportHandler(options);
  const chorusReport = { ...makeFeedback(), song: { id: 'demo:123', title: '青い空', artist: '歌手',
    durationMS: 180000, genre: 'Pop' }, playback: { source: 'itunes_preview', audioSource: 'itunes_preview',
    startPositionMS: 0 }, playMode: 'solo' };
  for (let index = 0; index < 30; index++) {
    const id = `12345678-1234-1234-1234-${String(index).padStart(12, '0')}`;
    const result = index % 2 ? await chorus({ ...chorusReport, id }) : await feedback({ ...makeFeedback(), id });
    assert.equal(result.status, 200);
  }
  assert.equal((await feedback(makeFeedback())).status, 429);
  assert.equal((await chorus(chorusReport)).status, 429);
  currentTime += 60_000;
  assert.equal((await feedback(makeFeedback())).status, 200);
});

class TestResponse extends EventEmitter {
  constructor() { super(); this.completed = new Promise(resolve => { this.resolve = resolve; }); }
  writeHead(status) { this.status = status; }
  end(body) { this.body = JSON.parse(body); this.resolve(); }
}

test('POST /feedback accepts anonymous requests and bounds request size', async () => {
  const previousURL = process.env.DISCORD_FEEDBACK_WEBHOOK_URL, originalFetch = globalThis.fetch;
  process.env.DISCORD_FEEDBACK_WEBHOOK_URL = webhook;
  globalThis.fetch = async url => {
    assert.equal(url.pathname, new URL(webhook).pathname);
    return confirmation();
  };
  try {
    for (const [body, status] of [[JSON.stringify(makeFeedback()), 200], [' '.repeat(16_385), 413]]) {
      const request = Readable.from([Buffer.from(body)]);
      request.method = 'POST'; request.url = '/feedback'; request.headers = { host: 'localhost' };
      const response = new TestResponse(); server.emit('request', request, response);
      await response.completed;
      assert.equal(response.status, status);
      if (status === 200) assert.equal(response.body.delivered, true);
    }
  } finally {
    globalThis.fetch = originalFetch;
    if (previousURL === undefined) delete process.env.DISCORD_FEEDBACK_WEBHOOK_URL;
    else process.env.DISCORD_FEEDBACK_WEBHOOK_URL = previousURL;
  }
});

test('default feedback and chorus handlers use independent webhook settings with no fallback', async () => {
  const keys = ['DISCORD_CHORUS_WEBHOOK_URL', 'DISCORD_FEEDBACK_WEBHOOK_URL'];
  const previous = keys.map(key => process.env[key]);
  const feedbackWebhook = 'https://discord.com/api/webhooks/654321/feedback-token';
  const calls = [];
  const options = { fetchImpl: async url => { calls.push(url.pathname); return confirmation(); } };
  const chorusReport = { id: makeFeedback().id, appVersion: '1.0', appBuild: '7', playMode: 'solo',
    song: { id: 'demo:123', title: '青い空', artist: '歌手', durationMS: 180000, genre: 'Pop' },
    playback: { source: 'itunes_preview', audioSource: 'itunes_preview', startPositionMS: 0 } };
  try {
    process.env.DISCORD_CHORUS_WEBHOOK_URL = webhook;
    delete process.env.DISCORD_FEEDBACK_WEBHOOK_URL;
    assert.equal((await createFeedbackHandler(options)(makeFeedback())).status, 503);
    assert.deepEqual(calls, []);
    process.env.DISCORD_FEEDBACK_WEBHOOK_URL = feedbackWebhook;
    assert.equal((await createFeedbackHandler(options)(makeFeedback())).status, 200);
    assert.equal((await createChorusReportHandler(options)(chorusReport)).status, 200);
    assert.deepEqual(calls, [new URL(feedbackWebhook).pathname, new URL(webhook).pathname]);
    delete process.env.DISCORD_CHORUS_WEBHOOK_URL;
    assert.equal((await createChorusReportHandler(options)(chorusReport)).status, 503);
    assert.equal(calls.length, 2);
  } finally {
    keys.forEach((key, index) => {
      if (previous[index] === undefined) delete process.env[key];
      else process.env[key] = previous[index];
    });
  }
});
