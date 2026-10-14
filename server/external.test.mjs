import test from 'node:test';
import assert from 'node:assert/strict';
import { topSongs, chorusPosition, chorusResult, fallbackChorus } from './external.mjs';

test('top song metadata remains available for answer choices', async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async url => {
    assert.ok(String(url).includes('rss.applemarketingtools.com'));
    return new Response(JSON.stringify({ feed: { results: [{ name: '群青' }] } }), { status: 200 });
  };
  try { assert.deepEqual(await topSongs(), ['群青']); }
  finally { globalThis.fetch = original; }
});

test('DB misses never query Songle or iTunes, including songs with old URLs and positions', async () => {
  const original = globalThis.fetch;
  const requests = [];
  globalThis.fetch = async url => {
    requests.push(String(url));
    throw new Error('External lookups must not be used for chorus positions');
  };
  try {
    for (const id of ['applemusic:123', 'shared:recording', 'demo:aoi', 'itunes:123']) {
      const song = { id, title: '青い空', artist: '歌手', durationMS: 180000,
        songleURL: 'https://songle.jp/songs/www.nicovideo.jp%2Fwatch%2Fsm123',
        previewURL: 'https://audio.example/preview.m4a', chorusMS: 63500, chorusSource: 'songle' };
      assert.equal(await chorusPosition(song), null);
      assert.deepEqual(await chorusResult(song), { positionMS: null, source: null, databaseConfigured: false });
    }
    assert.deepEqual(requests, []);
  } finally { globalThis.fetch = original; }
});

test('duration estimates preserve audible time on short recordings', () => {
  for (const [duration, position] of [[180000, 56100], [181234, 56495], [30000, 25000],
    [3000, 0], [0, 56100], [600000, 88500]]) {
    assert.equal(fallbackChorus(duration), position);
  }
});
